package com.falcaosl.hyperenv.toolWindow

import com.falcaosl.hyperenv.HyperEnvBundle
import com.falcaosl.hyperenv.cli.EnvProfile
import com.falcaosl.hyperenv.cli.EnvProject
import com.falcaosl.hyperenv.cli.EnvVariable
import com.falcaosl.hyperenv.service.HyperEnvService
import com.intellij.icons.AllIcons
import com.intellij.ui.ColoredTreeCellRenderer
import com.intellij.ui.SimpleTextAttributes
import com.intellij.ui.treeStructure.Tree
import javax.swing.JTree
import javax.swing.tree.DefaultMutableTreeNode
import javax.swing.tree.DefaultTreeModel
import javax.swing.tree.TreePath

/** What a row is. The tree holds these; the actions switch on them. */
sealed class Node {
    data class ProjectNode(val project: EnvProject) : Node()
    data class ProfileNode(val project: EnvProject, val profile: EnvProfile) : Node() {
        val displayPath get() = "${project.name}/${profile.name}"
    }
    data class VariableNode(val project: EnvProject, val profile: EnvProfile, val variable: EnvVariable) : Node()
    data class Message(val text: String) : Node()
}

class EnvTree : Tree(DefaultTreeModel(DefaultMutableTreeNode("root"))) {

    init {
        isRootVisible = false
        showsRootHandles = true
        cellRenderer = Renderer()
    }

    val selectedNode: Node?
        get() = (lastSelectedPathComponent as? DefaultMutableTreeNode)?.userObject as? Node

    /** Rebuilds from a snapshot, keeping what was expanded and selected. */
    fun render(snapshot: HyperEnvService.Snapshot) {
        val expandedIds = expandedIds()
        val selectedId = selectedNode?.let(::id)

        val root = DefaultMutableTreeNode("root")
        if (snapshot.projects.isEmpty()) {
            root.add(DefaultMutableTreeNode(Node.Message(snapshot.error ?: HyperEnvBundle.message("tree.noProjects"))))
        }
        for (project in snapshot.projects) {
            val projectNode = DefaultMutableTreeNode(Node.ProjectNode(project))
            for (profile in project.profiles) {
                val profileNode = DefaultMutableTreeNode(Node.ProfileNode(project, profile))
                for (variable in snapshot.variables[profile.id] ?: emptyList()) {
                    profileNode.add(DefaultMutableTreeNode(Node.VariableNode(project, profile, variable)))
                }
                projectNode.add(profileNode)
            }
            root.add(projectNode)
        }
        model = DefaultTreeModel(root)

        // Re-expand what was open; a first render opens every project.
        val paths = ArrayList<TreePath>()
        var toSelect: TreePath? = null
        root.depthFirstEnumeration().asSequence().filterIsInstance<DefaultMutableTreeNode>().forEach { node ->
            val obj = node.userObject as? Node ?: return@forEach
            val nodeId = id(obj)
            if (nodeId in expandedIds || (expandedIds.isEmpty() && obj is Node.ProjectNode)) paths += TreePath(node.path)
            if (nodeId == selectedId) toSelect = TreePath(node.path)
        }
        paths.forEach(::expandPath)
        toSelect?.let { selectionPath = it }
    }

    private fun expandedIds(): Set<String> {
        val root = model.root as? DefaultMutableTreeNode ?: return emptySet()
        return root.depthFirstEnumeration().asSequence()
            .filterIsInstance<DefaultMutableTreeNode>()
            .filter { isExpanded(TreePath(it.path)) }
            .mapNotNull { (it.userObject as? Node)?.let(::id) }
            .toSet()
    }

    private fun id(node: Node): String = when (node) {
        is Node.ProjectNode -> "p:${node.project.id}"
        is Node.ProfileNode -> "f:${node.profile.id}"
        is Node.VariableNode -> "v:${node.variable.id}"
        is Node.Message -> "m"
    }

    private class Renderer : ColoredTreeCellRenderer() {
        override fun customizeCellRenderer(
            tree: JTree, value: Any?, selected: Boolean, expanded: Boolean, leaf: Boolean, row: Int, hasFocus: Boolean,
        ) {
            val node = (value as? DefaultMutableTreeNode)?.userObject as? Node ?: return
            when (node) {
                is Node.ProjectNode -> {
                    icon = AllIcons.Nodes.Module
                    append(node.project.name, SimpleTextAttributes.REGULAR_BOLD_ATTRIBUTES)
                    if (node.project.isDefault) append("  " + HyperEnvBundle.message("tree.default"), SimpleTextAttributes.GRAYED_ATTRIBUTES)
                }
                is Node.ProfileNode -> {
                    val p = node.profile
                    icon = if (p.isApplied) AllIcons.Actions.Execute else AllIcons.Nodes.Folder
                    append(p.name, if (p.isApplied) SimpleTextAttributes.REGULAR_BOLD_ATTRIBUTES else SimpleTextAttributes.REGULAR_ATTRIBUTES)
                    append("  ${p.kind}", SimpleTextAttributes.GRAYED_ATTRIBUTES)
                    append("  ${p.enabledCount}/${p.variableCount}", SimpleTextAttributes.GRAYED_SMALL_ATTRIBUTES)
                    if (p.isApplied) append("  ● " + HyperEnvBundle.message("tree.applied"), SimpleTextAttributes.GRAYED_BOLD_ATTRIBUTES)
                }
                is Node.VariableNode -> {
                    val v = node.variable
                    icon = if (v.isSecret) AllIcons.Nodes.Padlock else AllIcons.Nodes.Variable
                    val attrs = when {
                        !v.isValid -> SimpleTextAttributes.ERROR_ATTRIBUTES
                        !v.isEnabled -> SimpleTextAttributes.GRAYED_ATTRIBUTES
                        else -> SimpleTextAttributes.REGULAR_ATTRIBUTES
                    }
                    append(v.key, attrs)
                    append(" = ", SimpleTextAttributes.GRAYED_ATTRIBUTES)
                    append(if (v.isSecret) "••••••" else v.value.take(80), if (v.isEnabled) SimpleTextAttributes.REGULAR_ATTRIBUTES else SimpleTextAttributes.GRAYED_ATTRIBUTES)
                    if (!v.isEnabled) append("  " + HyperEnvBundle.message("tree.disabled"), SimpleTextAttributes.GRAYED_SMALL_ATTRIBUTES)
                }
                is Node.Message -> {
                    icon = AllIcons.General.Information
                    append(node.text, SimpleTextAttributes.GRAYED_ATTRIBUTES)
                }
            }
        }
    }
}
