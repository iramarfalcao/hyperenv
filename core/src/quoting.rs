//! Aspas para cada destino. Cada shell tem a sua regra, e errar aqui é
//! injeção de comando no login do usuário.

/// Aspas simples POSIX (zsh, bash, sh): o único construto que desliga *toda*
/// interpretação — `$`, crase, `\`, `#`, `!`, espaço e quebra de linha passam
/// literais.
///
/// Aspa simples não escapa dentro de aspas simples, então fecha, insere e
/// reabre: `it's` vira `'it'\''s'`. Sempre com aspas, mesmo valor trivial:
/// consistência vale mais que saída bonita.
pub fn posix_single(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('\'');
    for c in value.chars() {
        if c == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(c);
        }
    }
    out.push('\'');
    out
}

/// Aspas simples do fish: lá dentro só `\'` e `\\` são escapes, todo o resto
/// (inclusive `$` e quebra de linha) é literal.
pub fn fish_single(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('\'');
    for c in value.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\'' => out.push_str("\\'"),
            _ => out.push(c),
        }
    }
    out.push('\'');
    out
}

/// Aspas simples do PowerShell: literais, e a aspa simples se dobra (`''`).
/// O PowerShell também trata as aspas tipográficas ‘ ’ ‚ ‛ como aspa simples,
/// então elas se dobram do mesmo jeito.
pub fn powershell_single(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('\'');
    for c in value.chars() {
        if matches!(c, '\'' | '\u{2018}' | '\u{2019}' | '\u{201A}' | '\u{201B}') {
            out.push(c);
        }
        out.push(c);
    }
    out.push('\'');
    out
}

/// Aspas duplas para parsers de dotenv, que em geral não implementam aspas
/// simples POSIX. Quebra de linha vira `\n`, porque a maioria não aceita uma
/// quebra literal dentro do valor.
pub fn dotenv_double(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for c in value.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '$' => out.push_str("\\$"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            _ => out.push(c),
        }
    }
    out.push('"');
    out
}
