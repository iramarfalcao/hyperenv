package com.falcaosl.hyperenv.toolWindow

import com.falcaosl.hyperenv.HyperEnvBundle
import com.falcaosl.hyperenv.cli.AppliedCheck
import com.falcaosl.hyperenv.cli.CliLocator
import com.falcaosl.hyperenv.cli.DriftItem
import com.falcaosl.hyperenv.service.HyperEnvService.Connection
import com.falcaosl.hyperenv.service.HyperEnvService.Snapshot

/** The status line above the lists: what is applied, and whatever no longer matches. */
object StatusText {

    fun html(snap: Snapshot): String = "<html>" + lines(snap).joinToString("<br>") + "</html>"

    private fun lines(snap: Snapshot): List<String> {
        when (val c = snap.connection) {
            Connection.Unknown -> return listOf(HyperEnvBundle.message("status.loading"))
            Connection.Missing -> return listOf(
                HyperEnvBundle.message("status.missing", esc(CliLocator.INSTALL_UNIX), esc(CliLocator.INSTALL_WINDOWS)),
            )
            is Connection.TooOld -> return listOf(
                HyperEnvBundle.message("status.tooOld", esc(c.path), esc(c.version), esc(CliLocator.INSTALL_UNIX), esc(CliLocator.INSTALL_WINDOWS)),
            )
            is Connection.Broken -> return listOf(HyperEnvBundle.message("status.broken", esc(c.path), esc(c.message)))
            is Connection.Ready -> Unit
        }
        val status = snap.status ?: return listOf(HyperEnvBundle.message("status.loading"))
        val out = mutableListOf<String>()
        val applied = status.applied
        if (applied == null) {
            out += HyperEnvBundle.message("status.nothingApplied")
        } else {
            out += HyperEnvBundle.message("status.applied", esc(applied.profileName), applied.exports.size)
            // Only checkable for the selected profile: that is the one whose variables are loaded.
            val selected = snap.selectedProfile
            if (selected != null && selected.id == applied.profileId && AppliedCheck.changedSinceApplied(snap.variables, applied)) {
                out += "<b>" + HyperEnvBundle.message("status.changedSinceApplied") + "</b>"
            }
            out += HyperEnvBundle.message("status.reload", esc(status.reloadCommand))
        }
        val startup = status.startupFile ?: "the startup file"
        if (status.hook == "malformed") {
            out += HyperEnvBundle.message("status.hook.malformed", esc(startup), status.hookDetail?.let { ": " + esc(it) } ?: "")
        }
        if (status.pendingRecoveries > 0) out += HyperEnvBundle.message("status.recoveries", status.pendingRecoveries)
        if (status.drift.isNotEmpty()) {
            out += "<b>" + HyperEnvBundle.message("status.drift.title") + ":</b> " +
                status.drift.joinToString("; ") { describe(it, startup) }
        }
        return out
    }

    private fun describe(d: DriftItem, startup: String): String = when (d.kind) {
        "sessionEdited" -> HyperEnvBundle.message("status.drift.sessionEdited")
        "hookMissing" -> HyperEnvBundle.message("status.drift.hookMissing", esc(startup))
        "missing" -> HyperEnvBundle.message("status.drift.missing", esc(d.key ?: "?"))
        "shadowed" -> HyperEnvBundle.message("status.drift.shadowed", esc(d.key ?: "?"))
        else -> HyperEnvBundle.message("status.drift.other", esc(listOfNotNull(d.kind, d.key).joinToString(" ")))
    }

    private fun esc(s: String) = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
}
