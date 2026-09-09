import * as vscode from "vscode";
import { EnvProfile, EnvProject, EnvVariable, Status } from "./cli";

export interface Snapshot {
  status?: Status;
  projects: EnvProject[];
  variables: Map<string, EnvVariable[]>; // profile id -> variables
  error?: string;
}

export type Node =
  | { kind: "project"; project: EnvProject }
  | { kind: "profile"; project: EnvProject; profile: EnvProfile }
  | { kind: "variable"; project: EnvProject; profile: EnvProfile; variable: EnvVariable };

export function displayPath(node: Node & { kind: "profile" | "variable" }): string {
  return `${node.project.name}/${node.profile.name}`;
}

/** Projects → profiles → variables. `contextValue` is what the menus key on. */
export class EnvTreeProvider implements vscode.TreeDataProvider<Node> {
  private readonly changed = new vscode.EventEmitter<Node | undefined>();
  readonly onDidChangeTreeData = this.changed.event;
  private snapshot: Snapshot = { projects: [], variables: new Map() };

  render(snapshot: Snapshot): void {
    this.snapshot = snapshot;
    this.changed.fire(undefined);
  }

  getChildren(node?: Node): Node[] {
    if (!node) return this.snapshot.projects.map((project) => ({ kind: "project", project }));
    if (node.kind === "project") {
      return node.project.profiles.map((profile) => ({ kind: "profile", project: node.project, profile }));
    }
    if (node.kind === "profile") {
      return (this.snapshot.variables.get(node.profile.id) ?? []).map((variable) => ({
        kind: "variable",
        project: node.project,
        profile: node.profile,
        variable,
      }));
    }
    return [];
  }

  getTreeItem(node: Node): vscode.TreeItem {
    switch (node.kind) {
      case "project": {
        const item = new vscode.TreeItem(node.project.name, vscode.TreeItemCollapsibleState.Expanded);
        item.iconPath = new vscode.ThemeIcon("package");
        item.contextValue = node.project.isDefault ? "project-default" : "project";
        if (node.project.isDefault) item.description = "snapshot of this machine";
        item.id = `p:${node.project.id}`;
        return item;
      }
      case "profile": {
        const p = node.profile;
        const item = new vscode.TreeItem(p.name, vscode.TreeItemCollapsibleState.Collapsed);
        item.iconPath = new vscode.ThemeIcon(p.isApplied ? "play-circle" : "folder");
        item.description = `${p.kind} · ${p.enabledCount}/${p.variableCount}${p.isApplied ? " · applied" : ""}`;
        // "profile" gets Apply and Delete; the Default snapshot and the applied one do not.
        item.contextValue = p.isDefault ? "profile-default" : p.isApplied ? "profile-applied" : "profile";
        item.tooltip = p.isDefault
          ? "The machine's own environment. Duplicate it to make an appliable profile."
          : `${displayPath(node)} — ${p.enabledCount} of ${p.variableCount} switched on`;
        item.id = `f:${p.id}`;
        return item;
      }
      case "variable": {
        const v = node.variable;
        const item = new vscode.TreeItem(v.key, vscode.TreeItemCollapsibleState.None);
        item.description = (v.isSecret ? "••••••" : v.value.slice(0, 80)) + (v.isEnabled ? "" : "  (off)");
        item.iconPath = new vscode.ThemeIcon(v.isSecret ? "lock" : "symbol-variable");
        item.contextValue = v.isEnabled ? "variable" : "variable-off";
        if (!v.isValid) item.iconPath = new vscode.ThemeIcon("error");
        item.tooltip = v.note ?? (v.isSecret ? "Hidden in the list; exported in plain text." : v.value);
        item.command = { command: "hyperenv.editVariable", title: "Edit", arguments: [node] };
        item.id = `v:${v.id}`;
        return item;
      }
    }
  }
}
