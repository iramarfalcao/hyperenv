package com.falcaosl.hyperenv.ui

import com.falcaosl.hyperenv.HyperEnvBundle
import com.falcaosl.hyperenv.cli.Variable
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.DialogWrapper
import com.intellij.openapi.ui.ValidationInfo
import com.intellij.ui.components.JBCheckBox
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBPasswordField
import com.intellij.ui.components.JBTextField
import com.intellij.util.ui.FormBuilder
import com.intellij.util.ui.UIUtil
import javax.swing.JComponent

/**
 * One variable: name, value and the secret switch. Adding accepts a pasted
 * `NAME=value` in the name field; editing keeps the name, because the
 * command has no rename — that would be a delete plus a create.
 */
class VariableDialog(project: Project, private val existing: Variable?) : DialogWrapper(project) {
    private val keyField = JBTextField(existing?.key ?: "", 32)
    private val valueField = JBPasswordField().apply { columns = 32; text = existing?.value ?: "" }
    private val secretBox = JBCheckBox(HyperEnvBundle.message("dialog.variable.secret"), existing?.isSecret ?: false)
    private val defaultEcho = valueField.echoChar

    val key: String get() = split(keyField.text).first
    val value: String get() = split(keyField.text).second ?: String(valueField.password)
    val isSecret: Boolean get() = secretBox.isSelected

    init {
        title = existing?.let { HyperEnvBundle.message("dialog.variable.title.edit", it.key) }
            ?: HyperEnvBundle.message("dialog.variable.title.new")
        keyField.isEditable = existing == null
        // The value is masked only while the variable is marked secret.
        secretBox.addChangeListener { updateEcho() }
        updateEcho()
        init()
    }

    private fun updateEcho() {
        valueField.echoChar = if (secretBox.isSelected) defaultEcho else 0.toChar()
    }

    override fun createCenterPanel(): JComponent {
        val form = FormBuilder.createFormBuilder()
            .addLabeledComponent(HyperEnvBundle.message("dialog.variable.key"), keyField)
        if (existing == null) {
            form.addComponentToRightColumn(
                JBLabel(HyperEnvBundle.message("dialog.variable.key.hint")).apply {
                    componentStyle = UIUtil.ComponentStyle.SMALL
                    fontColor = UIUtil.FontColor.BRIGHTER
                },
            )
        }
        return form
            .addLabeledComponent(HyperEnvBundle.message("dialog.variable.value"), valueField)
            .addComponent(secretBox)
            .panel
    }

    override fun getPreferredFocusedComponent(): JComponent = if (existing == null) keyField else valueField

    override fun doValidate(): ValidationInfo? =
        if (isValidKey(key)) null else ValidationInfo(HyperEnvBundle.message("dialog.variable.invalidKey"), keyField)

    companion object {
        private val keyPattern = Regex("^[A-Za-z_][A-Za-z0-9_]*$")

        /** The command's rule, so a bad name is caught before the round trip. */
        fun isValidKey(key: String): Boolean = keyPattern.matches(key)

        /**
         * `NAME=value` → (NAME, value); a bare name → (name, null). The first
         * `=` splits, as in the command, so the value may contain `=`.
         */
        fun split(text: String): Pair<String, String?> {
            val i = text.indexOf('=')
            return if (i < 0) text.trim() to null else text.substring(0, i).trim() to text.substring(i + 1)
        }
    }
}
