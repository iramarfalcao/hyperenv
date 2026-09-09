package com.falcaosl.hyperenv.ui

import com.falcaosl.hyperenv.HyperEnvBundle
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.ComboBox
import com.intellij.openapi.ui.DialogWrapper
import com.intellij.openapi.ui.ValidationInfo
import com.intellij.ui.components.JBTextField
import com.intellij.util.ui.FormBuilder
import javax.swing.JComponent

/** Name and kind. Pre-filled with dev, as the app does: the safe default. */
class ProfileDialog(project: Project) : DialogWrapper(project) {
    private val nameField = JBTextField("dev", 24)
    private val kindBox = ComboBox(arrayOf("dev", "hml", "prd", "custom"))

    val name: String get() = nameField.text.trim()
    val kind: String get() = kindBox.item as String

    init {
        title = HyperEnvBundle.message("dialog.newProfile.title")
        init()
    }

    override fun createCenterPanel(): JComponent = FormBuilder.createFormBuilder()
        .addLabeledComponent("Name", nameField)
        .addLabeledComponent("Kind", kindBox)
        .panel

    override fun getPreferredFocusedComponent(): JComponent = nameField

    override fun doValidate(): ValidationInfo? =
        if (name.isEmpty()) ValidationInfo("A profile needs a name.", nameField) else null
}
