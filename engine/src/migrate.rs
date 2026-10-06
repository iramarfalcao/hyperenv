//! Migration from the 1.x app (macOS): the SwiftData database becomes the flat
//! list of profiles.
//!
//! Read-only: the old database is never modified or deleted, so going back to
//! 1.x stays possible. Project and profile merge into a single name
//! (`api · production`), and the "Default" profile — the snapshot of the
//! machine's environment — is left out: in 2.0 the original is the environment
//! itself, with no profile.

use std::path::{Path, PathBuf};

use hyperenv_core::{EnvKey, EnvValue};
use rusqlite::{Connection, OpenFlags};

use crate::Error;
use crate::store::{Store, Variable};

/// Where 1.x's SwiftData keeps the database: with and without the sandbox.
pub fn candidate_stores(home: &Path) -> Vec<PathBuf> {
    vec![
        home.join("Library/Containers/com.falcaosl.hyperenv/Data/Library/Application Support/default.store"),
        home.join("Library/Application Support/default.store"),
    ]
}

/// A `default.store` only belongs to HyperEnv if it has HyperEnv's three
/// tables — the file name is SwiftData's default and other apps use it too.
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
    /// Variables with an invalid name, left out.
    pub skipped: Vec<String>,
}

/// Merges the old database's profiles into `store`. Profiles whose name
/// already exists get a suffix; they never overwrite.
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
        // With a single project, the project name adds nothing.
        let base = if projects <= 1 || project.is_empty() {
            profile.clone()
        } else {
            format!("{project} · {profile}")
        };
        let name = unique_name(store, if base.trim().is_empty() { "profile" } else { &base });

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
        let target = store.profiles.last_mut().expect("just created");
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
        .expect("there is always a free suffix")
}
