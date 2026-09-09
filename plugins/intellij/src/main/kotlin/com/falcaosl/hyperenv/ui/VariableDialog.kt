package com.falcaosl.hyperenv.ui

import com.falcaosl.hyperenv.HyperEnvBundle
import com.falcaosl.hyperenv.cli.EnvVariable
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.DialogWrapper
import com.intellij.openapi.ui.ValidationInfo
import com.intellij.ui.components.JBCheckBox
import com.intellij.ui.components.JBTextField
import com.intellij.util.ui.FormBuilder
import javax.swing.JComponent

/** One variable: name, value, note, and the two switches. */
class VariableDialog(project: Project, private val existing: EnvVariable?) : DialogWrapper(project) {
    private val keyField = JBTextField(existing?.key ?: "", 32)
    private val valueField = JBTextField(existing?.value ?: "", 32)
    private val noteField = JBTextField(existing?.note ?: "", 32)
    private val secretBox = JBCheckBox(HyperEnvBundle.message("dialog.variable.secret"), existing?.isSecret ?: false)
    private val enabledBox = JBCheckBox(HyperEnvBundle.message("dialog.variable.enabled"), existing?.isEnabled ?: true)

    val key: String get() = keyField.text.trim()
    val value: String get() = valueField.text
    val note: String? get() = noteField.text.trim().ifEmpty { null }
    val isSecret: Boolean get() = secretBox.isSelected
    val isEnabled: Boolean get() = enabledBox.isSelected

    init {
        title = HyperEnvBundle.message(if (existing == null) "dialog.variable.title.new" else "dialog.variable.title.edit")
        // Renaming would be a delete plus a create; the command has no rename.
        keyField.isEditable = existing == null
        init()
    }

    override fun createCenterPanel(): JComponent = FormBuilder.createFormBuilder()
        .addLabeledComponent(HyperEnvBundle.message("dialog.variable.key"), keyField)
        .addLabeledComponent(HyperEnvBundle.message("dialog.variable.value"), valueField)
        .addLabeledComponent(HyperEnvBundle.message("dialog.variable.note"), noteField)
        .addComponent(secretBox)
        .addComponent(enabledBox)
        .panel

    override fun getPreferredFocusedComponent(): JComponent = if (existing == null) keyField else valueField

    override fun doValidate(): ValidationInfo? =
        if (isValidKey(key)) null else ValidationInfo(HyperEnvBundle.message("dialog.variable.invalidKey"), keyField)

    companion object {
        private val keyPattern = Regex("^[A-Za-z_][A-Za-z0-9_]*$")
        /** The same rule as the app's EnvKey, so a bad name is caught before the round trip. */
        fun isValidKey(key: String): Boolean = keyPattern.matches(key)
    }
}
