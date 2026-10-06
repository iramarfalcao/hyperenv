//! Ler e escrever arquivos `.env`.
//!
//! Não existe um dialeto de `.env` certo. O `docker --env-file` não tira aspa
//! nenhuma — pega os bytes crus depois do `=` —, então um valor com aspas para
//! o shell chega no Docker com as aspas dentro. O dialeto é escolha explícita,
//! nunca palpite.

use crate::quoting::{dotenv_double, posix_single};
use crate::types::{EnvKey, EnvSet, EnvValue};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Dialect {
    /// Aspas simples. Pode dar `source` num shell.
    PosixShell,
    /// Aspas duplas com escapes. O que a maioria das bibliotecas de dotenv espera.
    Dotenv,
    /// Bytes crus depois do `=`. Sem aspas, sem quebra de linha.
    Docker,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
    Warning,
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Diagnostic {
    pub severity: Severity,
    /// A partir de 1, para mostrar direto numa lista. 0 = o arquivo todo.
    pub line: usize,
    pub message: String,
}

impl Diagnostic {
    fn error(line: usize, message: impl Into<String>) -> Self {
        Self {
            severity: Severity::Error,
            line,
            message: message.into(),
        }
    }
    fn warning(line: usize, message: impl Into<String>) -> Self {
        Self {
            severity: Severity::Warning,
            line,
            message: message.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub key: EnvKey,
    pub value: EnvValue,
    pub line: usize,
}

#[derive(Debug, Clone, Default)]
pub struct DecodeResult {
    pub entries: Vec<Entry>,
    pub diagnostics: Vec<Diagnostic>,
}

impl DecodeResult {
    pub fn has_errors(&self) -> bool {
        self.diagnostics.iter().any(|d| d.severity == Severity::Error)
    }

    /// Duplicadas resolvidas (a última vence), pronto para importar.
    pub fn env_set(&self) -> EnvSet {
        self.entries
            .iter()
            .map(|e| (e.key.clone(), e.value.clone()))
            .collect()
    }
}

#[derive(Debug, Clone, Copy)]
pub struct Limits {
    pub max_bytes: usize,
    pub max_value_bytes: usize,
    pub max_entries: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_bytes: 5 * 1024 * 1024,
            max_value_bytes: 64 * 1024,
            max_entries: 5_000,
        }
    }
}

// ── Escrever ─────────────────────────────────────────────────────────────────

/// Gera o texto do `.env`, em ordem de nome (o arquivo vai para o git).
pub fn encode(
    variables: &EnvSet,
    dialect: Dialect,
    header: &[String],
    export_prefix: bool,
) -> (String, Vec<Diagnostic>) {
    let mut lines: Vec<String> = header.iter().map(|h| format!("# {h}")).collect();
    if !lines.is_empty() {
        lines.push(String::new());
    }
    let mut diagnostics = Vec::new();
    let prefix = if export_prefix { "export " } else { "" };

    for (key, value) in variables.iter() {
        let rendered = match dialect {
            Dialect::PosixShell => posix_single(value.as_str()),
            Dialect::Dotenv => dotenv_double(value.as_str()),
            Dialect::Docker => {
                if value.contains_newline() {
                    diagnostics.push(Diagnostic::error(
                        0,
                        format!("{key} tem quebra de linha, que o docker --env-file não representa. Ficou de fora."),
                    ));
                    continue;
                }
                value.as_str().to_owned()
            }
        };
        lines.push(format!("{prefix}{key}={rendered}"));
    }
    let mut text = lines.join("\n");
    text.push('\n');
    (text, diagnostics)
}

// ── Ler ──────────────────────────────────────────────────────────────────────

/// Lê o texto e devolve tudo o que conseguiu *mais* tudo o que recusou. Uma
/// linha ruim é recusada sozinha; nunca derruba o resto do arquivo.
pub fn decode(raw: &str, limits: Limits) -> DecodeResult {
    let mut out = DecodeResult::default();

    if raw.len() > limits.max_bytes {
        out.diagnostics.push(Diagnostic::error(
            0,
            format!("O arquivo passa de {} MB.", limits.max_bytes / 1_048_576),
        ));
        return out;
    }

    let text = raw
        .strip_prefix('\u{FEFF}')
        .unwrap_or(raw)
        .replace("\r\n", "\n")
        .replace('\r', "\n");
    let c: Vec<char> = text.chars().collect();
    let n = c.len();
    let mut i = 0usize;
    let mut line = 1usize;

    let skip_ws = |i: &mut usize| {
        while *i < n && (c[*i] == ' ' || c[*i] == '\t') {
            *i += 1;
        }
    };
    let skip_eol = |i: &mut usize| {
        while *i < n && c[*i] != '\n' {
            *i += 1;
        }
    };

    while i < n {
        skip_ws(&mut i);
        if i >= n {
            break;
        }
        if c[i] == '\n' {
            i += 1;
            line += 1;
            continue;
        }
        if c[i] == '#' {
            skip_eol(&mut i);
            continue;
        }
        let entry_line = line;

        // Prefixo `export ` opcional — comum em .env estilo shell.
        if i + 6 < n
            && c[i..i + 6].iter().copied().eq("export".chars())
            && (c[i + 6] == ' ' || c[i + 6] == '\t')
        {
            i += 6;
            skip_ws(&mut i);
        }

        let mut key = String::new();
        while i < n && !matches!(c[i], '=' | '\n' | ' ' | '\t') {
            key.push(c[i]);
            i += 1;
        }
        let mut space_before = false;
        if i < n && (c[i] == ' ' || c[i] == '\t') {
            space_before = true;
            skip_ws(&mut i);
        }
        if i >= n || c[i] != '=' {
            out.diagnostics
                .push(Diagnostic::error(entry_line, "Sem '='. Linha ignorada."));
            skip_eol(&mut i);
            continue;
        }
        i += 1;

        let Some(env_key) = EnvKey::new(key.clone()) else {
            out.diagnostics.push(Diagnostic::error(
                entry_line,
                if key.is_empty() {
                    "Falta o nome da variável antes do '='. Linha ignorada.".to_owned()
                } else {
                    format!("'{key}' não é um nome de variável válido. Linha ignorada.")
                },
            ));
            skip_eol(&mut i);
            continue;
        };

        let mut space_after = false;
        if i < n && (c[i] == ' ' || c[i] == '\t') {
            space_after = true;
            skip_ws(&mut i);
        }
        if space_before || space_after {
            out.diagnostics.push(Diagnostic::warning(
                entry_line,
                "Espaço em volta do '='. Um shell leria isto como comando, não como atribuição.",
            ));
        }

        let mut value = String::new();
        let mut failed = false;
        if i < n && (c[i] == '\'' || c[i] == '"') {
            // Semântica de palavra do shell: trechos com e sem aspas colados se
            // juntam — é o que faz a própria saída do HyperEnv voltar inteira
            // ('it'\''s' -> it's).
            'runs: while i < n && c[i] != '\n' {
                match c[i] {
                    '\'' => {
                        i += 1;
                        let mut closed = false;
                        while i < n {
                            if c[i] == '\'' {
                                i += 1;
                                closed = true;
                                break;
                            }
                            if c[i] == '\n' {
                                line += 1;
                            }
                            value.push(c[i]);
                            i += 1;
                        }
                        if !closed {
                            out.diagnostics.push(Diagnostic::error(
                                entry_line,
                                "Aspa simples sem fechar. Linha ignorada.",
                            ));
                            failed = true;
                            break 'runs;
                        }
                    }
                    '"' => {
                        i += 1;
                        let mut closed = false;
                        while i < n {
                            if c[i] == '"' {
                                i += 1;
                                closed = true;
                                break;
                            }
                            if c[i] == '\\' && i + 1 < n {
                                i += 1;
                                unescape(c[i], &mut value);
                                i += 1;
                                continue;
                            }
                            if c[i] == '\n' {
                                line += 1;
                            }
                            value.push(c[i]);
                            i += 1;
                        }
                        if !closed {
                            out.diagnostics.push(Diagnostic::error(
                                entry_line,
                                "Aspa dupla sem fechar. Linha ignorada.",
                            ));
                            failed = true;
                            break 'runs;
                        }
                    }
                    ' ' | '\t' => break 'runs,
                    '\\' => {
                        i += 1;
                        if i < n {
                            value.push(c[i]);
                            i += 1;
                        }
                    }
                    other => {
                        value.push(other);
                        i += 1;
                    }
                }
            }
            skip_eol(&mut i);
        } else {
            // Valor sem aspas: semântica de dotenv. O resto da linha, menos um
            // ` # comentário` no fim. Um '#' *sem* espaço antes faz parte do
            // valor (fragmento de URL, cor em hex).
            let mut bare = String::new();
            while i < n && c[i] != '\n' {
                bare.push(c[i]);
                i += 1;
            }
            if let Some(pos) = bare.find(" #").or_else(|| bare.find("\t#")) {
                bare.truncate(pos);
            }
            value = bare.trim_matches([' ', '\t']).to_owned();
        }

        // Aspa sem fechar: a mensagem diz "linha ignorada", então ignora de
        // fato. (A versão Swift ainda gravava o valor parcial.)
        if failed {
            continue;
        }
        if value.len() > limits.max_value_bytes {
            out.diagnostics.push(Diagnostic::error(
                entry_line,
                format!(
                    "O valor de {env_key} passa de {} KB. Ignorado.",
                    limits.max_value_bytes / 1024
                ),
            ));
            continue;
        }
        out.entries.push(Entry {
            key: env_key,
            value: EnvValue::new(value),
            line: entry_line,
        });
        if out.entries.len() > limits.max_entries {
            out.diagnostics.push(Diagnostic::error(
                entry_line,
                format!("Mais de {} entradas. Parei aqui.", limits.max_entries),
            ));
            break;
        }
    }

    let mut seen: std::collections::HashMap<&EnvKey, usize> = std::collections::HashMap::new();
    let mut warnings = Vec::new();
    for e in &out.entries {
        if let Some(first) = seen.get(&e.key) {
            warnings.push(Diagnostic::warning(
                e.line,
                format!(
                    "{} já foi definida na linha {first}. Vale o valor de baixo.",
                    e.key
                ),
            ));
        }
        seen.insert(&e.key, e.line);
    }
    out.diagnostics.extend(warnings);
    out
}

fn unescape(c: char, into: &mut String) {
    match c {
        'n' => into.push('\n'),
        'r' => into.push('\r'),
        't' => into.push('\t'),
        '\\' => into.push('\\'),
        '"' => into.push('"'),
        '$' => into.push('$'),
        // Escape desconhecido mantém a barra, como o shell faz em aspas duplas.
        other => {
            into.push('\\');
            into.push(other);
        }
    }
}
