package com.falcaosl.hyperenv.settings

import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.components.PersistentStateComponent
import com.intellij.openapi.components.Service
import com.intellij.openapi.components.State
import com.intellij.openapi.components.Storage

@Service(Service.Level.APP)
@State(name = "com.falcaosl.hyperenv.settings", storages = [Storage("hyperenv.xml")])
class HyperEnvSettings : PersistentStateComponent<HyperEnvSettings.State> {

    class State {
        /** Empty means "find it": PATH, then the copy inside HyperEnv.app. */
        var cliPath: String = ""
    }

    private var current = State()

    override fun getState(): State = current
    override fun loadState(state: State) { current = state }

    companion object {
        fun getInstance(): HyperEnvSettings = ApplicationManager.getApplication().getService(HyperEnvSettings::class.java)
    }
}
