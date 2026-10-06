// The client for HyperEnv's `hyperenv` command. No `vscode` import on
// purpose: this file is unit-tested with plain Node, and the extension wires it
// up.
//
// The command drives the same engine and store as the desktop apps, so this
// extension never carries an engine of its own. Shapes mirror
// crates/cli/README.md in the repository.

import { execFile } from "node:child_process";
import { accessSync, chmodSync, constants, statSync } from "node:fs";
import { posix, win32 } from "node:path";

// ------------------------------------------------------------------- model

export interface Profile {
  id: string;
  name: string;
  variableCount: number;
  enabledCount: number;
  isApplied: boolean;
  updatedAt: string;
}

export interface Variable {
  key: string;
  value: string;
  isSecret: boolean;
  isEnabled: boolean;
}

export interface Applied {
  profileId: string;
  profileName: string;
  appliedAt: string;
  exportedKeys: string[];
  exports: Record<string, string>;
}

export interface Drift {
  kind: string;
  key?: string;
  expected?: string;
  actual?: string;
}

export interface Status {
  version: string;
  shell: string;
  hook: string;
  hookDetail?: string;
  applied?: Applied;
  drift: Drift[];
  pendingRecoveries: number;
  reloadCommand: string;
  undoCommand: string;
  sessionScript: string;
  startupFile?: string;
  store: string;
}

export interface Restored {
  key: string;
  to: string | null;
}

export interface ApplyResult {
  applied: string;
  exported: string[];
  captured: string[];
  restored: Restored[];
  reloadCommand: string;
  undoCommand: string;
}

export interface UnapplyResult {
  restored: Restored[];
  undoCommand: string;
}

export interface ImportResult {
  imported: number;
  diagnostics: { line: number; message: string; severity: string }[];
}

export class CliError extends Error {}

// ---------------------------------------------------------------- envelope

/** Unwraps `{"ok":…}`; the command's own message becomes the error. */
export function parseEnvelope(text: string): unknown {
  let doc: unknown;
  try {
    doc = JSON.parse(text);
  } catch {
    throw new CliError(`the hyperenv command returned something that is not JSON: ${text.slice(0, 200)}`);
  }
  if (typeof doc !== "object" || doc === null) throw new CliError(`unexpected output: ${text.slice(0, 200)}`);
  const envelope = doc as { ok?: boolean; data?: unknown; error?: string };
  if (envelope.ok !== true) throw new CliError(envelope.error ?? "unknown error");
  return envelope.data ?? {};
}

// Light shape checks: if the command and the extension ever disagree (an old
// 1.x command, say), the user gets a clear message instead of `undefined` deep
// inside the tree.
function obj(value: unknown, what: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new CliError(`unexpected ${what} from the hyperenv command`);
  }
  return value as Record<string, unknown>;
}

function str(o: Record<string, unknown>, key: string, what: string): string {
  if (typeof o[key] !== "string") throw new CliError(`unexpected ${what} from the hyperenv command (no ${key})`);
  return o[key] as string;
}

function arr(value: unknown, what: string): unknown[] {
  if (!Array.isArray(value)) throw new CliError(`unexpected ${what} from the hyperenv command`);
  return value;
}

function strings(value: unknown): string[] {
  return Array.isArray(value) ? value.map(String) : [];
}

function restored(value: unknown): Restored[] {
  if (!Array.isArray(value)) return [];
  return value.map((r) => {
    const o = obj(r, "restored variable");
    return { key: String(o.key), to: typeof o.to === "string" ? o.to : null };
  });
}

export function parseProfiles(data: unknown): Profile[] {
  return arr(data, "profile list").map((item) => {
    const o = obj(item, "profile");
    return {
      id: str(o, "id", "profile"),
      name: str(o, "name", "profile"),
      variableCount: Number(o.variableCount ?? 0),
      enabledCount: Number(o.enabledCount ?? 0),
      isApplied: o.isApplied === true,
      updatedAt: String(o.updatedAt ?? ""),
    };
  });
}

export function parseVariables(data: unknown): Variable[] {
  return arr(data, "variable list").map((item) => {
    const o = obj(item, "variable");
    return {
      key: str(o, "key", "variable"),
      value: str(o, "value", "variable"),
      isSecret: o.isSecret === true,
      isEnabled: o.isEnabled !== false,
    };
  });
}

export function parseStatus(data: unknown): Status {
  const o = obj(data, "status");
  let applied: Applied | undefined;
  // Absent, not null, means nothing is applied.
  if (o.applied !== undefined) {
    const a = obj(o.applied, "applied profile");
    const exports: Record<string, string> = {};
    if (a.exports && typeof a.exports === "object") {
      for (const [k, v] of Object.entries(a.exports as Record<string, unknown>)) exports[k] = String(v);
    }
    applied = {
      profileId: str(a, "profileId", "applied profile"),
      profileName: str(a, "profileName", "applied profile"),
      appliedAt: String(a.appliedAt ?? ""),
      exportedKeys: strings(a.exportedKeys),
      exports,
    };
  }
  const drift = Array.isArray(o.drift)
    ? o.drift.map((d) => {
        const x = obj(d, "drift item");
        return {
          kind: String(x.kind),
          key: typeof x.key === "string" ? x.key : undefined,
          expected: typeof x.expected === "string" ? x.expected : undefined,
          actual: typeof x.actual === "string" ? x.actual : undefined,
        };
      })
    : [];
  return {
    version: str(o, "version", "status"),
    shell: String(o.shell ?? ""),
    hook: String(o.hook ?? ""),
    hookDetail: typeof o.hookDetail === "string" ? o.hookDetail : undefined,
    applied,
    drift,
    pendingRecoveries: Number(o.pendingRecoveries ?? 0),
    reloadCommand: str(o, "reloadCommand", "status"),
    undoCommand: str(o, "undoCommand", "status"),
    sessionScript: String(o.sessionScript ?? ""),
    startupFile: typeof o.startupFile === "string" ? o.startupFile : undefined,
    store: String(o.store ?? ""),
  };
}

export function parseApply(data: unknown): ApplyResult {
  const o = obj(data, "apply result");
  return {
    applied: str(o, "applied", "apply result"),
    exported: strings(o.exported),
    captured: strings(o.captured),
    restored: restored(o.restored),
    reloadCommand: str(o, "reloadCommand", "apply result"),
    undoCommand: str(o, "undoCommand", "apply result"),
  };
}

export function parseUnapply(data: unknown): UnapplyResult {
  const o = obj(data, "undo result");
  return { restored: restored(o.restored), undoCommand: String(o.undoCommand ?? "") };
}

export function parseImport(data: unknown): ImportResult {
  const o = obj(data, "import result");
  const diagnostics = Array.isArray(o.diagnostics)
    ? o.diagnostics.map((d) => {
        const x = obj(d, "import diagnostic");
        return { line: Number(x.line ?? 0), message: String(x.message ?? ""), severity: String(x.severity ?? "") };
      })
    : [];
  return { imported: Number(o.imported ?? 0), diagnostics };
}

// ----------------------------------------------------------------- version

/** The extension speaks the 2.x grammar only; 1.x had projects and kinds. */
export const MIN_MAJOR = 2;

/** "2.0.0-alpha.3" -> 2; anything unreadable -> undefined. */
export function majorVersion(version: string): number | undefined {
  const match = /^v?(\d+)(\.|$)/.exec(version.trim());
  return match ? Number(match[1]) : undefined;
}

export function isSupportedVersion(version: string): boolean {
  const major = majorVersion(version);
  return major !== undefined && major >= MIN_MAJOR;
}

// ------------------------------------------------------------------ locate

export const INSTALL_UNIX = "curl -fsSL https://hyperenv.falcaosl.com/install-cli.sh | sh";
export const INSTALL_WINDOWS = "irm https://hyperenv.falcaosl.com/install.ps1 | iex";

export interface LocateEnv {
  platform: NodeJS.Platform;
  home: string;
  path?: string;
  localAppData?: string;
  /** The extension's own folder; platform-specific packages carry `bin/hyperenv[.exe]` there. */
  extensionPath?: string;
}

/** The copy inside the macOS app, looked at before PATH: it is the one the app itself uses. */
export function appCandidates(env: LocateEnv): string[] {
  if (env.platform !== "darwin") return [];
  return [
    "/Applications/HyperEnv.app/Contents/Helpers/hyperenv",
    posix.join(env.home, "Applications", "HyperEnv.app", "Contents", "Helpers", "hyperenv"),
  ];
}

/** Where the install scripts put the command; a fresh install may not be on PATH yet. */
export function installerCandidates(env: LocateEnv): string[] {
  if (env.platform === "win32") {
    return env.localAppData ? [win32.join(env.localAppData, "Programs", "hyperenv", "hyperenv.exe")] : [];
  }
  return [posix.join(env.home, ".local", "bin", "hyperenv")];
}

/** The copy bundled in a platform-specific package: the last resort, after anything the user installed. */
export function bundledCandidates(env: LocateEnv): string[] {
  if (!env.extensionPath) return [];
  return env.platform === "win32"
    ? [win32.join(env.extensionPath, "bin", "hyperenv.exe")]
    : [posix.join(env.extensionPath, "bin", "hyperenv")];
}

/**
 * VSIX extraction can drop the execute bit; put it back on the bundled copy so
 * `isExecutable` accepts it. Harmless when the file is absent or on Windows.
 */
export function ensureExecutable(file: string, platform: NodeJS.Platform = process.platform): void {
  if (platform === "win32") return;
  try {
    const mode = statSync(file).mode;
    if ((mode & 0o111) !== 0o111) chmodSync(file, 0o755);
  } catch {
    // Missing or read-only install: the lookup simply skips it.
  }
}

export function pathCandidates(env: LocateEnv): string[] {
  const windows = env.platform === "win32";
  const path = windows ? win32 : posix;
  const name = windows ? "hyperenv.exe" : "hyperenv";
  return (env.path ?? "")
    .split(windows ? ";" : ":")
    .filter(Boolean)
    .map((dir) => path.join(dir, name));
}

export function isExecutable(file: string): boolean {
  try {
    // Windows has no execute bit; existing is enough there.
    accessSync(file, process.platform === "win32" ? constants.F_OK : constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/** Setting, then the macOS app, then PATH, then the installers' places, then the bundled copy. Pure, for the tests. */
export function locate(
  override: string | undefined,
  env: LocateEnv,
  exists: (file: string) => boolean = isExecutable,
): string | undefined {
  const explicit = override?.trim();
  if (explicit && exists(explicit)) return explicit;
  return [...appCandidates(env), ...pathCandidates(env), ...installerCandidates(env), ...bundledCandidates(env)].find(
    exists,
  );
}

// ------------------------------------------------------------------- client

export type Runner = (executable: string, args: string[]) => Promise<string>;

/**
 * Runs the real binary, always asynchronously: apply, unapply and status start
 * the user's shell, and the editor must never wait on that. stdout carries the
 * envelope even on failure (exit 1).
 */
export const execRunner: Runner = (executable, args) =>
  new Promise((resolve, reject) => {
    execFile(executable, args, { timeout: 60_000, maxBuffer: 16 * 1024 * 1024, windowsHide: true }, (error, stdout, stderr) => {
      const out = String(stdout).trim();
      if (out) return resolve(out);
      if (error) return reject(new CliError(String(stderr).trim() || error.message));
      reject(new CliError("the hyperenv command printed nothing"));
    });
  });

export class HyperEnvCli {
  /** `prefix` goes before `--json`; the tests pass `--home <dir>` to stay off the real home. */
  constructor(
    readonly executable: string,
    private readonly runner: Runner = execRunner,
    private readonly prefix: string[] = [],
  ) {}

  private async run(...args: string[]): Promise<unknown> {
    return parseEnvelope(await this.runner(this.executable, [...this.prefix, "--json", ...args]));
  }

  private async message(...args: string[]): Promise<string> {
    const data = (await this.run(...args)) as { message?: unknown };
    return typeof data?.message === "string" ? data.message : "";
  }

  async version(): Promise<string> {
    return str(obj(await this.run("version"), "version"), "version", "version");
  }

  async status(options: { drift?: boolean } = {}): Promise<Status> {
    return parseStatus(await this.run("status", ...(options.drift === false ? ["--no-drift"] : [])));
  }

  async profiles(): Promise<Profile[]> {
    return parseProfiles(await this.run("profiles"));
  }

  async variables(profile: string): Promise<Variable[]> {
    // JSON values go out in full anyway; the tree decides what to mask.
    return parseVariables(await this.run("vars", profile));
  }

  createProfile(name: string): Promise<string> {
    return this.message("profile", "create", name);
  }

  renameProfile(name: string, newName: string): Promise<string> {
    return this.message("profile", "rename", name, newName);
  }

  duplicateProfile(name: string, newName: string): Promise<string> {
    return this.message("profile", "duplicate", name, newName);
  }

  deleteProfile(name: string): Promise<string> {
    return this.message("profile", "delete", name);
  }

  /** Omitting `secret` keeps an existing variable's flag (for a new one the engine guesses). */
  setVariable(profile: string, key: string, value: string, secret?: boolean): Promise<string> {
    const args = ["var", "set", profile, `${key}=${value}`];
    if (secret === true) args.push("--secret");
    if (secret === false) args.push("--no-secret");
    return this.message(...args);
  }

  setEnabled(profile: string, key: string, enabled: boolean): Promise<string> {
    return this.message("var", enabled ? "enable" : "disable", profile, key);
  }

  deleteVariable(profile: string, key: string): Promise<string> {
    return this.message("var", "delete", profile, key);
  }

  async importFile(profile: string, file: string): Promise<ImportResult> {
    return parseImport(await this.run("import", profile, file));
  }

  async exportDotenv(profile: string): Promise<string> {
    return str(obj(await this.run("export", profile, "--dialect", "dotenv"), "export"), "text", "export");
  }

  async apply(profile: string): Promise<ApplyResult> {
    return parseApply(await this.run("apply", profile));
  }

  async unapply(): Promise<UnapplyResult> {
    return parseUnapply(await this.run("unapply"));
  }
}

// ------------------------------------------------------------------ helpers

/** The same rule as the engine's EnvKey, so a bad name is caught before the round trip. */
export function isValidKey(key: string): boolean {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(key);
}

/** "NAME=value": the first `=` splits, as in the command, so the value may contain `=`. */
export function parseAssignment(text: string): { key: string; value: string } | undefined {
  const at = text.indexOf("=");
  if (at <= 0) return undefined;
  const key = text.slice(0, at).trim();
  return isValidKey(key) ? { key, value: text.slice(at + 1) } : undefined;
}

/**
 * True when the profile's enabled variables no longer match what was exported
 * at apply time: new terminals keep getting the old values until it is applied
 * again.
 */
export function changedSinceApplied(variables: Variable[], exports: Record<string, string>): boolean {
  const enabled = variables.filter((v) => v.isEnabled);
  if (enabled.length !== Object.keys(exports).length) return true;
  return enabled.some((v) => !Object.prototype.hasOwnProperty.call(exports, v.key) || exports[v.key] !== v.value);
}
