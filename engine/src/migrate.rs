//! Migração do app 1.x (macOS): o banco SwiftData vira a lista plana de perfis.
//!
//! Só leitura: o banco antigo nunca é alterado nem apagado, para a volta ao
//! 1.x continuar possível. Projeto e perfil viram um nome só
//! (`api · producao`), e o perfil "Default" — a foto do ambiente da máquina —
//! fica de fora: na 2.0 o original é o próprio ambiente, sem perfil.

use std::path::{Path, PathBuf};

use hyperenv_core::{EnvKey, EnvValue};
use rusqlite::{Connection, OpenFlags};

use crate::Error;
use crate::store::{Store, Variable};

/// Onde o SwiftData do 1.x guarda o banco: com e sem sandbox.
pub fn candidate_stores(home: &Path) -> Vec<PathBuf> {
    vec![
        home.join("Library/Containers/com.falcaosl.hyperenv/Data/Library/Application Support/default.store"),
        home.join("Library/Application Support/default.store"),
    ]
}

/// Um `default.store` só é do HyperEnv se tiver as três tabelas dele — o
/// nome do arquivo é o padrão do SwiftData e outros apps usam o mesmo.
pub fn find_store(home: &Path) -> Option<PathBuf> {
    candidate_stores(home).into_iter().find(|p| is_hyperenv_store(p))
}

pub fn is_hyperenv_store(path: &Path) -> bool {
    let Ok(conn) = open(path) else { return false };
    ["ZPROJECT", "ZPROFILE", "ZENVVARIABLE"].iter().all(|t| {
        conn.query_row(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1",
            [t],
            |_| Ok(()),
        )
        .is_ok()
    })
}

fn open(path: &Path) -> rusqlite::Result<Connection> {
    Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
}

#[derive(Debug, Default)]
pub struct Report {
    pub profiles: usize,
    pub variables: usize,
    /// Variáveis com nome inválido, deixadas de fora.
    pub skipped: Vec<String>,
}

/// Junta os perfis do banco antigo ao `store`. Perfis cujo nome já existe
/// ganham um sufixo, nunca sobrescrevem.
pub fn import_swiftdata(db: &Path, store: &mut Store) -> Result<Report, Error> {
    let corrupt = |e: rusqlite::Error| Error::Corrupt {
        path: db.to_path_buf(),
        detail: e.to_string(),
    };
    let conn = open(db).map_err(corrupt)?;

    let projects: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM ZPROJECT WHERE COALESCE(ZISDEFAULT,0)=0",
            [],
            |r| r.get(0),
        )
        .map_err(corrupt)?;

    let mut stmt = conn
        .prepare(
            "SELECT p.Z_PK, COALESCE(pr.ZNAME,''), COALESCE(p.ZNAME,'')
             FROM ZPROFILE p LEFT JOIN ZPROJECT pr ON pr.Z_PK = p.ZPROJECT
             WHERE COALESCE(p.ZISDEFAULT,0)=0
             ORDER BY COALESCE(pr.ZSORTINDEX,0), COALESCE(p.ZSORTINDEX,0)",
        )
        .map_err(corrupt)?;
    let rows: Vec<(i64, String, String)> = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .map_err(corrupt)?
        .collect::<Result<_, _>>()
        .map_err(corrupt)?;

    let mut report = Report::default();
    for (pk, project, profile) in rows {
        // Com um projeto só, o nome do projeto não acrescenta nada.
        let base = if projects <= 1 || project.is_empty() {
            profile.clone()
        } else {
            format!("{project} · {profile}")
        };
        let name = unique_name(store, if base.trim().is_empty() { "perfil" } else { &base });

        let mut vars_stmt = conn
            .prepare(
                "SELECT COALESCE(ZKEY,''), COALESCE(ZVALUE,''), COALESCE(ZISSECRET,0), COALESCE(ZISENABLED,1)
                 FROM ZENVVARIABLE WHERE ZPROFILE = ?1 ORDER BY COALESCE(ZSORTINDEX,0)",
            )
            .map_err(corrupt)?;
        let vars: Vec<(String, String, bool, bool)> = vars_stmt
            .query_map([pk], |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get::<_, i64>(2)? != 0,
                    r.get::<_, i64>(3)? != 0,
                ))
            })
            .map_err(corrupt)?
            .collect::<Result<_, _>>()
            .map_err(corrupt)?;

        store.create(&name)?;
        let target = store.profiles.last_mut().expect("acabou de ser criado");
        for (key, value, secret, enabled) in vars {
            match EnvKey::new(key.clone()) {
                Some(key) if !target.variables.iter().any(|v| v.key == key) => {
                    target.variables.push(Variable {
                        key,
                        value: EnvValue::new(value),
                        secret,
                        enabled,
                    });
                    report.variables += 1;
                }
                Some(_) => {}
                None => report.skipped.push(format!("{name}: {key}")),
            }
        }
        report.profiles += 1;
    }
    Ok(report)
}

fn unique_name(store: &Store, base: &str) -> String {
    let taken = |n: &str| store.profiles.iter().any(|p| p.name.eq_ignore_ascii_case(n));
    if !taken(base) {
        return base.to_owned();
    }
    (2..)
        .map(|i| format!("{base} ({i})"))
        .find(|n| !taken(n))
        .expect("sempre há um sufixo livre")
}
