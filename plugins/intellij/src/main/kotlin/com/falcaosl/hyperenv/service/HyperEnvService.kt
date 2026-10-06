package com.falcaosl.hyperenv.service

import com.falcaosl.hyperenv.HyperEnvBundle
import com.falcaosl.hyperenv.cli.CliException
import com.falcaosl.hyperenv.cli.CliLocator
import com.falcaosl.hyperenv.cli.HyperEnvCli
import com.falcaosl.hyperenv.cli.Profile
import com.falcaosl.hyperenv.cli.Status
import com.falcaosl.hyperenv.cli.Variable
import com.falcaosl.hyperenv.settings.HyperEnvSettings
import com.intellij.notification.Notification
import com.intellij.notification.NotificationAction
import com.intellij.notification.NotificationGroupManager
import com.intellij.notification.NotificationType
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.components.Service
import com.intellij.openapi.diagnostic.thisLogger
import com.intellij.openapi.ide.CopyPasteManager
import com.intellij.openapi.project.Project
import com.intellij.util.concurrency.AppExecutorUtil
import java.awt.datatransfer.StringSelection

/**
 * The panel's data and every mutation, one per IDE project.
 *
 * All command calls run on one background queue, in order — so two quick
 * clicks cannot race each other into the store — and the result lands on the
 * EDT as a fresh [Snapshot]. The command is the source of truth; re-reading
 * it after each change is cheaper than keeping a second model in sync.
 */
@Service(Service.Level.PROJECT)
class HyperEnvService(private val project: Project) {

    /** Whether there is a command to talk to, and if not, why. */
    sealed interface Connection {
        data object Unknown : Connection
        data object Missing : Connection
        data class TooOld(val path: String, val version: String) : Connection
        data class Broken(val path: String, val message: String) : Connection
        data class Ready(val path: String, val version: String) : Connection
    }

    data class Snapshot(
        val connection: Connection = Connection.Unknown,
        val profiles: List<Profile> = emptyList(),
        val status: Status? = null,
        /** Name of the selected profile; the command addresses profiles by name. */
        val selected: String? = null,
        val variables: List<Variable> = emptyList(),
        val busy: Boolean = false,
    ) {
        val selectedProfile: Profile? get() = profiles.firstOrNull { it.name == selected }
    }

    private val queue = AppExecutorUtil.createBoundedApplicationPoolExecutor("HyperEnv", 1)

    @Volatile
    var snapshot: Snapshot = Snapshot()
        private set

    private val listeners = mutableListOf<() -> Unit>()

    fun addListener(listener: () -> Unit) { listeners += listener }

    // Reading

    /** Re-reads everything: the command, the profiles, the status, the selected profile's variables. */
    fun refresh() = enqueue { cli, current -> reload(cli, current.selected) }

    /** Selecting only reads that profile's variables; status and the list stay as they are. */
    fun select(name: String?) {
        if (name == snapshot.selected) return
        publish(snapshot.copy(selected = name, variables = emptyList()))
        enqueue { cli, current ->
            current.copy(selected = name, variables = name?.let { cli.variables(it) } ?: emptyList())
        }
    }

    // Profiles

    fun createProfile(name: String) = mutate(Selection.To(name)) { it.createProfile(name) }
    fun renameProfile(name: String, newName: String) = mutate(Selection.To(newName)) { it.renameProfile(name, newName) }
    fun duplicateProfile(name: String, newName: String) = mutate(Selection.To(newName)) { it.duplicateProfile(name, newName) }
    fun deleteProfile(name: String) = mutate(Selection.To(null)) { it.deleteProfile(name) }

    // Variables

    fun setVariable(profile: String, key: String, value: String, secret: Boolean?) =
        mutate { it.setVariable(profile, key, value, secret) }

    fun setEnabled(profile: String, key: String, enabled: Boolean) = mutate { it.setEnabled(profile, key, enabled) }

    fun deleteVariable(profile: String, key: String) = mutate { it.deleteVariable(profile, key) }

    fun importFile(profile: String, file: java.io.File) = mutate { cli ->
        val result = cli.importFile(profile, file)
        val notes = result.diagnostics.joinToString("<br>") { "line ${it.line}: ${escape(it.message)}" }
        notify(
            HyperEnvBundle.message("notify.imported", result.imported, escape(profile)) +
                (if (notes.isEmpty()) "" else "<br>$notes"),
            if (result.diagnostics.isEmpty()) NotificationType.INFORMATION else NotificationType.WARNING,
        )
    }

    /** Writes the profile as a dotenv file. The command produces the text; the plugin only saves it. */
    fun exportFile(profile: String, file: java.io.File) = enqueue { cli, current ->
        file.writeText(cli.exportDotenv(profile))
        notify(HyperEnvBundle.message("notify.exported", escape(profile), escape(file.path)), NotificationType.INFORMATION)
        current
    }

    // Apply and undo

    fun apply(profile: String) = mutate { cli ->
        val result = cli.apply(profile)
        val reload = result.reloadCommand ?: ""
        notify(
            HyperEnvBundle.message("notify.applied", escape(profile), result.exported.size, escape(reload)),
            NotificationType.INFORMATION,
            copyAction(HyperEnvBundle.message("action.copyReload"), reload),
        )
    }

    fun unapply() = mutate { cli ->
        val result = cli.unapply()
        val undo = result.undoCommand ?: ""
        notify(
            HyperEnvBundle.message("notify.undone", result.restored.size, escape(undo)),
            NotificationType.INFORMATION,
            copyAction(HyperEnvBundle.message("action.copyUndo"), undo),
        )
    }

    // Plumbing

    /** What to select once a change lands: what was selected, or a given profile (renamed, new, gone). */
    private sealed interface Selection {
        data object Keep : Selection
        data class To(val name: String?) : Selection
    }

    private fun mutate(select: Selection = Selection.Keep, work: (HyperEnvCli) -> Unit) = enqueue { cli, current ->
        work(cli)
        reload(cli, (select as? Selection.To)?.name ?: current.selected.takeIf { select == Selection.Keep })
    }

    private fun reload(cli: HyperEnvCli, wanted: String?): Snapshot {
        val profiles = cli.profiles()
        val status = cli.status()
        // Keep the selection if it still exists; otherwise the applied
        // profile, otherwise the first — never an empty pane when there is
        // something to show.
        val selected = wanted?.takeIf { w -> profiles.any { it.name == w } }
            ?: profiles.firstOrNull { it.isApplied }?.name
            ?: profiles.firstOrNull()?.name
        val variables = selected?.let { cli.variables(it) } ?: emptyList()
        return Snapshot(
            connection = Connection.Ready(cli.executable.path, status.version),
            profiles = profiles, status = status, selected = selected, variables = variables,
        )
    }

    /**
     * Finds and checks the command, runs [work] on the queue, publishes the
     * result. A missing or too-old command becomes a state the panel shows,
     * not an error balloon on every click.
     */
    private fun enqueue(work: (HyperEnvCli, Snapshot) -> Snapshot) {
        publish(snapshot.copy(busy = true))
        queue.execute {
            val current = snapshot
            val next = try {
                val path = HyperEnvSettings.getInstance().locateCli()
                if (path == null) {
                    Snapshot(connection = Connection.Missing)
                } else {
                    val cli = HyperEnvCli(path)
                    val version = try {
                        cli.version()
                    } catch (e: CliException) {
                        null.also { publishLater(Snapshot(connection = Connection.Broken(path.path, e.message ?: ""))) }
                    }
                    when {
                        version == null -> null
                        !CliLocator.isSupportedVersion(version) -> Snapshot(connection = Connection.TooOld(path.path, version))
                        else -> work(cli, current)
                    }
                }
            } catch (e: CliException) {
                notify(escape(e.message ?: "error"), NotificationType.ERROR)
                current
            } catch (e: Exception) {
                thisLogger().warn("hyperenv call failed", e)
                notify(escape(e.toString()), NotificationType.ERROR)
                current
            }
            next?.let { publishLater(it) }
        }
    }

    private fun publishLater(next: Snapshot) {
        ApplicationManager.getApplication().invokeLater {
            if (!project.isDisposed) publish(next.copy(busy = false))
        }
    }

    private fun publish(next: Snapshot) {
        snapshot = next
        listeners.toList().forEach { it() }
    }

    fun copyToClipboard(text: String) {
        CopyPasteManager.getInstance().setContents(StringSelection(text))
    }

    private fun copyAction(label: String, text: String) = NotificationAction.createSimple(label) { copyToClipboard(text) }

    fun notify(content: String, type: NotificationType, vararg actions: NotificationAction) {
        val notification: Notification = NotificationGroupManager.getInstance().getNotificationGroup("HyperEnv")
            .createNotification(HyperEnvBundle.message("notify.title"), content, type)
        actions.forEach { notification.addAction(it) }
        notification.notify(project)
    }

    private fun escape(s: String) = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    companion object {
        fun getInstance(project: Project): HyperEnvService = project.getService(HyperEnvService::class.java)
    }
}
