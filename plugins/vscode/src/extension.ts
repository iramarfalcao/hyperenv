import * as vscode from "vscode";
import { homedir } from "node:os";
import { CliError, HyperEnvCli, bundledCandidates, isValidKey, locate } from "./cli";
import { EnvTreeProvider, Node, Snapshot, displayPath } from "./tree";

const CLI_MISSING =
  "The hyperenv command was not found. Install the HyperEnv app, or set hyperenv.cliPath.";

export function activate(context: vscode.ExtensionContext): void {
  const tree = new EnvTreeProvider();
  const view = vscode.window.createTreeView("hyperenv.tree", { treeDataProvider: tree, showCollapseAll: true });
  const status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 50);
  status.command = "hyperenv.copyReload";
  context.subscriptions.push(view, status);

  let snapshot: Snapshot = { projects: [], variables: new Map() };

  function cli(): HyperEnvCli {
    const found = locate(
      vscode.workspace.getConfiguration("hyperenv").get<string>("cliPath"),
      process.env.PATH,
      bundledCandidates(homedir()),
    );
    if (!found) throw new CliError(CLI_MISSING);
    return new HyperEnvCli(found);
  }

  /** Re-reads everything: the command is the source of truth. */
  async function read(client: HyperEnvCli): Promise<Snapshot> {
    const [st, projects] = await Promise.all([client.status(), client.projects()]);
    const variables = new Map<string, Awaited<ReturnType<HyperEnvCli["variables"]>>>();
    await Promise.all(
      projects.flatMap((p) => p.profiles.map(async (f) => variables.set(f.id, await client.variables(p.id, f.id)))),
    );
    return { status: st, projects, variables };
  }

  function show(next: Snapshot): void {
    snapshot = next;
    tree.render(next);
    const applied = next.status?.applied;
    vscode.commands.executeCommand("setContext", "hyperenv.hasProjects", next.projects.length > 0);
    vscode.commands.executeCommand("setContext", "hyperenv.applied", !!applied);
    vscode.commands.executeCommand("setContext", "hyperenv.hookInstalled", next.status?.hook === "installed");
    if (applied) {
      status.text = `$(play-circle) ${applied.projectName}/${applied.profileName}`;
      status.tooltip = "HyperEnv: applied. Click to copy the reload command for an open terminal.";
      status.show();
    } else {
      status.hide();
    }
  }

  /** Runs one operation, then re-reads. Errors become messages, never crashes. */
  async function mutate(title: string, work: (client: HyperEnvCli) => Promise<string | void>): Promise<void> {
    try {
      await vscode.window.withProgress({ location: { viewId: "hyperenv.tree" }, title }, async () => {
        const client = cli();
        const message = await work(client);
        show(await read(client));
        if (message) vscode.window.showInformationMessage(message);
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      snapshot = { ...snapshot, error: message };
      vscode.window.showErrorMessage(`HyperEnv: ${message}`);
    }
  }

  const refresh = () => mutate("Reading…", async () => undefined);

  function profileOf(node?: Node): (Node & { kind: "profile" | "variable" }) | undefined {
    return node && node.kind !== "project" ? node : undefined;
  }

  context.subscriptions.push(
    vscode.commands.registerCommand("hyperenv.refresh", refresh),

    vscode.commands.registerCommand("hyperenv.newProject", async () => {
      const name = await vscode.window.showInputBox({ prompt: "Project name", placeHolder: "payments" });
      if (name?.trim()) await mutate("Creating project…", (c) => c.createProject(name.trim()).then(() => undefined));
    }),

    vscode.commands.registerCommand("hyperenv.newProfile", async (node?: Node) => {
      const project = node?.project ?? (await pickProject());
      if (!project) return;
      const name = await vscode.window.showInputBox({ prompt: "Profile name", value: "dev" });
      if (!name?.trim()) return;
      const kind = await vscode.window.showQuickPick(["dev", "hml", "prd", "custom"], { placeHolder: "Kind" });
      if (!kind) return;
      await mutate("Creating profile…", (c) => c.createProfile(project.id, name.trim(), kind).then(() => undefined));
    }),

    vscode.commands.registerCommand("hyperenv.newVariable", async (node?: Node) => {
      const target = profileOf(node);
      if (!target) return;
      const key = await vscode.window.showInputBox({
        prompt: "Variable name",
        placeHolder: "API_URL",
        validateInput: (v) => (isValidKey(v.trim()) ? undefined : "Letters, digits and underscores; cannot start with a digit."),
      });
      if (!key) return;
      const value = await vscode.window.showInputBox({ prompt: `Value of ${key.trim()}` });
      if (value === undefined) return;
      const secret = await vscode.window.showQuickPick(["Show the value in the list", "Hide it (secret)"], { placeHolder: "Visibility" });
      if (!secret) return;
      await mutate("Saving…", (c) =>
        c.setVariable(target.project.id, target.profile.id, key.trim(), value, { secret: secret.startsWith("Hide"), enabled: true }).then(() => undefined),
      );
    }),

    vscode.commands.registerCommand("hyperenv.editVariable", async (node?: Node) => {
      if (node?.kind !== "variable") return;
      const value = await vscode.window.showInputBox({ prompt: `Value of ${node.variable.key}`, value: node.variable.value });
      if (value === undefined) return;
      await mutate("Saving…", (c) =>
        c
          .setVariable(node.project.id, node.profile.id, node.variable.key, value, {
            secret: node.variable.isSecret,
            enabled: node.variable.isEnabled,
            note: node.variable.note,
          })
          .then(() => undefined),
      );
    }),

    vscode.commands.registerCommand("hyperenv.toggleVariable", async (node?: Node) => {
      if (node?.kind !== "variable") return;
      await mutate("Saving…", (c) => c.toggleVariable(node.project.id, node.profile.id, node.variable.key, !node.variable.isEnabled));
    }),

    vscode.commands.registerCommand("hyperenv.duplicateProfile", async (node?: Node) => {
      const target = profileOf(node);
      if (!target) return;
      await mutate("Duplicating…", (c) => c.duplicateProfile(target.project.id, target.profile.id).then(() => undefined));
    }),

    vscode.commands.registerCommand("hyperenv.delete", async (node?: Node) => {
      if (!node) return;
      const what =
        node.kind === "project" ? `project ${node.project.name}` : node.kind === "profile" ? `profile ${displayPath(node)}` : node.variable.key;
      const ok = await vscode.window.showWarningMessage(`Delete ${what}? This cannot be undone.`, { modal: true }, "Delete");
      if (ok !== "Delete") return;
      await mutate("Deleting…", async (c) => {
        if (node.kind === "project") await c.deleteProject(node.project.id);
        else if (node.kind === "profile") await c.deleteProfile(node.project.id, node.profile.id);
        else await c.deleteVariable(node.project.id, node.profile.id, node.variable.key);
      });
    }),

    vscode.commands.registerCommand("hyperenv.apply", async (node?: Node) => {
      const target = profileOf(node) ?? (await pickProfile());
      if (!target) return;
      await mutate(`Applying ${displayPath(target)}…`, async (c) => {
        const result = await c.apply(target.project.id, target.profile.id);
        return `Applied ${displayPath(target)}: ${result.exported} variables. New terminals inherit it; for one already open, use "Copy Reload Command".`;
      });
    }),

    vscode.commands.registerCommand("hyperenv.unapply", () =>
      mutate("Reverting…", async (c) => {
        await c.unapply();
        return "Reverted. New terminals are back to your own environment.";
      }),
    ),

    vscode.commands.registerCommand("hyperenv.copyReload", async () => {
      const command = snapshot.status?.reloadCommand;
      if (!command) return;
      await vscode.env.clipboard.writeText(command);
      vscode.window.showInformationMessage("Reload command copied.");
    }),

    vscode.commands.registerCommand("hyperenv.installHook", () =>
      mutate("Installing the shell hook…", async (c) => {
        await c.installHook();
        return `Shell hook installed in ${(await c.status()).dotfile}.`;
      }),
    ),

    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("hyperenv")) refresh();
    }),
  );

  async function pickProject() {
    const projects = snapshot.projects.filter((p) => !p.isDefault);
    if (projects.length === 0) return undefined;
    const pick = await vscode.window.showQuickPick(
      projects.map((p) => ({ label: p.name, project: p })),
      { placeHolder: "Project" },
    );
    return pick?.project;
  }

  async function pickProfile() {
    const items = snapshot.projects.flatMap((project) =>
      project.profiles.filter((f) => f.canBeApplied).map((profile) => ({
        label: `${project.name}/${profile.name}`,
        description: profile.kind,
        node: { kind: "profile" as const, project, profile },
      })),
    );
    const pick = await vscode.window.showQuickPick(items, { placeHolder: "Profile to apply" });
    return pick?.node;
  }

  refresh();
}

export function deactivate(): void {}
