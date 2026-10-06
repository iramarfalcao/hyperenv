package com.falcaosl.hyperenv.toolWindow

import com.falcaosl.hyperenv.HyperEnvBundle
import com.falcaosl.hyperenv.HyperEnvIcons
import com.falcaosl.hyperenv.cli.Profile
import com.falcaosl.hyperenv.cli.Variable
import com.falcaosl.hyperenv.service.HyperEnvService
import com.falcaosl.hyperenv.ui.VariableDialog
import com.intellij.icons.AllIcons
import com.intellij.notification.NotificationType
import com.intellij.openapi.actionSystem.ActionManager
import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.DefaultActionGroup
import com.intellij.openapi.actionSystem.Separator
import com.intellij.openapi.actionSystem.ToggleAction
import com.intellij.openapi.fileChooser.FileChooser
import com.intellij.openapi.fileChooser.FileChooserDescriptorFactory
import com.intellij.openapi.fileChooser.FileChooserFactory
import com.intellij.openapi.fileChooser.FileSaverDescriptor
import com.intellij.openapi.options.ShowSettingsUtil
import com.intellij.openapi.project.DumbAwareAction
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.InputValidator
import com.intellij.openapi.ui.Messages
import com.intellij.openapi.ui.SimpleToolWindowPanel
import com.intellij.ui.ColoredListCellRenderer
import com.intellij.ui.ColoredTableCellRenderer
import com.intellij.ui.OnePixelSplitter
import com.intellij.ui.PopupHandler
import com.intellij.ui.ScrollPaneFactory
import com.intellij.ui.SimpleTextAttributes
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBList
import com.intellij.ui.table.JBTable
import com.intellij.util.ui.JBUI
import java.awt.BorderLayout
import java.awt.event.MouseAdapter
import java.awt.event.MouseEvent
import javax.swing.DefaultListModel
import javax.swing.Icon
import javax.swing.JList
import javax.swing.JPanel
import javax.swing.JTable
import javax.swing.ListSelectionModel
import javax.swing.table.AbstractTableModel

/**
 * The tool window: a status line on top, the flat profile list, and the
 * selected profile's variables below it. Every action reads the current
 * [HyperEnvService.Snapshot] to decide whether it applies; every change goes
 * through the service, off the EDT.
 */
class HyperEnvPanel(private val project: Project) : SimpleToolWindowPanel(true, true) {
    private val service = HyperEnvService.getInstance(project)

    private val statusLabel = JBLabel().apply {
        setCopyable(true)
        border = JBUI.Borders.empty(6, 8)
        verticalAlignment = JBLabel.TOP
    }

    private val profileModel = DefaultListModel<Profile>()
    private val profileList = JBList(profileModel).apply {
        selectionMode = ListSelectionModel.SINGLE_SELECTION
        cellRenderer = ProfileRenderer()
        emptyText.text = HyperEnvBundle.message("panel.profiles.empty")
    }

    private val variableModel = VariableTableModel()
    private val variableTable = JBTable(variableModel).apply {
        setSelectionMode(ListSelectionModel.SINGLE_SELECTION)
        setShowGrid(false)
        emptyText.text = HyperEnvBundle.message("panel.variables.empty")
        setDefaultRenderer(Any::class.java, VariableRenderer())
    }

    /** Secrets are masked until the user asks; per panel, not persisted. */
    private var revealSecrets = false

    /** Set while the list is rebuilt from a snapshot, so that is not read as a user selection. */
    private var rendering = false

    init {
        val profileGroup = DefaultActionGroup(
            RefreshAction(),
            Separator.getInstance(),
            NewProfileAction(), RenameProfileAction(), DuplicateProfileAction(), DeleteProfileAction(),
            Separator.getInstance(),
            ApplyAction(), UnapplyAction(), CopyReloadAction(),
            Separator.getInstance(),
            ImportAction(), ExportAction(),
            Separator.getInstance(),
            SettingsAction(),
        )
        val variableGroup = DefaultActionGroup(
            NewVariableAction(), EditVariableAction(), DeleteVariableAction(),
            Separator.getInstance(),
            ToggleEnabledAction(), ToggleSecretAction(), CopyValueAction(),
            Separator.getInstance(),
            RevealSecretsAction(),
        )

        toolbar = ActionManager.getInstance().createActionToolbar("HyperEnvToolbar", profileGroup, true)
            .also { it.targetComponent = this }.component
        val variableToolbar = ActionManager.getInstance().createActionToolbar("HyperEnvVariablesToolbar", variableGroup, true)
            .also { it.targetComponent = this }.component

        val variablesPane = JPanel(BorderLayout()).apply {
            add(variableToolbar, BorderLayout.NORTH)
            add(ScrollPaneFactory.createScrollPane(variableTable), BorderLayout.CENTER)
        }
        val splitter = OnePixelSplitter(true, "HyperEnv.splitter", 0.35f).apply {
            firstComponent = ScrollPaneFactory.createScrollPane(profileList)
            secondComponent = variablesPane
        }
        setContent(JPanel(BorderLayout()).apply {
            add(statusLabel, BorderLayout.NORTH)
            add(splitter, BorderLayout.CENTER)
        })

        PopupHandler.installPopupMenu(profileList, profileGroup, "HyperEnvProfilesPopup")
        PopupHandler.installPopupMenu(variableTable, variableGroup, "HyperEnvVariablesPopup")

        profileList.addListSelectionListener {
            if (!it.valueIsAdjusting && !rendering) service.select(profileList.selectedValue?.name)
        }
        variableTable.addMouseListener(object : MouseAdapter() {
            override fun mouseClicked(e: MouseEvent) {
                if (e.clickCount == 2 && selectedVariable() != null) editVariable()
            }
        })

        service.addListener { render() }
        render()
        service.refresh()
    }

    // Rendering

    private fun render() {
        val snap = service.snapshot
        rendering = true
        try {
            if (profileModel.elements().toList() != snap.profiles) {
                profileModel.clear()
                snap.profiles.forEach(profileModel::addElement)
            }
            val index = snap.profiles.indexOfFirst { it.name == snap.selected }
            if (index >= 0 && profileList.selectedIndex != index) profileList.selectedIndex = index
            if (index < 0) profileList.clearSelection()
        } finally {
            rendering = false
        }
        val selectedKey = selectedVariable()?.key
        variableModel.set(snap.variables)
        snap.variables.indexOfFirst { it.key == selectedKey }.takeIf { it >= 0 }
            ?.let { variableTable.selectionModel.setSelectionInterval(it, it) }
        statusLabel.text = StatusText.html(snap)
        statusLabel.icon = if (snap.status?.drift?.isNotEmpty() == true) HyperEnvIcons.Drift else null
    }

    private fun selectedProfile(): Profile? = service.snapshot.selectedProfile

    private fun selectedVariable(): Variable? =
        variableTable.selectedRow.takeIf { it >= 0 }?.let { variableModel.rows.getOrNull(variableTable.convertRowIndexToModel(it)) }

    private val ready get() = service.snapshot.connection is HyperEnvService.Connection.Ready

    // Actions

    private abstract inner class Action(text: String, icon: Icon?, description: String? = null) :
        DumbAwareAction(text, description, icon) {
        override fun getActionUpdateThread() = ActionUpdateThread.EDT
        override fun update(e: AnActionEvent) { e.presentation.isEnabled = ready && enabled() }
        open fun enabled(): Boolean = true
    }

    private abstract inner class ProfileAction(text: String, icon: Icon?, description: String? = null) :
        Action(text, icon, description) {
        override fun enabled() = selectedProfile() != null
        final override fun actionPerformed(e: AnActionEvent) { selectedProfile()?.let(::perform) }
        abstract fun perform(profile: Profile)
    }

    private abstract inner class VariableAction(text: String, icon: Icon?) : Action(text, icon) {
        override fun enabled() = selectedProfile() != null && selectedVariable() != null
        final override fun actionPerformed(e: AnActionEvent) {
            val profile = selectedProfile() ?: return
            val variable = selectedVariable() ?: return
            perform(profile, variable)
        }
        abstract fun perform(profile: Profile, variable: Variable)
    }

    private inner class RefreshAction : Action(HyperEnvBundle.message("action.refresh"), AllIcons.Actions.Refresh) {
        // Refresh is how a missing command gets found again, so it is always on.
        override fun update(e: AnActionEvent) { e.presentation.isEnabled = !service.snapshot.busy }
        override fun actionPerformed(e: AnActionEvent) = service.refresh()
    }

    private inner class SettingsAction : DumbAwareAction(HyperEnvBundle.message("action.settings"), null, AllIcons.General.Settings) {
        override fun getActionUpdateThread() = ActionUpdateThread.EDT
        override fun actionPerformed(e: AnActionEvent) {
            ShowSettingsUtil.getInstance().showSettingsDialog(project, "HyperEnv")
            service.refresh()
        }
    }

    private inner class NewProfileAction : Action(HyperEnvBundle.message("action.newProfile"), HyperEnvIcons.Add) {
        override fun actionPerformed(e: AnActionEvent) {
            askName(HyperEnvBundle.message("dialog.newProfile.title"), "")?.let(service::createProfile)
        }
    }

    private inner class RenameProfileAction : ProfileAction(HyperEnvBundle.message("action.renameProfile"), AllIcons.Actions.Edit) {
        override fun perform(profile: Profile) {
            askName(HyperEnvBundle.message("dialog.renameProfile.title"), profile.name)
                ?.takeIf { it != profile.name }
                ?.let { service.renameProfile(profile.name, it) }
        }
    }

    private inner class DuplicateProfileAction : ProfileAction(HyperEnvBundle.message("action.duplicateProfile"), HyperEnvIcons.Copy) {
        override fun perform(profile: Profile) {
            askName(HyperEnvBundle.message("dialog.duplicateProfile.title"), HyperEnvBundle.message("dialog.duplicate.suggestion", profile.name))
                ?.let { service.duplicateProfile(profile.name, it) }
        }
    }

    private inner class DeleteProfileAction : ProfileAction(HyperEnvBundle.message("action.deleteProfile"), HyperEnvIcons.Delete) {
        // The command refuses it too; disabling says so before the click.
        override fun enabled() = selectedProfile()?.isApplied == false
        override fun update(e: AnActionEvent) {
            super.update(e)
            e.presentation.description = if (selectedProfile()?.isApplied == true) HyperEnvBundle.message("dialog.deleteApplied") else null
        }
        override fun perform(profile: Profile) {
            val ok = Messages.showYesNoDialog(
                project, HyperEnvBundle.message("dialog.deleteProfile.message", profile.name, profile.variableCount),
                HyperEnvBundle.message("dialog.deleteProfile.title"), Messages.getWarningIcon(),
            ) == Messages.YES
            if (ok) service.deleteProfile(profile.name)
        }
    }

    private inner class ApplyAction : ProfileAction(
        HyperEnvBundle.message("action.apply"), HyperEnvIcons.Apply, HyperEnvBundle.message("action.apply.description"),
    ) {
        // Re-applying the applied profile is how an edit reaches new terminals,
        // so it stays enabled for the applied one too.
        override fun perform(profile: Profile) = service.apply(profile.name)
    }

    private inner class UnapplyAction : Action(
        HyperEnvBundle.message("action.unapply"), HyperEnvIcons.Undo, HyperEnvBundle.message("action.unapply.description"),
    ) {
        override fun enabled() = service.snapshot.status?.applied != null
        override fun actionPerformed(e: AnActionEvent) = service.unapply()
    }

    private inner class CopyReloadAction : Action(
        HyperEnvBundle.message("action.copyReload"), HyperEnvIcons.Terminal, HyperEnvBundle.message("action.copyReload.description"),
    ) {
        override fun enabled() = service.snapshot.status?.applied != null
        override fun actionPerformed(e: AnActionEvent) {
            val command = service.snapshot.status?.reloadCommand ?: return
            copy(command)
        }
    }

    private inner class ImportAction : ProfileAction(HyperEnvBundle.message("action.import"), HyperEnvIcons.Import) {
        override fun perform(profile: Profile) {
            val descriptor = FileChooserDescriptorFactory.singleFile()
                .withTitle(HyperEnvBundle.message("dialog.import.title", profile.name))
            val file = FileChooser.chooseFile(descriptor, project, null) ?: return
            service.importFile(profile.name, java.io.File(file.path))
        }
    }

    private inner class ExportAction : ProfileAction(HyperEnvBundle.message("action.export"), HyperEnvIcons.Export) {
        override fun perform(profile: Profile) {
            val descriptor = FileSaverDescriptor(
                HyperEnvBundle.message("dialog.export.title", profile.name),
                HyperEnvBundle.message("dialog.export.description"),
            )
            val target = FileChooserFactory.getInstance().createSaveFileDialog(descriptor, project)
                .save("${profile.name}.env") ?: return
            service.exportFile(profile.name, target.file)
        }
    }

    private inner class NewVariableAction : ProfileAction(HyperEnvBundle.message("action.newVariable"), HyperEnvIcons.Add) {
        override fun perform(profile: Profile) {
            val dialog = VariableDialog(project, null)
            if (dialog.showAndGet()) service.setVariable(profile.name, dialog.key, dialog.value, dialog.isSecret)
        }
    }

    private inner class EditVariableAction : VariableAction(HyperEnvBundle.message("action.editVariable"), AllIcons.Actions.Edit) {
        override fun perform(profile: Profile, variable: Variable) = editVariable()
    }

    private fun editVariable() {
        val profile = selectedProfile() ?: return
        val variable = selectedVariable() ?: return
        val dialog = VariableDialog(project, variable)
        if (dialog.showAndGet()) service.setVariable(profile.name, variable.key, dialog.value, dialog.isSecret)
    }

    private inner class DeleteVariableAction : VariableAction(HyperEnvBundle.message("action.deleteVariable"), HyperEnvIcons.Delete) {
        override fun perform(profile: Profile, variable: Variable) {
            val ok = Messages.showYesNoDialog(
                project, HyperEnvBundle.message("dialog.deleteVariable.message", variable.key, profile.name),
                HyperEnvBundle.message("dialog.deleteVariable.title"), Messages.getWarningIcon(),
            ) == Messages.YES
            if (ok) service.deleteVariable(profile.name, variable.key)
        }
    }

    private inner class ToggleEnabledAction : VariableAction(HyperEnvBundle.message("action.toggleEnabled"), HyperEnvIcons.Confirm) {
        override fun perform(profile: Profile, variable: Variable) =
            service.setEnabled(profile.name, variable.key, !variable.isEnabled)
    }

    private inner class ToggleSecretAction : VariableAction(HyperEnvBundle.message("action.toggleSecret"), HyperEnvIcons.Secret) {
        // `var set` with the same value and the flag flipped: the command has
        // no separate verb for it.
        override fun perform(profile: Profile, variable: Variable) =
            service.setVariable(profile.name, variable.key, variable.value, !variable.isSecret)
    }

    private inner class CopyValueAction : VariableAction(HyperEnvBundle.message("action.copyValue"), HyperEnvIcons.Copy) {
        override fun perform(profile: Profile, variable: Variable) = copy(variable.value)
    }

    private inner class RevealSecretsAction : ToggleAction(HyperEnvBundle.message("action.revealSecrets"), null, HyperEnvIcons.Reveal) {
        override fun getActionUpdateThread() = ActionUpdateThread.EDT
        override fun isSelected(e: AnActionEvent) = revealSecrets
        override fun setSelected(e: AnActionEvent, state: Boolean) {
            revealSecrets = state
            variableTable.repaint()
        }
        override fun update(e: AnActionEvent) {
            super.update(e)
            e.presentation.icon = if (revealSecrets) HyperEnvIcons.Conceal else HyperEnvIcons.Reveal
        }
    }

    // Helpers

    private fun copy(text: String) {
        service.copyToClipboard(text)
        service.notify(HyperEnvBundle.message("notify.copied"), NotificationType.INFORMATION)
    }

    private fun askName(title: String, initial: String): String? =
        Messages.showInputDialog(
            project, HyperEnvBundle.message("dialog.profileName"), title, null, initial,
            object : InputValidator {
                override fun checkInput(inputString: String?) = !inputString.isNullOrBlank()
                override fun canClose(inputString: String?) = checkInput(inputString)
            },
        )?.trim()?.takeIf { it.isNotEmpty() }

    // Renderers

    private class ProfileRenderer : ColoredListCellRenderer<Profile>() {
        override fun customizeCellRenderer(list: JList<out Profile>, value: Profile?, index: Int, selected: Boolean, hasFocus: Boolean) {
            val p = value ?: return
            icon = if (p.isApplied) HyperEnvIcons.Apply else HyperEnvIcons.Profile
            append(p.name, if (p.isApplied) SimpleTextAttributes.REGULAR_BOLD_ATTRIBUTES else SimpleTextAttributes.REGULAR_ATTRIBUTES)
            append("  ${p.enabledCount}/${p.variableCount}", SimpleTextAttributes.GRAYED_SMALL_ATTRIBUTES)
            if (p.isApplied) append("  ● applied", SimpleTextAttributes.GRAYED_BOLD_ATTRIBUTES)
        }
    }

    private class VariableTableModel : AbstractTableModel() {
        var rows: List<Variable> = emptyList()
            private set

        fun set(next: List<Variable>) {
            if (next == rows) return
            rows = next
            fireTableDataChanged()
        }

        override fun getRowCount() = rows.size
        override fun getColumnCount() = 2
        override fun getColumnName(column: Int): String =
            HyperEnvBundle.message(if (column == 0) "panel.column.name" else "panel.column.value")
        override fun getValueAt(rowIndex: Int, columnIndex: Int): Any = rows[rowIndex]
    }

    private inner class VariableRenderer : ColoredTableCellRenderer() {
        override fun customizeCellRenderer(table: JTable, value: Any?, selected: Boolean, hasFocus: Boolean, row: Int, column: Int) {
            val v = value as? Variable ?: return
            // Disabled variables stay in the list, dimmed: they are kept, just not exported.
            val attrs = if (v.isEnabled) SimpleTextAttributes.REGULAR_ATTRIBUTES else SimpleTextAttributes.GRAYED_ATTRIBUTES
            if (column == 0) {
                icon = if (v.isSecret) HyperEnvIcons.Secret else null
                append(v.key, attrs)
                if (!v.isEnabled) append("  " + HyperEnvBundle.message("panel.disabled"), SimpleTextAttributes.GRAYED_SMALL_ATTRIBUTES)
            } else {
                val shown = if (v.isSecret && !revealSecrets) "••••••••" else v.value
                append(shown.replace("\n", "⏎"), attrs)
            }
        }
    }
}
