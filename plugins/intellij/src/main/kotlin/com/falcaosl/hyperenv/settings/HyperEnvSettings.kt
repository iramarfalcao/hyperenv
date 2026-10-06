package com.falcaosl.hyperenv.settings

import com.falcaosl.hyperenv.cli.CliLocator
import com.intellij.ide.plugins.PluginManagerCore
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.components.PersistentStateComponent
import com.intellij.openapi.components.Service
import com.intellij.openapi.components.State
import com.intellij.openapi.components.Storage
import com.intellij.openapi.extensions.PluginId
import com.intellij.util.EnvironmentUtil
import java.io.File

@Service(Service.Level.APP)
@State(name = "com.falcaosl.hyperenv.settings", storages = [Storage("hyperenv.xml")])
class HyperEnvSettings : PersistentStateComponent<HyperEnvSettings.State> {

    class State {
        /** Empty means "find it" — see [CliLocator] for the order. */
        var cliPath: String = ""
    }

    private var current = State()

    override fun getState(): State = current
    override fun loadState(state: State) { current = state }

    /**
     * Where the command is right now, or null. Only file checks, no process,
     * so it is cheap enough for the settings page to call on the EDT.
     *
     * The PATH comes from [EnvironmentUtil], which on macOS is the login
     * shell's PATH rather than the bare one a Dock-launched IDE inherits.
     */
    fun locateCli(): File? {
        val os = CliLocator.currentOs()
        val home = File(System.getProperty("user.home"))
        return CliLocator.resolve(
            override = current.cliPath,
            appCandidates = CliLocator.appCandidates(os, home),
            pathCandidates = CliLocator.pathCandidates(EnvironmentUtil.getValue("PATH") ?: System.getenv("PATH"), os),
            installerCandidates = CliLocator.installerCandidates(os, home, System.getenv("LOCALAPPDATA")),
            bundledCandidate = bundledCli(os),
        )
    }

    /**
     * The command shipped inside the plugin. Zip extraction can drop the
     * executable bit, so it is restored here on macOS and Linux.
     */
    private fun bundledCli(os: CliLocator.Os): File? {
        val dir = PluginManagerCore.getPlugin(PluginId.getId(PLUGIN_ID))?.pluginPath?.toFile() ?: return null
        val file = CliLocator.bundledCandidate(dir, os) ?: return null
        if (os != CliLocator.Os.WINDOWS && file.isFile && !file.canExecute()) {
            runCatching { file.setExecutable(true) }
        }
        return file
    }

    companion object {
        const val PLUGIN_ID = "com.falcaosl.hyperenv"

        fun getInstance(): HyperEnvSettings = ApplicationManager.getApplication().getService(HyperEnvSettings::class.java)
    }
}
