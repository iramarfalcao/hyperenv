//! Inserir e remover, de forma idempotente, um bloco delimitado por
//! marcadores dentro de um arquivo que o usuário também edita à mão
//! (`~/.zprofile`, `~/.bash_profile`).
//!
//! É de propósito uma transformação pura `&str -> String`: é a operação mais
//! perigosa do app — reescreve um arquivo que pode quebrar o login do shell —
//! então não faz I/O nenhum e todo caso de borda é alcançável por um teste.

use crate::types::Error;
use std::ops::RangeInclusive;

/// A detecção casa pelo prefixo, e não pelo texto inteiro, para que uma versão
/// futura que mude o final do marcador ainda ache — e migre — um bloco da v1.
pub const BEGIN_PREFIX: &str = "# >>> hyperenv managed block";
pub const END_PREFIX: &str = "# <<< hyperenv managed block";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Markers {
    pub begin: String,
    pub end: String,
}

impl Markers {
    /// Os mesmos marcadores do app Swift: um `~/.zprofile` escrito pela v1
    /// continua sendo reconhecido.
    pub fn v1() -> Self {
        Self {
            begin: format!("{BEGIN_PREFIX} v1 >>> (do not edit)"),
            end: format!("{END_PREFIX} v1 <<<"),
        }
    }
}

// ── Modelo de linhas ─────────────────────────────────────────────────────────

/// O arquivo em linhas, mais as duas propriedades que precisam sobreviver à
/// ida e volta: o terminador usado e se ele terminava com um. Perder qualquer
/// uma apareceria como diff do arquivo inteiro no repositório de dotfiles.
#[derive(Debug, Clone, PartialEq, Eq)]
struct LineModel {
    lines: Vec<String>,
    uses_crlf: bool,
    has_trailing_newline: bool,
}

impl LineModel {
    fn parse(content: &str) -> Self {
        let mut normalized = String::with_capacity(content.len());
        let mut saw_crlf = false;
        let mut chars = content.chars().peekable();
        while let Some(c) = chars.next() {
            if c == '\r' {
                if chars.peek() == Some(&'\n') {
                    chars.next();
                    saw_crlf = true;
                }
                // CR sozinho também conta como quebra de linha.
                normalized.push('\n');
            } else {
                normalized.push(c);
            }
        }
        let has_trailing_newline = normalized.ends_with('\n');
        if has_trailing_newline {
            normalized.pop();
        }
        let lines = if normalized.is_empty() && !has_trailing_newline {
            Vec::new()
        } else {
            normalized.split('\n').map(str::to_owned).collect()
        };
        Self {
            lines,
            uses_crlf: saw_crlf,
            has_trailing_newline,
        }
    }

    fn render(&self) -> String {
        let terminator = if self.uses_crlf { "\r\n" } else { "\n" };
        let mut out = self.lines.join(terminator);
        if self.has_trailing_newline {
            out.push_str(terminator);
        }
        out
    }
}

fn is_blank(line: &str) -> bool {
    line.trim_matches([' ', '\t']).is_empty()
}

// ── Localização ──────────────────────────────────────────────────────────────

/// Acha o bloco gerenciado, ou falha se o arquivo estiver num estado em que
/// adivinhar poderia destruir conteúdo do usuário.
///
/// Casa prefixo exato numa linha aparada, então um marcador citado dentro de
/// um comentário do usuário (`# veja o "# >>> hyperenv"`) não conta.
fn find_span(lines: &[String], path: &str) -> Result<Option<RangeInclusive<usize>>, Error> {
    let trimmed = |l: &String| l.trim_matches([' ', '\t']).to_owned();
    let begins: Vec<usize> = (0..lines.len())
        .filter(|&i| trimmed(&lines[i]).starts_with(BEGIN_PREFIX))
        .collect();
    let ends: Vec<usize> = (0..lines.len())
        .filter(|&i| trimmed(&lines[i]).starts_with(END_PREFIX))
        .collect();

    let fail = |detail: String| Error::UnbalancedMarkers {
        path: path.to_owned(),
        detail,
    };

    match (begins.len(), ends.len()) {
        (0, 0) => Ok(None),
        (1, 1) if ends[0] > begins[0] => Ok(Some(begins[0]..=ends[0])),
        (1, 1) => Err(fail(format!(
            "o marcador de fim na linha {} vem antes do de início na linha {}",
            ends[0] + 1,
            begins[0] + 1
        ))),
        (0, _) => Err(fail(format!(
            "um marcador de fim na linha {} sem marcador de início",
            ends[0] + 1
        ))),
        (_, 0) => Err(fail(format!(
            "um marcador de início na linha {} sem marcador de fim",
            begins[0] + 1
        ))),
        (b, e) => Err(fail(format!(
            "{b} marcadores de início e {e} de fim; esperado exatamente um de cada"
        ))),
    }
}

// ── Instalar ─────────────────────────────────────────────────────────────────

/// Insere ou atualiza o bloco.
///
/// - Sem bloco, ele vai para o fim: no `.zprofile` a última atribuição vence, e
///   precisamos ficar depois de coisas como `brew shellenv`.
/// - Com bloco, ele é trocado **no lugar**, preservando a posição — quem o
///   moveu de propósito mantém a ordem.
///
/// Entrada igual à saída significa que quem chamou deve pular a escrita.
pub fn install(content: &str, body: &[String], markers: &Markers, path: &str) -> Result<String, Error> {
    let mut model = LineModel::parse(content);
    let mut block = Vec::with_capacity(body.len() + 2);
    block.push(markers.begin.clone());
    block.extend(body.iter().cloned());
    block.push(markers.end.clone());

    if let Some(span) = find_span(&model.lines, path)? {
        model.lines.splice(span, block);
    } else {
        let file_was_empty = model.lines.is_empty();
        // Separa do conteúdo existente com exatamente uma linha em branco, e só
        // quando há conteúdo para separar.
        if model.lines.last().is_some_and(|l| !is_blank(l)) {
            model.lines.push(String::new());
        }
        model.lines.extend(block);
        // Só arquivo novo ganha quebra de linha final imposta. Pôr uma num
        // arquivo que não tinha quebraria a garantia de que instalar e remover
        // devolve os mesmos bytes.
        if file_was_empty {
            model.has_trailing_newline = true;
        }
    }
    Ok(model.render())
}

// ── Remover ──────────────────────────────────────────────────────────────────

/// Apaga o bloco e a única linha em branco separadora que `install` põe.
/// Arquivo sem bloco volta intacto.
pub fn remove(content: &str, path: &str) -> Result<String, Error> {
    let mut model = LineModel::parse(content);
    let Some(span) = find_span(&model.lines, path)? else {
        return Ok(content.to_owned());
    };
    let mut lower = *span.start();
    if lower > 0 && is_blank(&model.lines[lower - 1]) {
        lower -= 1;
    }
    model.lines.drain(lower..=*span.end());
    if model.lines.is_empty() {
        model.has_trailing_newline = false;
    }
    Ok(model.render())
}

// ── Inspeção ─────────────────────────────────────────────────────────────────

/// As linhas internas do bloco, sem os marcadores.
pub fn extract_body(content: &str, path: &str) -> Result<Option<Vec<String>>, Error> {
    let model = LineModel::parse(content);
    let Some(span) = find_span(&model.lines, path)? else {
        return Ok(None);
    };
    let (start, end) = (*span.start(), *span.end());
    Ok(Some(model.lines[start + 1..end].to_vec()))
}

pub fn contains_block(content: &str) -> bool {
    matches!(find_span(&LineModel::parse(content).lines, "file"), Ok(Some(_)))
}
