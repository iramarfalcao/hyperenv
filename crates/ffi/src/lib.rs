//! The C interface the macOS app links against.
//!
//! Deliberately one call wide. The app sends a command line — the same
//! grammar as the `hyperenv` command — as a JSON array of strings, and gets
//! back the same `--json` envelope the command prints:
//!
//! ```text
//! ["vars", "api-dev"]  →  {"ok":true,"data":[{"key":"PORT","value":"8080",…}]}
//! ```
//!
//! So the window, the terminal and the editor plugins share one contract,
//! already covered by the command's tests, and nothing crosses the boundary
//! but UTF-8 text. `--json` is always on.

use std::ffi::{CStr, CString, c_char};

/// Runs one command. `argv_json` is a NUL-terminated UTF-8 JSON array of
/// strings. Returns a NUL-terminated UTF-8 JSON envelope that the caller must
/// release with `hyperenv_free`. Never returns NULL; never unwinds.
///
/// # Safety
/// `argv_json` must be a valid pointer to a NUL-terminated string, or NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyperenv_run(argv_json: *const c_char) -> *mut c_char {
    let envelope = std::panic::catch_unwind(|| {
        if argv_json.is_null() {
            return error("no arguments");
        }
        // SAFETY: the caller guarantees a NUL-terminated string.
        let raw = unsafe { CStr::from_ptr(argv_json) };
        let Ok(text) = raw.to_str() else {
            return error("arguments are not UTF-8");
        };
        let Ok(mut args) = serde_json::from_str::<Vec<String>>(text) else {
            return error("arguments must be a JSON array of strings");
        };
        if !args.iter().any(|a| a == "--json") {
            args.insert(0, "--json".into());
        }
        let out = hyperenv_cli::execute(args);
        let body = out.stdout.trim_end();
        if body.is_empty() {
            error(out.stderr.trim())
        } else {
            body.to_owned()
        }
    })
    .unwrap_or_else(|_| error("internal error"));

    // An interior NUL cannot come out of serde_json, but never trust that
    // enough to hand back a NULL.
    CString::new(envelope)
        .unwrap_or_else(|_| CString::new(error("invalid output")).unwrap())
        .into_raw()
}

/// Releases a string returned by `hyperenv_run`. NULL is ignored.
///
/// # Safety
/// `s` must come from `hyperenv_run` and must not be used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyperenv_free(s: *mut c_char) {
    if !s.is_null() {
        // SAFETY: allocated by CString::into_raw in hyperenv_run.
        drop(unsafe { CString::from_raw(s) });
    }
}

fn error(message: &str) -> String {
    serde_json::json!({ "ok": false, "error": message }).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(args: &str) -> serde_json::Value {
        let input = CString::new(args).unwrap();
        // SAFETY: valid NUL-terminated input; the result is freed below.
        unsafe {
            let out = hyperenv_run(input.as_ptr());
            let text = CStr::from_ptr(out).to_str().unwrap().to_owned();
            hyperenv_free(out);
            serde_json::from_str(&text).unwrap()
        }
    }

    #[test]
    fn runs_the_commands_grammar_and_returns_the_envelope() {
        let home = std::env::temp_dir().join(format!("hyperenv-ffi-{}", std::process::id()));
        let h = home.to_str().unwrap();
        assert_eq!(
            call(&format!(r#"["--home","{h}","profile","create","dev"]"#))["ok"],
            true
        );
        assert_eq!(
            call(&format!(r#"["--home","{h}","var","set","dev","PORT=8080"]"#))["ok"],
            true
        );
        let vars = call(&format!(r#"["--home","{h}","vars","dev"]"#));
        assert_eq!(vars["data"][0]["value"], "8080");
        assert_eq!(call(&format!(r#"["--home","{h}","vars","nope"]"#))["ok"], false);
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn bad_input_is_an_error_envelope_not_a_crash() {
        assert_eq!(call("not json")["ok"], false);
        assert_eq!(call("[1,2]")["ok"], false);
        assert_eq!(call(r#"["fly"]"#)["ok"], false);
        // SAFETY: NULL is documented as accepted.
        let out = unsafe { hyperenv_run(std::ptr::null()) };
        unsafe { hyperenv_free(out) };
    }
}
