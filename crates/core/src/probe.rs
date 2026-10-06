//! Parses NUL-separated `env -0` output that follows a marker.

use crate::types::{EnvKey, EnvSet, EnvValue, Error};

/// Everything the probe prints before this marker is discarded.
///
/// An interactive shell runs the user's prompt framework, plugin managers and
/// completion setup, any of which may print banners to stdout. Framing the
/// real payload is what makes the probe survive a chatty `.zshrc`.
pub const SENTINEL: &str = "<<<HYPERENV-ENV-BEGIN>>>";

/// Records are NUL-separated — the only byte that cannot appear inside a
/// value — so newlines inside values round-trip intact.
pub fn parse_nul_separated(data: &[u8]) -> Result<EnvSet, Error> {
    let marker = SENTINEL.as_bytes();
    let start = data
        .windows(marker.len())
        .position(|w| w == marker)
        .ok_or(Error::ProbeSentinelMissing)?
        + marker.len();

    let mut out = EnvSet::new();
    for record in data[start..].split(|&b| b == 0).filter(|r| !r.is_empty()) {
        // Decoded per record, so one undecodable value cannot discard the rest.
        let Ok(text) = std::str::from_utf8(record) else {
            continue;
        };
        let Some((name, value)) = text.split_once('=') else {
            continue;
        };
        // The marker is often followed by a newline before the first NUL.
        let name = name.trim_start_matches(['\n', '\r']);
        let Some(key) = EnvKey::new(name) else { continue };
        out.insert(key, EnvValue::new(value));
    }
    Ok(out)
}
