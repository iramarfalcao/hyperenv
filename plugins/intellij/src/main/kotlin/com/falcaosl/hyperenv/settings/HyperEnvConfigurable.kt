package com.falcaosl.hyperenv.settings

import com.falcaosl.hyperenv.HyperEnvBundle
import com.falcaosl.hyperenv.cli.HyperEnvCli
import com.intellij.openapi.fileChooser.FileChooserDescriptorFactory
import com.intellij.openapi.options.Configurable
import com.intellij.openapi.ui.TextFieldWithBrowseButton
import com.intellij.ui.components.JBLabel
import com.intellij.util.ui.FormBuilder
import javax.swing.JComponent
import javax.swing.JPanel

/** Settings › Tools › HyperEnv: one field, the path to the command. */
class HyperEnvConfigurable : Configurable {
    private var pathField: TextFieldWithBrowseButton? = null
    private var foundLabel: JBLabel? = null

    override fun getDisplayName(): String = "HyperEnv"

    override fun createComponent(): JComponent {
        val field = TextFieldWithBrowseButton().also { pathField = it }
        field.addBrowseFolderListener(null, FileChooserDescriptorFactory.singleFile())
        val label = JBLabel().also { foundLabel = it }
        val panel: JPanel = FormBuilder.createFormBuilder()
            .addLabeledComponent(HyperEnvBundle.message("settings.cliPath"), field)
            .addComponentToRightColumn(JBLabel(HyperEnvBundle.message("settings.cliPath.hint")))
            .addComponentToRightColumn(label)
            .addComponentFillVertically(JPanel(), 0)
            .panel
        reset()
        return panel
    }

    override fun isModified(): Boolean = (pathField?.text ?: "") != HyperEnvSettings.getInstance().state.cliPath

    override fun apply() {
        HyperEnvSettings.getInstance().state.cliPath = pathField?.text?.trim() ?: ""
        refreshFound()
    }

    override fun reset() {
        pathField?.text = HyperEnvSettings.getInstance().state.cliPath
        refreshFound()
    }

    private fun refreshFound() {
        val found = HyperEnvCli.locate()
        foundLabel?.text = found?.let { HyperEnvBundle.message("settings.found", it.path) }
            ?: HyperEnvBundle.message("settings.notFound")
    }
}
