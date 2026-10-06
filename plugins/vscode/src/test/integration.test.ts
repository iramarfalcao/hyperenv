// Runs the real `hyperenv` command end to end against a throwaway home, never
// the user's. Set HYPERENV_CLI to the binary (e.g. target/release/hyperenv);
// without it the test is skipped, so `npm test` works on a machine without one.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CliError, HyperEnvCli, changedSinceApplied, isSupportedVersion } from "../cli";

const binary = process.env.HYPERENV_CLI;
const skip = !binary || !existsSync(binary) ? "set HYPERENV_CLI to a built hyperenv to run" : false;

test("real command: create, set, list, apply, status, unapply", { skip, timeout: 60_000 }, async () => {
  const home = mkdtempSync(join(tmpdir(), "hyperenv-vscode-"));
  try {
    // --shell pins the probe to zsh so the result does not depend on the runner's $SHELL.
    const prefix = ["--home", home, ...(process.platform === "win32" ? [] : ["--shell", "/bin/zsh"])];
    const cli = new HyperEnvCli(binary!, undefined, prefix);

    assert.ok(isSupportedVersion(await cli.version()));
    await cli.createProfile("dev");
    await cli.setVariable("dev", "API_URL", "https://api.local/v1?a=b");
    await cli.setVariable("dev", "TOKEN", "s3cret", true);
    await cli.setVariable("dev", "DEBUG", "1");
    await cli.setEnabled("dev", "DEBUG", false);

    const [profile] = await cli.profiles();
    assert.equal(profile.name, "dev");
    assert.equal(profile.variableCount, 3);
    assert.equal(profile.enabledCount, 2);
    assert.equal(profile.isApplied, false);
    const vars = await cli.variables("dev");
    assert.equal(vars.find((v) => v.key === "TOKEN")?.isSecret, true);
    assert.equal(vars.find((v) => v.key === "TOKEN")?.value, "s3cret");

    assert.equal((await cli.status()).applied, undefined);
    const applied = await cli.apply("dev");
    assert.equal(applied.applied, "dev");
    assert.deepEqual([...applied.exported].sort(), ["API_URL", "TOKEN"]);
    assert.ok(applied.reloadCommand.length > 0);

    const status = await cli.status();
    assert.equal(status.applied?.profileName, "dev");
    assert.equal(changedSinceApplied(await cli.variables("dev"), status.applied!.exports), false);
    assert.equal((await cli.profiles())[0].isApplied, true);

    // Editing after apply makes it "changed since applied".
    await cli.setVariable("dev", "API_URL", "changed");
    assert.equal(changedSinceApplied(await cli.variables("dev"), (await cli.status({ drift: false })).applied!.exports), true);

    // The applied profile cannot be deleted.
    await assert.rejects(cli.deleteProfile("dev"), CliError);

    // Import and export round-trip through a .env file.
    const envFile = join(home, "in.env");
    writeFileSync(envFile, "A=1\nB=\"two\"\n");
    await cli.createProfile("other");
    assert.equal((await cli.importFile("other", envFile)).imported, 2);
    assert.match(await cli.exportDotenv("other"), /^B="two"$/m);

    const undone = await cli.unapply();
    assert.deepEqual(undone.restored.map((r) => r.key).sort(), ["API_URL", "TOKEN"]);
    assert.equal((await cli.status()).applied, undefined);
    await cli.deleteProfile("dev");
    assert.deepEqual((await cli.profiles()).map((p) => p.name), ["other"]);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});
