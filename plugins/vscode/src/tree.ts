import * as vscode from "vscode";
import { Profile, Status, Variable, changedSinceApplied } from "./cli";

export interface Snapshot {
  status?: Status;
  profiles: Profile[];
  variables: Map<string, Variable[]>; // profile id -> variables
}

export type Node =
  | { kind: "profile"; profile: Profile }
  | { kind: "variable"; profile: Profile; variable: Variable };

export type IconName =
  | "add" | "apply" | "undo" | "copy" | "delete" | "export" | "import" | "profile" | "reveal"
  | "conceal" | "secret" | "drift" | "confirm" | "close" | "terminal";

/**
 * HyperEnv 2's own icons. Tree icons ignore `currentColor`, so each one ships
 * twice with the stroke baked in for light and dark themes.
 */
export function icon(extension: vscode.Uri, name: IconName): { light: vscode.Uri; dark: vscode.Uri } {
  return {
    light: vscode.Uri.joinPath(extension, "media", "icons", "light", `${name}.svg`),
    dark: vscode.Uri.joinPath(extension, "media", "icons", "dark", `${name}.svg`),
  };
}

const MASK = "••••••••";

/** True when the applied profile was edited after Apply (new terminals still get the old values). */
export function isChanged(snapshot: Snapshot, profile: Profile): boolean {
  const applied = snapshot.status?.applied;
  if (!applied || applied.profileId !== profile.id) return false;
  const vars = snapshot.variables.get(profile.id);
  return vars ? changedSinceApplied(vars, applied.exports) : false;
}

/** A flat list of profiles, each expanding to its variables. `contextValue` is what the menus key on. */
export class EnvTreeProvider implements vscode.TreeDataProvider<Node> {
  private readonly changed = new vscode.EventEmitter<Node | undefined>();
  readonly onDidChangeTreeData = this.changed.event;
  private snapshot: Snapshot = { profiles: [], variables: new Map() };
  /** Secrets shown in clear: "*" for all, or `profileId/KEY` one at a time. Session only. */
  readonly revealed = new Set<string>();

  constructor(private readonly extension: vscode.Uri) {}

  render(snapshot: Snapshot): void {
    this.snapshot = snapshot;
    this.changed.fire(undefined);
  }

  redraw(): void {
    this.changed.fire(undefined);
  }

  isRevealed(profile: Profile, variable: Variable): boolean {
    return this.revealed.has("*") || this.revealed.has(`${profile.id}/${variable.key}`);
  }

  getChildren(node?: Node): Node[] {
    if (!node) return this.snapshot.profiles.map((profile) => ({ kind: "profile", profile }));
    if (node.kind === "profile") {
      return (this.snapshot.variables.get(node.profile.id) ?? []).map((variable) => ({
        kind: "variable",
        profile: node.profile,
        variable,
      }));
    }
    return [];
  }

  getTreeItem(node: Node): vscode.TreeItem {
    if (node.kind === "profile") {
      const p = node.profile;
      const changed = isChanged(this.snapshot, p);
      const item = new vscode.TreeItem(p.name, vscode.TreeItemCollapsibleState.Collapsed);
      item.id = `p:${p.id}`;
      item.iconPath = icon(this.extension, p.isApplied ? (changed ? "drift" : "apply") : "profile");
      const count = p.enabledCount === p.variableCount ? `${p.variableCount}` : `${p.enabledCount}/${p.variableCount}`;
      item.description = `${count} var${p.variableCount === 1 ? "" : "s"}${p.isApplied ? (changed ? " · applied, changed since" : " · applied") : ""}`;
      item.tooltip = p.isApplied
        ? changed
          ? `${p.name} is applied, but its variables changed since. Apply it again so new terminals get the new values.`
          : `${p.name} is applied: new terminals start with it.`
        : `${p.name}: ${p.enabledCount} of ${p.variableCount} variables on.`;
      // The applied profile gets Undo instead of Delete.
      item.contextValue = p.isApplied ? "profile-applied" : "profile";
      return item;
    }

    const { profile, variable: v } = node;
    const secretShown = v.isSecret && this.isRevealed(profile, v);
    const item = new vscode.TreeItem(v.key, vscode.TreeItemCollapsibleState.None);
    item.id = `v:${profile.id}/${v.key}`;
    const shown = v.isSecret && !secretShown ? MASK : v.value.length > 80 ? `${v.value.slice(0, 80)}…` : v.value;
    item.description = v.isEnabled ? shown : `${shown}  (off)`;
    item.iconPath = icon(this.extension, !v.isEnabled ? "close" : v.isSecret ? "secret" : "terminal");
    item.tooltip = new vscode.MarkdownString(undefined);
    item.tooltip.appendMarkdown(`**${v.key}**${v.isEnabled ? "" : " — off, not exported"}${v.isSecret ? " — secret" : ""}\n\n`);
    if (!v.isSecret || secretShown) item.tooltip.appendCodeblock(v.value, "text");
    // Menus match on these words: secret/plain, on/off, shown/hidden.
    item.contextValue = [
      "variable",
      v.isSecret ? "secret" : "plain",
      v.isEnabled ? "on" : "off",
      v.isSecret ? (secretShown ? "shown" : "hidden") : "",
    ].filter(Boolean).join("-");
    item.command = { command: "hyperenv.editVariable", title: "Edit Value", arguments: [node] };
    return item;
  }
}
