// The C interface to HyperEnv (crates/ffi). See crates/ffi/src/lib.rs.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Runs one command — the `hyperenv` command's grammar, as a JSON array of
// strings — and returns its JSON envelope. Free the result with hyperenv_free.
char *hyperenv_run(const char *argv_json);

// Releases a string returned by hyperenv_run. NULL is ignored.
void hyperenv_free(char *s);

#ifdef __cplusplus
}
#endif
