//! The `hyperenv` binary: runs the command line and prints what it produced.

use std::io::Write;
use std::process::ExitCode;

fn main() -> ExitCode {
    let out = hyperenv_cli::execute(std::env::args().skip(1).collect());
    let _ = std::io::stdout().write_all(out.stdout.as_bytes());
    let _ = std::io::stderr().write_all(out.stderr.as_bytes());
    ExitCode::from(out.code)
}
