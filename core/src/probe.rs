//! Lê a saída do `env -0` (ou equivalente) depois de um marcador.

use crate::types::{EnvKey, EnvSet, EnvValue, Error};

/// Tudo o que a sondagem imprime antes disto é descartado.
///
/// Um shell interativo roda o framework de prompt, gerenciadores de plugin e
/// completions, e qualquer um deles pode imprimir banner no stdout. Enquadrar
/// a carga útil é o que faz a sondagem sobreviver a um `.zshrc` falador.
pub const SENTINEL: &str = "<<<HYPERENV-ENV-BEGIN>>>";

/// Registros separados por NUL — o único byte que não aparece num valor, então
/// quebras de linha dentro de valores voltam intactas.
pub fn parse_nul_separated(data: &[u8]) -> Result<EnvSet, Error> {
    let marker = SENTINEL.as_bytes();
    let start = data
        .windows(marker.len())
        .position(|w| w == marker)
        .ok_or(Error::ProbeSentinelMissing)?
        + marker.len();

    let mut out = EnvSet::new();
    for record in data[start..].split(|&b| b == 0).filter(|r| !r.is_empty()) {
        // Decodificado por registro: um valor ilegível não derruba o ambiente todo.
        let Ok(text) = std::str::from_utf8(record) else {
            continue;
        };
        let Some((name, value)) = text.split_once('=') else {
            continue;
        };
        // O marcador costuma vir seguido de quebra de linha antes do primeiro NUL.
        let name = name.trim_start_matches(['\n', '\r']);
        let Some(key) = EnvKey::new(name) else { continue };
        out.insert(key, EnvValue::new(value));
    }
    Ok(out)
}
