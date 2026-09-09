// The client for the `hyperenv` command. No `vscode` import on purpose: this
// file is unit-tested with plain Node, and the extension wires it up.
//
// The command opens the same store and drives the same engine as the HyperEnv
// app, so this extension never carries an engine of its own. Shapes mirror
// docs/CLI.md in the repository root.

import { execFile } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { delimiter, join } from "node:path";

export interface EnvProfile {
  id: string;
  name: string;
  kind: string;
  isDefault: boolean;
  canBeApplied: boolean;
  isApplied: boolean;
  variableCount: number;
  enabledCount: number;
}

export interface EnvProject {
  id: string;
  name: string;
  isDefault: boolean;
  profiles: EnvProfile[];
}

export interface EnvVariable {
  id: string;
  key: string;
  value: string;
  isEnabled: boolean;
  isSecret: boolean;
  note?: string;
  isValid: boolean;
}

export interface Applied {
  projectId: string;
  projectName: string;
  profileId: string;
  profileName: string;
}

export interface Status {
  version: string;
  applied?: Applied;
  hook: "installed" | "notInstalled" | "malformed";
  hookDetail?: string;
  drift: string[];
  reloadCommand: string;
  dotfile: string;
}

export interface ApplyResult {
  exported: number;
  reloadCommand: string;
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

// ------------------------------------------------------------------ locate

/** Where the command may be, after the setting and PATH: inside the app. */
export function bundledCandidates(home: string): string[] {
  return [
    "/Applications/HyperEnv.app/Contents/Helpers/hyperenv",
    join(home, "Applications", "HyperEnv.app", "Contents", "Helpers", "hyperenv"),
  ];
}

export function isExecutable(path: string): boolean {
  try {
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/** Settings first, then PATH, then the bundled copy. Pure, for the tests. */
export function locate(
  override: string | undefined,
  pathEnv: string | undefined,
  candidates: string[],
  exists: (path: string) => boolean = isExecutable,
): string | undefined {
  const explicit = override?.trim();
  if (explicit && exists(explicit)) return explicit;
  for (const dir of (pathEnv ?? "").split(delimiter).filter(Boolean)) {
    const candidate = join(dir, "hyperenv");
    if (exists(candidate)) return candidate;
  }
  return candidates.find(exists);
}

// ------------------------------------------------------------------- client

export type Runner = (executable: string, args: string[]) => Promise<string>;

/** Runs the real binary. stdout carries the envelope even on failure. */
export const execRunner: Runner = (executable, args) =>
  new Promise((resolve, reject) => {
    execFile(executable, args, { timeout: 30_000, maxBuffer: 8 * 1024 * 1024 }, (error, stdout, stderr) => {
      const out = String(stdout).trim();
      if (out) return resolve(out);
      if (error) return reject(new CliError(String(stderr).trim() || error.message));
      reject(new CliError("the hyperenv command printed nothing"));
    });
  });

export class HyperEnvCli {
  constructor(
    private readonly executable: string,
    private readonly runner: Runner = execRunner,
  ) {}

  private async run(...args: string[]): Promise<unknown> {
    return parseEnvelope(await this.runner(this.executable, ["--json", ...args]));
  }

  status(): Promise<Status> {
    return this.run("status") as Promise<Status>;
  }

  projects(): Promise<EnvProject[]> {
    return this.run("projects") as Promise<EnvProject[]>;
  }

  variables(project: string, profile: string): Promise<EnvVariable[]> {
    return this.run("vars", "--project", project, "--profile", profile) as Promise<EnvVariable[]>;
  }

  createProject(name: string): Promise<EnvProject> {
    return this.run("project", "create", name) as Promise<EnvProject>;
  }

  async deleteProject(project: string): Promise<void> {
    await this.run("project", "delete", "--project", project);
  }

  createProfile(project: string, name: string, kind: string): Promise<EnvProfile> {
    return this.run("profile", "create", "--project", project, "--name", name, "--kind", kind) as Promise<EnvProfile>;
  }

  duplicateProfile(project: string, profile: string): Promise<EnvProfile> {
    return this.run("profile", "duplicate", "--project", project, "--profile", profile) as Promise<EnvProfile>;
  }

  async deleteProfile(project: string, profile: string): Promise<void> {
    await this.run("profile", "delete", "--project", project, "--profile", profile);
  }

  setVariable(
    project: string,
    profile: string,
    key: string,
    value: string,
    options: { secret?: boolean; enabled?: boolean; note?: string } = {},
  ): Promise<EnvVariable> {
    const args = ["var", "set", "--project", project, "--profile", profile];
    if (options.secret) args.push("--secret");
    if (options.enabled === false) args.push("--disabled");
    if (options.enabled === true) args.push("--enabled");
    if (options.note) args.push("--note", options.note);
    args.push(`${key}=${value}`);
    return this.run(...args) as Promise<EnvVariable>;
  }

  async toggleVariable(project: string, profile: string, key: string, enabled: boolean): Promise<void> {
    await this.run("var", enabled ? "enable" : "disable", "--project", project, "--profile", profile, key);
  }

  async deleteVariable(project: string, profile: string, key: string): Promise<void> {
    await this.run("var", "delete", "--project", project, "--profile", profile, key);
  }

  apply(project: string, profile: string): Promise<ApplyResult> {
    return this.run("apply", "--project", project, "--profile", profile) as Promise<ApplyResult>;
  }

  async unapply(): Promise<void> {
    await this.run("unapply");
  }

  async installHook(): Promise<void> {
    await this.run("hook", "install");
  }
}

/** The same rule as the app's EnvKey, so a bad name is caught before the round trip. */
export function isValidKey(key: string): boolean {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(key);
}
