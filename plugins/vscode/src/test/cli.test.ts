// Plain Node tests: no VS Code needed. `cli.ts` never imports `vscode`.
//
// The fixtures in src/test/fixtures are real output of `hyperenv` 2.0.0-alpha.3,
// captured with `hyperenv --home <temp> --json …` (see the README). Parsing
// them proves the extension reads what the command really prints.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  CliError,
  HyperEnvCli,
  INSTALL_UNIX,
  Runner,
  changedSinceApplied,
  isExecutable,
  isSupportedVersion,
  isValidKey,
  bundledCandidates,
  ensureExecutable,
  locate,
  majorVersion,
  parseApply,
  parseAssignment,
  parseEnvelope,
  parseImport,
  parseProfiles,
  parseStatus,
  parseUnapply,
  parseVariables,
} from "../cli";

// Compiled to out/test; the fixtures stay in src/test (not shipped in the .vsix).
const fixture = (name: string) => readFileSync(join(__dirname, "..", "..", "src", "test", "fixtures", `${name}.json`), "utf8");
const data = (name: string) => parseEnvelope(fixture(name));

// ---------------------------------------------------------------- envelope

test("ok envelope yields its data", () => {
  assert.deepEqual(data("version"), { version: "2.0.0-alpha.3" });
});

test("error envelope becomes CliError with the command's message", () => {
  assert.throws(() => data("error"), (e: unknown) => e instanceof CliError && e.message === '"dev" is applied. Undo it before deleting.');
});

test("non-JSON output is a CliError, not a crash", () => {
  assert.throws(() => parseEnvelope("Segmentation fault"), (e: unknown) => e instanceof CliError && /not JSON/.test(e.message));
});

// ------------------------------------------------------------------- model

test("profiles: real list parses, applied one marked", () => {
  const profiles = parseProfiles(data("profiles"));
  assert.equal(profiles.length, 2);
  assert.deepEqual(
    profiles.map((p) => [p.name, p.variableCount, p.enabledCount, p.isApplied]),
    [["dev", 3, 2, true], ["empty", 0, 0, false]],
  );
  assert.match(profiles[0].id, /^[0-9a-f-]{36}$/);
});

test("variables: values in full, secret and off flags kept", () => {
  const vars = parseVariables(data("vars"));
  assert.deepEqual(vars, [
    { key: "API_URL", value: "https://api.local/v1?a=b", isSecret: false, isEnabled: true },
    { key: "TOKEN", value: "s3cret", isSecret: true, isEnabled: true },
    { key: "DEBUG", value: "1", isSecret: false, isEnabled: false },
  ]);
});

test("status with nothing applied: `applied` absent", () => {
  const status = parseStatus(data("status-none"));
  assert.equal(status.applied, undefined);
  assert.equal(status.version, "2.0.0-alpha.3");
  assert.equal(status.hook, "notInstalled");
  assert.deepEqual(status.drift, []);
  assert.equal(status.reloadCommand, "source ~/.config/hyperenv/session.zsh");
  assert.equal(status.undoCommand, "source ~/.config/hyperenv/unsession.zsh");
});

test("status with a profile applied carries its exports", () => {
  const status = parseStatus(data("status-applied"));
  assert.equal(status.applied?.profileName, "dev");
  assert.deepEqual(status.applied?.exportedKeys, ["API_URL", "TOKEN"]);
  assert.deepEqual(status.applied?.exports, { API_URL: "https://api.local/v1?a=b", TOKEN: "s3cret" });
  assert.equal(status.hook, "installed");
  assert.equal(status.startupFile, "~/.zprofile");
});

test("status drift items parse (shape from the README; hard to provoke for real)", () => {
  const raw = JSON.parse(fixture("status-applied"));
  raw.data.drift = [{ kind: "shadowed", key: "API_URL", expected: "a", actual: "b" }, { kind: "hookMissing" }];
  const status = parseStatus(parseEnvelope(JSON.stringify(raw)));
  assert.equal(status.drift.length, 2);
  assert.deepEqual(status.drift[0], { kind: "shadowed", key: "API_URL", expected: "a", actual: "b" });
  assert.equal(status.drift[1].key, undefined);
});

test("apply, unapply, import and export results parse", () => {
  const apply = parseApply(data("apply"));
  assert.equal(apply.applied, "dev");
  assert.deepEqual(apply.exported, ["API_URL", "TOKEN"]);
  assert.equal(apply.reloadCommand, "source ~/.config/hyperenv/session.zsh");
  const undo = parseUnapply(data("unapply"));
  assert.deepEqual(undo.restored, [{ key: "API_URL", to: null }, { key: "TOKEN", to: null }]);
  const imported = parseImport(data("import"));
  assert.equal(imported.imported, 2);
  assert.equal(imported.diagnostics[0].line, 3);
  assert.match((data("export") as { text: string }).text, /^API_URL="https:\/\/api.local\/v1\?a=b"$/m);
});

test("a 1.x-shaped status is rejected with a clear error", () => {
  assert.throws(() => parseStatus({ version: "1.4.0", hook: "installed", drift: [], dotfile: "~/.zprofile" }), CliError);
});

test("changed since applied: compares enabled variables with the exports", () => {
  const vars = parseVariables(data("vars"));
  const exports = parseStatus(data("status-applied")).applied!.exports;
  assert.equal(changedSinceApplied(vars, exports), false); // DEBUG is off, so not exported
  assert.equal(changedSinceApplied(vars.map((v) => (v.key === "TOKEN" ? { ...v, value: "new" } : v)), exports), true);
  assert.equal(changedSinceApplied(vars.map((v) => ({ ...v, isEnabled: true })), exports), true);
  assert.equal(changedSinceApplied(vars.filter((v) => v.key !== "TOKEN"), exports), true);
});

// ----------------------------------------------------------------- version

test("version: 2.x and later accepted, 1.x and garbage refused", () => {
  assert.equal(majorVersion("2.0.0-alpha.3"), 2);
  assert.ok(isSupportedVersion((data("version") as { version: string }).version));
  assert.ok(isSupportedVersion("10.1.0"));
  assert.ok(!isSupportedVersion("1.9.9"));
  assert.ok(!isSupportedVersion(""));
  assert.ok(!isSupportedVersion("dev"));
});

// ------------------------------------------------------------------ locate

const mac = { platform: "darwin" as const, home: "/Users/me", path: "/usr/bin:/opt/homebrew/bin" };
const only = (...files: string[]) => (f: string) => files.includes(f);

test("locate: an explicit setting wins; one that points nowhere is ignored", () => {
  assert.equal(locate("/tmp/my/hyperenv", mac, only("/tmp/my/hyperenv", "/opt/homebrew/bin/hyperenv")), "/tmp/my/hyperenv");
  assert.equal(locate("/tmp/nope", mac, only("/opt/homebrew/bin/hyperenv")), "/opt/homebrew/bin/hyperenv");
});

test("locate (macOS): the app's copy beats PATH, /Applications before ~/Applications", () => {
  const app = "/Applications/HyperEnv.app/Contents/Helpers/hyperenv";
  const userApp = "/Users/me/Applications/HyperEnv.app/Contents/Helpers/hyperenv";
  assert.equal(locate("", mac, only(app, userApp, "/usr/bin/hyperenv")), app);
  assert.equal(locate("", mac, only(userApp, "/usr/bin/hyperenv")), userApp);
});

test("locate: PATH beats the installer location, which is the last resort", () => {
  const local = "/Users/me/.local/bin/hyperenv";
  assert.equal(locate(undefined, mac, only("/opt/homebrew/bin/hyperenv", local)), "/opt/homebrew/bin/hyperenv");
  assert.equal(locate(undefined, mac, only(local)), local);
  assert.equal(locate(undefined, mac, () => false), undefined);
});

test("locate (Linux): no app bundle; ~/.local/bin after PATH", () => {
  const linux = { platform: "linux" as const, home: "/home/me", path: "/usr/bin" };
  const seen: string[] = [];
  locate(undefined, linux, (f) => (seen.push(f), false));
  assert.deepEqual(seen, ["/usr/bin/hyperenv", "/home/me/.local/bin/hyperenv"]);
});

test("locate (Windows): hyperenv.exe on PATH, then %LOCALAPPDATA%\\Programs\\hyperenv", () => {
  const win = { platform: "win32" as const, home: "C:\\Users\\me", path: "C:\\Tools;C:\\Bin", localAppData: "C:\\Users\\me\\AppData\\Local" };
  const seen: string[] = [];
  locate(undefined, win, (f) => (seen.push(f), false));
  assert.deepEqual(seen, ["C:\\Tools\\hyperenv.exe", "C:\\Bin\\hyperenv.exe", "C:\\Users\\me\\AppData\\Local\\Programs\\hyperenv\\hyperenv.exe"]);
});

test("locate: the bundled copy is the very last resort, after the installers' places", () => {
  const ext = { ...mac, extensionPath: "/ext" };
  const bundled = "/ext/bin/hyperenv";
  const seen: string[] = [];
  locate(undefined, ext, (f) => (seen.push(f), false));
  assert.equal(seen[seen.length - 1], bundled);
  assert.equal(seen.indexOf("/Users/me/.local/bin/hyperenv"), seen.length - 2);
  assert.equal(locate(undefined, ext, only(bundled)), bundled);
  assert.equal(locate(undefined, ext, only(bundled, "/usr/bin/hyperenv")), "/usr/bin/hyperenv");
  assert.equal(locate("/tmp/mine", ext, only(bundled, "/tmp/mine")), "/tmp/mine");
  assert.equal(locate(undefined, mac, only(bundled)), undefined);
});

test("bundled candidate: bin/hyperenv, or bin\\hyperenv.exe on Windows", () => {
  assert.deepEqual(bundledCandidates({ platform: "linux", home: "/h", extensionPath: "/ext" }), ["/ext/bin/hyperenv"]);
  assert.deepEqual(bundledCandidates({ platform: "win32", home: "C:\\h", extensionPath: "C:\\ext" }), ["C:\\ext\\bin\\hyperenv.exe"]);
  assert.deepEqual(bundledCandidates({ platform: "linux", home: "/h" }), []);
});

test("ensureExecutable restores a dropped execute bit", { skip: process.platform === "win32" }, () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-bin-"));
  const file = join(dir, "hyperenv");
  writeFileSync(file, "#!/bin/sh\n", { mode: 0o644 });
  assert.equal(isExecutable(file), false);
  ensureExecutable(file);
  assert.equal(isExecutable(file), true);
  ensureExecutable(join(dir, "missing"));
  rmSync(dir, { recursive: true, force: true });
});

test("install command is the documented one", () => {
  assert.equal(INSTALL_UNIX, "curl -fsSL https://hyperenv.falcaosl.com/install-cli.sh | sh");
});

// ------------------------------------------------------------------- client

test("client builds the 2.x grammar: --json first, profile positional, no --project", async () => {
  const calls: string[][] = [];
  const runner: Runner = async (_exe, args) => {
    calls.push(args);
    return '{"ok":true,"data":{"message":"done"}}';
  };
  const cli = new HyperEnvCli("/x/hyperenv", runner, ["--home", "/tmp/h"]);
  assert.equal(await cli.setVariable("dev", "API_URL", "a=b", true), "done");
  await cli.setVariable("dev", "API_URL", "x");
  await cli.setVariable("dev", "API_URL", "x", false);
  await cli.setEnabled("dev", "API_URL", false);
  await cli.renameProfile("dev", "staging");
  await cli.duplicateProfile("dev", "dev copy");
  assert.deepEqual(calls, [
    ["--home", "/tmp/h", "--json", "var", "set", "dev", "API_URL=a=b", "--secret"],
    ["--home", "/tmp/h", "--json", "var", "set", "dev", "API_URL=x"],
    ["--home", "/tmp/h", "--json", "var", "set", "dev", "API_URL=x", "--no-secret"],
    ["--home", "/tmp/h", "--json", "var", "disable", "dev", "API_URL"],
    ["--home", "/tmp/h", "--json", "profile", "rename", "dev", "staging"],
    ["--home", "/tmp/h", "--json", "profile", "duplicate", "dev", "dev copy"],
  ]);
});

test("client surfaces the command's error", async () => {
  const cli = new HyperEnvCli("/x/hyperenv", async () => fixture("error"));
  await assert.rejects(cli.deleteProfile("dev"), (e: unknown) => e instanceof CliError && /Undo it before deleting/.test(e.message));
});

// ------------------------------------------------------------------ helpers

test("NAME=value: the first = splits; bad names refused", () => {
  assert.deepEqual(parseAssignment("API_URL=https://x?a=b"), { key: "API_URL", value: "https://x?a=b" });
  assert.deepEqual(parseAssignment(" EMPTY ="), { key: "EMPTY", value: "" });
  assert.equal(parseAssignment("NOVALUE"), undefined);
  assert.equal(parseAssignment("=x"), undefined);
  assert.equal(parseAssignment("1BAD=x"), undefined);
});

test("variable-name rule agrees with the engine's EnvKey", () => {
  assert.ok(isValidKey("API_URL"));
  assert.ok(isValidKey("_x1"));
  assert.ok(!isValidKey("1BAD"));
  assert.ok(!isValidKey("MY-VAR"));
  assert.ok(!isValidKey(""));
});
