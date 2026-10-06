import * as vscode from "vscode";
import { homedir } from "node:os";
import {
  CliError,
  HyperEnvCli,
  INSTALL_UNIX,
  INSTALL_WINDOWS,
  MIN_MAJOR,
  Profile,
  Variable,
  isSupportedVersion,
  isValidKey,
  bundledCandidates,
  ensureExecutable,
  locate,
  parseAssignment,
} from "./cli";
import { EnvTreeProvider, Node, Snapshot, isChanged } from "./tree";

const VIEW = "hyperenv.tree";

/** Raised when there is no usable command; the message already told the user what to do. */
class Unavailable extends Error {}

export function activate(context: vscode.ExtensionContext): void {
  const tree = new EnvTreeProvider(context.extensionUri);
  const view = vscode.window.createTreeView(VIEW, { treeDataProvider: tree, showCollapseAll: true });
  const statusItem = vscode.window.createStatusBarItem("hyperenv.status", vscode.StatusBarAlignment.Left, 50);
  statusItem.name = "HyperEnv";
  statusItem.command = "hyperenv.focus";
  context.subscriptions.push(view, statusItem);

  let snapshot: Snapshot = { profiles: [], variables: new Map() };

  // ---------------------------------------------------------- the command

  // Resolved once per setting value: `version` is cheap, but asking it on
  // every click would still be a process per click.
  let resolved: { key: string; cli: Promise<HyperEnvCli> } | undefined;
  let warnedMissing = false;

  function cli(): Promise<HyperEnvCli> {
    const setting = vscode.workspace.getConfiguration("hyperenv").get<string>("cliPath") ?? "";
    if (resolved?.key !== setting) resolved = { key: setting, cli: resolve(setting) };
    const pending = resolved.cli;
    // A failed lookup is retried next time (the user may install it meanwhile).
    pending.catch(() => {
      if (resolved?.cli === pending) resolved = undefined;
    });
    return pending;
  }

  async function resolve(setting: string): Promise<HyperEnvCli> {
    const env = {
      platform: process.platform,
      home: homedir(),
      path: process.env.PATH ?? process.env.Path,
      localAppData: process.env.LOCALAPPDATA,
      extensionPath: context.extensionPath,
    };
    for (const bundled of bundledCandidates(env)) ensureExecutable(bundled);
    const found = locate(setting, env);
    if (!found) {
      setContext("hyperenv.missing", true);
      if (!warnedMissing) {
        warnedMissing = true;
        void showMissing();
      }
      throw new Unavailable("The hyperenv command was not found.");
    }
    const client = new HyperEnvCli(found);
    let version: string;
    try {
      version = await client.version();
    } catch (error) {
      // A 1.x command has no `version` in this shape, or no --json envelope at all.
      version = "";
      if (!(error instanceof CliError)) throw error;
    }
    if (!isSupportedVersion(version)) {
      setContext("hyperenv.missing", true);
      void vscode.window
        .showErrorMessage(
          `HyperEnv: ${found} is version ${version || "1.x or unknown"}; this extension needs HyperEnv ${MIN_MAJOR}.0 or later. Update the HyperEnv app or the command.`,
          "Copy Install Command",
          "Open Settings",
        )
        .then(installAction);
      throw new Unavailable(`HyperEnv ${MIN_MAJOR}.0 or later is required.`);
    }
    setContext("hyperenv.missing", false);
    return client;
  }

  function installCommand(): string {
    return process.platform === "win32" ? INSTALL_WINDOWS : INSTALL_UNIX;
  }

  async function showMissing(): Promise<void> {
    const pick = await vscode.window.showErrorMessage(
      "HyperEnv: the hyperenv command was not found. Install HyperEnv, or point hyperenv.cliPath at it.",
      {
        modal: false,
        detail: `macOS / Linux: ${INSTALL_UNIX}\nWindows (PowerShell): ${INSTALL_WINDOWS}`,
      },
      "Copy Install Command",
      "Open Settings",
    );
    await installAction(pick);
  }

  async function installAction(pick: string | undefined): Promise<void> {
    if (pick === "Copy Install Command") {
      await vscode.env.clipboard.writeText(installCommand());
      vscode.window.showInformationMessage(`Copied: ${installCommand()}`);
    } else if (pick === "Open Settings") {
      await vscode.commands.executeCommand("workbench.action.openSettings", "hyperenv.cliPath");
    }
  }

  // ---------------------------------------------------------------- state

  function setContext(key: string, value: unknown): void {
    void vscode.commands.executeCommand("setContext", key, value);
  }

  /** Re-reads everything: the command is the source of truth, shared with the desktop apps. */
  async function read(client: HyperEnvCli): Promise<Snapshot> {
    const [status, profiles] = await Promise.all([client.status(), client.profiles()]);
    const variables = new Map<string, Variable[]>();
    await Promise.all(profiles.map(async (p) => variables.set(p.id, await client.variables(p.name))));
    return { status, profiles, variables };
  }

  function show(next: Snapshot): void {
    snapshot = next;
    tree.render(next);
    const applied = next.status?.applied;
    setContext("hyperenv.ready", true);
    setContext("hyperenv.hasProfiles", next.profiles.length > 0);
    setContext("hyperenv.applied", !!applied);

    const drift = next.status?.drift.length ?? 0;
    const appliedProfile = next.profiles.find((p) => p.id === applied?.profileId);
    const changed = appliedProfile ? isChanged(next, appliedProfile) : false;
    // Status bar items only take codicons; plain text keeps it free of non-HyperEnv icons.
    statusItem.text = applied
      ? `HyperEnv: ${applied.profileName}${changed ? " (changed)" : ""}${drift ? ` · ${drift} drift` : ""}`
      : `HyperEnv: nothing applied${drift ? ` · ${drift} drift` : ""}`;
    const tip = new vscode.MarkdownString(undefined);
    tip.appendMarkdown(
      applied
        ? `**${applied.profileName}** is applied — ${applied.exportedKeys.length} variable(s) for new terminals.\n\n`
        : "Nothing is applied: new terminals get your own environment.\n\n",
    );
    if (changed) tip.appendMarkdown("Its variables changed since it was applied; apply it again to update new terminals.\n\n");
    if (drift) {
      tip.appendMarkdown(`${drift} drift item(s):\n\n`);
      for (const d of next.status!.drift) {
        tip.appendMarkdown(`- ${d.kind}${d.key ? ` \`${d.key}\`` : ""}\n`);
      }
    }
    statusItem.tooltip = tip;
    statusItem.backgroundColor = drift ? new vscode.ThemeColor("statusBarItem.warningBackground") : undefined;
    statusItem.show();
  }

  function report(error: unknown): void {
    if (error instanceof Unavailable) return; // already explained
    const message = error instanceof Error ? error.message : String(error);
    vscode.window.showErrorMessage(`HyperEnv: ${message}`);
  }

  // Refreshes never overlap: a request while one runs is folded into one more run.
  let refreshing: Promise<void> | undefined;
  let again = false;
  function refresh(): Promise<void> {
    if (refreshing) {
      again = true;
      return refreshing;
    }
    refreshing = (async () => {
      try {
        do {
          again = false;
          await vscode.window.withProgress({ location: { viewId: VIEW } }, async () => show(await read(await cli())));
        } while (again);
      } catch (error) {
        report(error);
      } finally {
        refreshing = undefined;
      }
    })();
    return refreshing;
  }

  /**
   * Runs one change with progress (never blocking the editor), then re-reads.
   * Long ones (apply/undo start the user's shell) also get a notification.
   */
  async function mutate<T>(title: string, work: (client: HyperEnvCli) => Promise<T>, notify = false): Promise<T | undefined> {
    try {
      const result = await vscode.window.withProgress(
        { location: notify ? vscode.ProgressLocation.Notification : { viewId: VIEW }, title },
        async () => work(await cli()),
      );
      await refresh();
      return result;
    } catch (error) {
      report(error);
      void refresh();
      return undefined;
    }
  }

  // --------------------------------------------------------------- pickers

  async function pickProfile(placeHolder: string, filter: (p: Profile) => boolean = () => true): Promise<Profile | undefined> {
    const items = snapshot.profiles.filter(filter).map((profile) => ({
      label: profile.name,
      description: `${profile.variableCount} vars${profile.isApplied ? " · applied" : ""}`,
      profile,
    }));
    if (items.length === 0) {
      vscode.window.showInformationMessage("HyperEnv: no profile to choose from.");
      return undefined;
    }
    return (await vscode.window.showQuickPick(items, { placeHolder }))?.profile;
  }

  async function profileFrom(node: Node | undefined, placeHolder: string, filter?: (p: Profile) => boolean) {
    return node ? node.profile : pickProfile(placeHolder, filter);
  }

  function validateName(exclude?: string) {
    return (value: string): string | undefined => {
      const name = value.trim();
      if (!name) return "A name is required.";
      if (name !== exclude && snapshot.profiles.some((p) => p.name === name)) return `There is already a profile named "${name}".`;
      return undefined;
    };
  }

  /** After apply/undo: HyperEnv only changes NEW terminals; an open one needs the reload command. */
  async function offerReload(message: string, command: string): Promise<void> {
    const terminal = vscode.window.activeTerminal;
    const actions = terminal ? ["Run in Terminal", "Copy Command"] : ["Copy Command"];
    const pick = await vscode.window.showInformationMessage(
      `${message} New terminals pick it up; for a terminal that is already open, run: ${command}`,
      ...actions,
    );
    if (pick === "Run in Terminal" && terminal) {
      terminal.show();
      terminal.sendText(command);
    } else if (pick === "Copy Command") {
      await vscode.env.clipboard.writeText(command);
    }
  }

  // -------------------------------------------------------------- commands

  const register = (id: string, fn: (...args: any[]) => unknown) =>
    context.subscriptions.push(vscode.commands.registerCommand(id, fn));

  register("hyperenv.refresh", () => refresh());
  register("hyperenv.focus", () => vscode.commands.executeCommand(`${VIEW}.focus`));

  register("hyperenv.newProfile", async () => {
    const name = await vscode.window.showInputBox({ prompt: "New profile name", placeHolder: "staging", validateInput: validateName() });
    if (name === undefined) return;
    await mutate("Creating profile…", (c) => c.createProfile(name.trim()));
  });

  register("hyperenv.renameProfile", async (node?: Node) => {
    const profile = await profileFrom(node, "Profile to rename");
    if (!profile) return;
    const name = await vscode.window.showInputBox({
      prompt: `Rename "${profile.name}"`,
      value: profile.name,
      validateInput: validateName(profile.name),
    });
    if (name === undefined || name.trim() === profile.name) return;
    await mutate("Renaming…", (c) => c.renameProfile(profile.name, name.trim()));
  });

  register("hyperenv.duplicateProfile", async (node?: Node) => {
    const profile = await profileFrom(node, "Profile to duplicate");
    if (!profile) return;
    let suggestion = `${profile.name} copy`;
    for (let i = 2; snapshot.profiles.some((p) => p.name === suggestion); i++) suggestion = `${profile.name} copy ${i}`;
    const name = await vscode.window.showInputBox({ prompt: `Duplicate "${profile.name}" as`, value: suggestion, validateInput: validateName() });
    if (name === undefined) return;
    await mutate("Duplicating…", (c) => c.duplicateProfile(profile.name, name.trim()));
  });

  register("hyperenv.deleteProfile", async (node?: Node) => {
    const profile = await profileFrom(node, "Profile to delete", (p) => !p.isApplied);
    if (!profile) return;
    if (profile.isApplied) {
      vscode.window.showWarningMessage(`HyperEnv: "${profile.name}" is applied. Undo it before deleting.`);
      return;
    }
    const ok = await vscode.window.showWarningMessage(
      `Delete the profile "${profile.name}"?`,
      { modal: true, detail: `Its ${profile.variableCount} variable(s) go with it. This cannot be undone.` },
      "Delete",
    );
    if (ok !== "Delete") return;
    await mutate("Deleting…", (c) => c.deleteProfile(profile.name));
  });

  register("hyperenv.addVariable", async (node?: Node) => {
    const profile = await profileFrom(node, "Add a variable to");
    if (!profile) return;
    const existing = new Set((snapshot.variables.get(profile.id) ?? []).map((v) => v.key));
    const text = await vscode.window.showInputBox({
      prompt: `Add a variable to "${profile.name}" as NAME=value`,
      placeHolder: "API_URL=https://api.example.com",
      validateInput: (value) => {
        const at = value.indexOf("=");
        const key = (at < 0 ? value : value.slice(0, at)).trim();
        if (!isValidKey(key)) return "The name takes letters, digits and underscores, and cannot start with a digit.";
        if (at < 0) return "Write NAME=value (the value may be empty).";
        if (existing.has(key)) return `${key} already exists here; this will replace its value.`;
        return undefined;
      },
    });
    if (text === undefined) return;
    const assignment = parseAssignment(text);
    if (!assignment) return;
    if (existing.has(assignment.key)) {
      const ok = await vscode.window.showWarningMessage(`Replace the value of ${assignment.key}?`, { modal: true }, "Replace");
      if (ok !== "Replace") return;
    }
    await mutate("Saving…", (c) => c.setVariable(profile.name, assignment.key, assignment.value));
  });

  function variableOf(node?: Node): (Node & { kind: "variable" }) | undefined {
    return node?.kind === "variable" ? node : undefined;
  }

  register("hyperenv.editVariable", async (node?: Node) => {
    const target = variableOf(node);
    if (!target) return;
    const { profile, variable } = target;
    const value = await vscode.window.showInputBox({
      prompt: `Value of ${variable.key} in "${profile.name}"`,
      value: variable.value,
      password: variable.isSecret && !tree.isRevealed(profile, variable),
    });
    if (value === undefined || value === variable.value) return;
    await mutate("Saving…", (c) => c.setVariable(profile.name, variable.key, value));
  });

  register("hyperenv.deleteVariable", async (node?: Node) => {
    const target = variableOf(node);
    if (!target) return;
    const ok = await vscode.window.showWarningMessage(
      `Delete ${target.variable.key} from "${target.profile.name}"?`,
      { modal: true },
      "Delete",
    );
    if (ok !== "Delete") return;
    await mutate("Deleting…", (c) => c.deleteVariable(target.profile.name, target.variable.key));
  });

  for (const [id, enabled] of [["hyperenv.enableVariable", true], ["hyperenv.disableVariable", false]] as const) {
    register(id, async (node?: Node) => {
      const target = variableOf(node);
      if (target) await mutate("Saving…", (c) => c.setEnabled(target.profile.name, target.variable.key, enabled));
    });
  }

  for (const [id, secret] of [["hyperenv.markSecret", true], ["hyperenv.unmarkSecret", false]] as const) {
    register(id, async (node?: Node) => {
      const target = variableOf(node);
      if (!target) return;
      // Same value, new flag: `var set` is the only way to change the flag.
      await mutate("Saving…", (c) => c.setVariable(target.profile.name, target.variable.key, target.variable.value, secret));
    });
  }

  register("hyperenv.copyValue", async (node?: Node) => {
    const target = variableOf(node);
    if (!target) return;
    await vscode.env.clipboard.writeText(target.variable.value);
    vscode.window.setStatusBarMessage(`HyperEnv: ${target.variable.key} copied`, 2500);
  });

  register("hyperenv.revealVariable", (node?: Node) => {
    const target = variableOf(node);
    if (!target) return;
    tree.revealed.add(`${target.profile.id}/${target.variable.key}`);
    tree.redraw();
  });

  register("hyperenv.concealVariable", (node?: Node) => {
    const target = variableOf(node);
    if (!target) return;
    tree.revealed.delete("*");
    tree.revealed.delete(`${target.profile.id}/${target.variable.key}`);
    tree.redraw();
  });

  register("hyperenv.revealSecrets", () => {
    tree.revealed.add("*");
    setContext("hyperenv.secretsShown", true);
    tree.redraw();
  });

  register("hyperenv.concealSecrets", () => {
    tree.revealed.clear();
    setContext("hyperenv.secretsShown", false);
    tree.redraw();
  });

  register("hyperenv.apply", async (node?: Node) => {
    const profile = await profileFrom(node, "Profile to apply");
    if (!profile) return;
    const result = await mutate(`Applying ${profile.name}…`, (c) => c.apply(profile.name), true);
    if (result) {
      await offerReload(`Applied ${result.applied}: ${result.exported.length} variable(s).`, result.reloadCommand);
    }
  });

  register("hyperenv.unapply", async () => {
    const name = snapshot.status?.applied?.profileName;
    const result = await mutate("Undoing…", (c) => c.unapply(), true);
    if (result) {
      await offerReload(
        `Undid ${name ?? "the applied profile"}: ${result.restored.length} variable(s) back to their previous values.`,
        result.undoCommand,
      );
    }
  });

  register("hyperenv.copyReload", async () => {
    const command = snapshot.status?.reloadCommand;
    if (!command) return;
    await vscode.env.clipboard.writeText(command);
    vscode.window.showInformationMessage(`Copied: ${command}`);
  });

  register("hyperenv.import", async (node?: Node) => {
    const profile = await profileFrom(node, "Import a .env into");
    if (!profile) return;
    const files = await vscode.window.showOpenDialog({
      title: `Import into "${profile.name}"`,
      canSelectMany: false,
      openLabel: "Import",
      defaultUri: vscode.workspace.workspaceFolders?.[0]?.uri,
      filters: { "Env files": ["env", "*"] },
    });
    const file = files?.[0];
    if (!file) return;
    const result = await mutate("Importing…", (c) => c.importFile(profile.name, file.fsPath));
    if (!result) return;
    const skipped = result.diagnostics.filter((d) => d.severity === "error").length;
    const summary = `Imported ${result.imported} variable(s) into "${profile.name}".`;
    if (result.diagnostics.length === 0) {
      vscode.window.showInformationMessage(summary);
    } else {
      vscode.window.showWarningMessage(`${summary} ${skipped} line(s) skipped.`, {
        modal: false,
        detail: result.diagnostics.map((d) => `line ${d.line}: ${d.message}`).join("\n"),
      });
    }
  });

  register("hyperenv.export", async (node?: Node) => {
    const profile = await profileFrom(node, "Profile to export");
    if (!profile) return;
    const folder = vscode.workspace.workspaceFolders?.[0]?.uri;
    const target = await vscode.window.showSaveDialog({
      title: `Export "${profile.name}" as .env`,
      saveLabel: "Export",
      defaultUri: folder ? vscode.Uri.joinPath(folder, `${profile.name}.env`) : undefined,
      filters: { "Env files": ["env"] },
    });
    if (!target) return;
    try {
      const text = await vscode.window.withProgress({ location: { viewId: VIEW }, title: "Exporting…" }, async () =>
        (await cli()).exportDotenv(profile.name),
      );
      await vscode.workspace.fs.writeFile(target, new TextEncoder().encode(text));
      vscode.window.showInformationMessage(`Exported "${profile.name}" to ${target.fsPath}. It contains secrets in plain text.`);
    } catch (error) {
      report(error);
    }
  });

  // --------------------------------------------------------------- events

  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("hyperenv")) {
        resolved = undefined;
        warnedMissing = false;
        void refresh();
      }
    }),
    // The desktop app or a terminal may have changed things while VS Code was in the background.
    vscode.window.onDidChangeWindowState((state) => {
      if (state.focused) void refresh();
    }),
  );

  setContext("hyperenv.secretsShown", false);
  void refresh();
}

export function deactivate(): void {}
