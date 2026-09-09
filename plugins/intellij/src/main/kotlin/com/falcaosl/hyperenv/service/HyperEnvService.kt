package com.falcaosl.hyperenv.service

import com.falcaosl.hyperenv.HyperEnvBundle
import com.falcaosl.hyperenv.cli.CliException
import com.falcaosl.hyperenv.cli.EnvProject
import com.falcaosl.hyperenv.cli.EnvVariable
import com.falcaosl.hyperenv.cli.HyperEnvCli
import com.falcaosl.hyperenv.cli.Status
import com.intellij.notification.NotificationGroupManager
import com.intellij.notification.NotificationType
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.components.Service
import com.intellij.openapi.project.Project

/**
 * The tree's data and every mutation, one place per IDE project. All work
 * runs on a pooled thread; the callback lands on the EDT with a fresh copy
 * of everything, because the command is the source of truth and re-reading
 * it is cheaper than keeping a second model in sync.
 */
@Service(Service.Level.PROJECT)
class HyperEnvService(private val project: Project) {

    data class Snapshot(
        val status: Status?,
        val projects: List<EnvProject>,
        val variables: Map<String, List<EnvVariable>>, // profile id -> variables
        val error: String?,
    )

    @Volatile
    var snapshot: Snapshot = Snapshot(null, emptyList(), emptyMap(), null)
        private set

    private val listeners = mutableListOf<() -> Unit>()

    fun addListener(listener: () -> Unit) { listeners += listener }

    /** Re-reads everything from the command. */
    fun refresh() = runInBackground({ cli ->
        val status = cli.status()
        val projects = cli.projects()
        val variables = HashMap<String, List<EnvVariable>>()
        for (p in projects) for (f in p.profiles) variables[f.id] = cli.variables(p.id, f.id)
        Snapshot(status, projects, variables, null)
    })

    // MARK: Mutations — each one re-reads afterwards.

    fun createProject(name: String) = mutate { it.createProject(name) }
    fun deleteProject(projectId: String) = mutate { it.deleteProject(projectId) }
    fun createProfile(projectId: String, name: String, kind: String) = mutate { it.createProfile(projectId, name, kind) }
    fun duplicateProfile(projectId: String, profileId: String) = mutate { it.duplicateProfile(projectId, profileId) }
    fun deleteProfile(projectId: String, profileId: String) = mutate { it.deleteProfile(projectId, profileId) }
    fun setVariable(projectId: String, profileId: String, key: String, value: String, secret: Boolean, enabled: Boolean, note: String?) =
        mutate { it.setVariable(projectId, profileId, key, value, secret, enabled, note) }
    fun toggleVariable(projectId: String, profileId: String, key: String, enabled: Boolean) =
        mutate { it.toggleVariable(projectId, profileId, key, enabled) }
    fun deleteVariable(projectId: String, profileId: String, key: String) = mutate { it.deleteVariable(projectId, profileId, key) }

    fun apply(projectId: String, profileId: String, displayPath: String) = mutate { cli ->
        val result = cli.apply(projectId, profileId)
        notify(HyperEnvBundle.message("notify.applied", displayPath, result.exported), NotificationType.INFORMATION)
    }

    fun unapply() = mutate { cli ->
        cli.unapply()
        notify(HyperEnvBundle.message("notify.reverted"), NotificationType.INFORMATION)
    }

    fun installHook() = mutate { cli ->
        cli.installHook()
        notify(HyperEnvBundle.message("notify.hookInstalled", cli.status().dotfile), NotificationType.INFORMATION)
    }

    // MARK: Plumbing

    private fun mutate(work: (HyperEnvCli) -> Unit) = runInBackground({ cli ->
        work(cli)
        val status = cli.status()
        val projects = cli.projects()
        val variables = HashMap<String, List<EnvVariable>>()
        for (p in projects) for (f in p.profiles) variables[f.id] = cli.variables(p.id, f.id)
        Snapshot(status, projects, variables, null)
    })

    private fun runInBackground(work: (HyperEnvCli) -> Snapshot) {
        ApplicationManager.getApplication().executeOnPooledThread {
            val next = try {
                work(HyperEnvCli.require())
            } catch (e: CliException) {
                notify(e.message ?: "error", NotificationType.ERROR)
                snapshot.copy(error = e.message)
            } catch (e: Exception) {
                notify(e.toString(), NotificationType.ERROR)
                snapshot.copy(error = e.toString())
            }
            ApplicationManager.getApplication().invokeLater {
                if (project.isDisposed) return@invokeLater
                snapshot = next
                listeners.toList().forEach { it() }
            }
        }
    }

    fun notify(content: String, type: NotificationType) {
        NotificationGroupManager.getInstance().getNotificationGroup("HyperEnv")
            .createNotification(HyperEnvBundle.message("error.title"), content, type)
            .notify(project)
    }

    companion object {
        fun getInstance(project: Project): HyperEnvService = project.getService(HyperEnvService::class.java)
    }
}
