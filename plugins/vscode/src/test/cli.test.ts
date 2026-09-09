// Plain Node tests: no VS Code needed. `cli.ts` never imports `vscode`.
import { test } from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { CliError, HyperEnvCli, Runner, bundledCandidates, isValidKey, locate, parseEnvelope } from "../cli";

test("ok envelope yields its data", () => {
  assert.deepEqual(parseEnvelope('{"ok":true,"data":{"version":"1.2.3"}}'), { version: "1.2.3" });
});

test("error envelope becomes CliError with the command's message", () => {
  assert.throws(() => parseEnvelope('{"ok":false,"error":"no project named \\"nope\\""}'), (e: unknown) =>
    e instanceof CliError && e.message === 'no project named "nope"',
  );
});

test("non-JSON output is a CliError, not a crash", () => {
  assert.throws(() => parseEnvelope("Segmentation fault"), (e: unknown) => e instanceof CliError && /not JSON/.test(e.message));
});

test("status without applied means nothing is applied", () => {
  const status = parseEnvelope('{"ok":true,"data":{"version":"dev","hook":"notInstalled","drift":[],"reloadCommand":"x","dotfile":"~/.zprofile"}}') as { applied?: unknown };
  assert.equal(status.applied, undefined);
});

test("locate: an explicit setting wins", () => {
  const exists = (p: string) => p === "/tmp/my/hyperenv" || p === "/opt/homebrew/bin/hyperenv";
  assert.equal(locate("/tmp/my/hyperenv", "/opt/homebrew/bin", [], exists), "/tmp/my/hyperenv");
});

test("locate: a setting that points nowhere is ignored", () => {
  const exists = (p: string) => p === "/opt/homebrew/bin/hyperenv";
  assert.equal(locate("/tmp/nope", "/usr/bin:/opt/homebrew/bin", [], exists), "/opt/homebrew/bin/hyperenv");
});

test("locate: PATH beats the bundled copy", () => {
  const bundled = "/Applications/HyperEnv.app/Contents/Helpers/hyperenv";
  const exists = (p: string) => p === "/usr/local/bin/hyperenv" || p === bundled;
  assert.equal(locate("", "/usr/local/bin", [bundled], exists), "/usr/local/bin/hyperenv");
});

test("locate: the bundled copy is the fallback, and nothing found is undefined", () => {
  const bundled = bundledCandidates("/Users/me");
  assert.equal(bundled[1], join("/Users/me", "Applications", "HyperEnv.app", "Contents", "Helpers", "hyperenv"));
  assert.equal(locate(undefined, "", bundled, (p) => p === bundled[0]), bundled[0]);
  assert.equal(locate(undefined, "", bundled, () => false), undefined);
});

test("client passes --json first and builds var set exactly as the command expects", async () => {
  const calls: string[][] = [];
  const runner: Runner = async (_exe, args) => {
    calls.push(args);
    return '{"ok":true,"data":{"id":"v","key":"API_URL","value":"a=b","isEnabled":false,"isSecret":true,"isValid":true}}';
  };
  const cli = new HyperEnvCli("/x/hyperenv", runner);
  const variable = await cli.setVariable("payments", "dev", "API_URL", "a=b", { secret: true, enabled: false, note: "why" });
  assert.deepEqual(calls[0], ["--json", "var", "set", "--project", "payments", "--profile", "dev", "--secret", "--disabled", "--note", "why", "API_URL=a=b"]);
  assert.equal(variable.value, "a=b");
});

test("client surfaces the command's error", async () => {
  const cli = new HyperEnvCli("/x/hyperenv", async () => '{"ok":false,"error":"the Default profile … cannot be applied"}');
  await assert.rejects(cli.apply("p", "f"), (e: unknown) => e instanceof CliError && /cannot be applied/.test(e.message));
});

test("variable-name rule agrees with the app's EnvKey", () => {
  assert.ok(isValidKey("API_URL"));
  assert.ok(isValidKey("_x1"));
  assert.ok(!isValidKey("1BAD"));
  assert.ok(!isValidKey("MY-VAR"));
  assert.ok(!isValidKey(""));
});
