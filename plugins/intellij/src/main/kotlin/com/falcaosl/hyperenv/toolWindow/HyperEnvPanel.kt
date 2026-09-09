package com.falcaosl.hyperenv.toolWindow

import com.falcaosl.hyperenv.HyperEnvBundle
import com.falcaosl.hyperenv.service.HyperEnvService
import com.falcaosl.hyperenv.ui.ProfileDialog
import com.falcaosl.hyperenv.ui.VariableDialog
import com.intellij.icons.AllIcons
import com.intellij.notification.NotificationType
import com.intellij.openapi.actionSystem.ActionManager
import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.DefaultActionGroup
import com.intellij.openapi.ide.CopyPasteManager
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.Messages
import com.intellij.openapi.ui.SimpleToolWindowPanel
import com.intellij.ui.PopupHandler
import com.intellij.ui.components.JBScrollPane
import java.awt.datatransfer.StringSelection
import java.awt.event.MouseAdapter
import java.awt.event.MouseEvent
import javax.swing.Icon

/**
 * The tool window: a toolbar, the tree, and a context menu — every action
 * decides from the selected row what it can do.
 */
class HyperEnvPanel(private val project: Project) : SimpleToolWindowPanel(true, true) {
    private val service = HyperEnvService.getInstance(project)
    private val tree = EnvTree()

    init {
        val group = DefaultActionGroup(
            RefreshAction(), NewProjectAction(), NewProfileAction(), NewVariableAction(),
            com.intellij.openapi.actionSystem.Separator.getInstance(),
            ApplyAction(), UnapplyAction(),
            com.intellij.openapi.actionSystem.Separator.getInstance(),
            EditAction(), ToggleAction(), DuplicateAction(), DeleteAction(),
            com.intellij.openapi.actionSystem.Separator.getInstance(),
            CopyReloadAction(), InstallHookAction(),
        )
        toolbar = ActionManager.getInstance().createActionToolbar("HyperEnvToolbar", group, true)
            .also { it.targetComponent = this }.component
        setContent(JBScrollPane(tree))

        PopupHandler.installPopupMenu(tree, group, "HyperEnvTreePopup")
        tree.addMouseListener(object : MouseAdapter() {
            override fun mouseClicked(e: MouseEvent) {
                if (e.clickCount == 2 && tree.selectedNode is Node.VariableNode) edit()
            }
        })

        service.addListener { tree.render(service.snapshot) }
        tree.render(service.snapshot)
        service.refresh()
    }

    // MARK: Actions

    private abstract inner class Action(text: String, icon: Icon) : AnAction(text, null, icon) {
        override fun getActionUpdateThread() = ActionUpdateThread.EDT
        override fun update(e: AnActionEvent) { e.presentation.isEnabled = enabled(tree.selectedNode) }
        open fun enabled(node: Node?): Boolean = true
    }

    private inner class RefreshAction : Action(HyperEnvBundle.message("action.refresh"), AllIcons.Actions.Refresh) {
        override fun actionPerformed(e: AnActionEvent) = service.refresh()
    }

    private inner class NewProjectAction : Action(HyperEnvBundle.message("action.newProject"), AllIcons.General.Add) {
        override fun actionPerformed(e: AnActionEvent) {
            val name = Messages.showInputDialog(
                project, HyperEnvBundle.message("dialog.newProject.message"),
                HyperEnvBundle.message("dialog.newProject.title"), null,
            )?.trim() ?: return
            if (name.isNotEmpty()) service.createProject(name)
        }
    }

    private inner class NewProfileAction : Action(HyperEnvBundle.message("action.newProfile"), AllIcons.Nodes.Folder) {
        override fun enabled(node: Node?) = node != null && node !is Node.Message
        override fun actionPerformed(e: AnActionEvent) {
            val projectId = projectOf(tree.selectedNode) ?: return
            val dialog = ProfileDialog(project)
            if (dialog.showAndGet()) service.createProfile(projectId, dialog.name, dialog.kind)
        }
    }

    private inner class NewVariableAction : Action(HyperEnvBundle.message("action.newVariable"), AllIcons.Nodes.Variable) {
        override fun enabled(node: Node?) = node is Node.ProfileNode || node is Node.VariableNode
        override fun actionPerformed(e: AnActionEvent) {
            val (projectId, profileId) = profileOf(tree.selectedNode) ?: return
            val dialog = VariableDialog(project, null)
            if (dialog.showAndGet()) service.setVariable(projectId, profileId, dialog.key, dialog.value, dialog.isSecret, dialog.isEnabled, dialog.note)
        }
    }

    private inner class EditAction : Action(HyperEnvBundle.message("action.edit"), AllIcons.Actions.Edit) {
        override fun enabled(node: Node?) = node is Node.VariableNode
        override fun actionPerformed(e: AnActionEvent) = edit()
    }

    private fun edit() {
        val node = tree.selectedNode as? Node.VariableNode ?: return
        val dialog = VariableDialog(project, node.variable)
        if (dialog.showAndGet()) {
            service.setVariable(node.project.id, node.profile.id, node.variable.key, dialog.value, dialog.isSecret, dialog.isEnabled, dialog.note)
        }
    }

    private inner class ToggleAction : Action(HyperEnvBundle.message("action.toggle"), AllIcons.Actions.Checked) {
        override fun enabled(node: Node?) = node is Node.VariableNode
        override fun actionPerformed(e: AnActionEvent) {
            val node = tree.selectedNode as? Node.VariableNode ?: return
            service.toggleVariable(node.project.id, node.profile.id, node.variable.key, !node.variable.isEnabled)
        }
    }

    private inner class DuplicateAction : Action(HyperEnvBundle.message("action.duplicate"), AllIcons.Actions.Copy) {
        override fun enabled(node: Node?) = node is Node.ProfileNode
        override fun actionPerformed(e: AnActionEvent) {
            val node = tree.selectedNode as? Node.ProfileNode ?: return
            service.duplicateProfile(node.project.id, node.profile.id)
        }
    }

    private inner class DeleteAction : Action(HyperEnvBundle.message("action.delete"), AllIcons.General.Remove) {
        override fun enabled(node: Node?) = when (node) {
            is Node.ProjectNode -> !node.project.isDefault
            is Node.ProfileNode -> !node.profile.isDefault && !node.profile.isApplied
            is Node.VariableNode -> true
            else -> false
        }
        override fun actionPerformed(e: AnActionEvent) {
            val node = tree.selectedNode ?: return
            val what = when (node) {
                is Node.ProjectNode -> "project ${node.project.name}"
                is Node.ProfileNode -> "profile ${node.displayPath}"
                is Node.VariableNode -> node.variable.key
                else -> return
            }
            val ok = Messages.showYesNoDialog(
                project, HyperEnvBundle.message("dialog.delete.message", what),
                HyperEnvBundle.message("dialog.delete.title"), Messages.getWarningIcon(),
            ) == Messages.YES
            if (!ok) return
            when (node) {
                is Node.ProjectNode -> service.deleteProject(node.project.id)
                is Node.ProfileNode -> service.deleteProfile(node.project.id, node.profile.id)
                is Node.VariableNode -> service.deleteVariable(node.project.id, node.profile.id, node.variable.key)
                is Node.Message -> Unit
            }
        }
    }

    private inner class ApplyAction : Action(HyperEnvBundle.message("action.apply"), AllIcons.Actions.Execute) {
        override fun enabled(node: Node?): Boolean {
            val profile = (node as? Node.ProfileNode)?.profile ?: (node as? Node.VariableNode)?.profile ?: return false
            return profile.canBeApplied && !profile.isApplied
        }
        override fun actionPerformed(e: AnActionEvent) {
            val node = tree.selectedNode
            val (projectId, profileId) = profileOf(node) ?: return
            val path = when (node) {
                is Node.ProfileNode -> node.displayPath
                is Node.VariableNode -> "${node.project.name}/${node.profile.name}"
                else -> return
            }
            service.apply(projectId, profileId, path)
        }
    }

    private inner class UnapplyAction : Action(HyperEnvBundle.message("action.unapply"), AllIcons.Actions.Suspend) {
        override fun enabled(node: Node?) = service.snapshot.status?.applied != null
        override fun actionPerformed(e: AnActionEvent) = service.unapply()
    }

    private inner class CopyReloadAction : Action(HyperEnvBundle.message("action.copyReload"), AllIcons.Actions.Copy) {
        override fun enabled(node: Node?) = service.snapshot.status?.applied != null
        override fun actionPerformed(e: AnActionEvent) {
            val command = service.snapshot.status?.reloadCommand ?: return
            CopyPasteManager.getInstance().setContents(StringSelection(command))
            service.notify(HyperEnvBundle.message("notify.copied"), NotificationType.INFORMATION)
        }
    }

    private inner class InstallHookAction : Action(HyperEnvBundle.message("action.installHook"), AllIcons.General.Settings) {
        override fun enabled(node: Node?) = service.snapshot.status?.hook != "installed"
        override fun actionPerformed(e: AnActionEvent) = service.installHook()
    }

    // MARK: Selection helpers

    private fun projectOf(node: Node?): String? = when (node) {
        is Node.ProjectNode -> node.project.id
        is Node.ProfileNode -> node.project.id
        is Node.VariableNode -> node.project.id
        else -> null
    }

    private fun profileOf(node: Node?): Pair<String, String>? = when (node) {
        is Node.ProfileNode -> node.project.id to node.profile.id
        is Node.VariableNode -> node.project.id to node.profile.id
        else -> null
    }
}
