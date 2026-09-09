package com.falcaosl.hyperenv.cli

import com.falcaosl.hyperenv.HyperEnvBundle
import com.falcaosl.hyperenv.settings.HyperEnvSettings
import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.execution.configurations.PathEnvironmentVariableUtil
import com.intellij.execution.util.ExecUtil
import java.io.File

/**
 * Runs the command. Every call is a fresh process; the command owns the store
 * and the journal, so there is nothing to cache here that could go stale.
 *
 * Blocking — always call from a pooled thread, never the EDT.
 */
class HyperEnvCli(private val executable: File) {

    companion object {
        fun locate(): File? = CliLocator.resolve(
            override = HyperEnvSettings.getInstance().state.cliPath,
            findInPath = { PathEnvironmentVariableUtil.findInPath(it) },
            candidates = CliLocator.bundledCandidates(File(System.getProperty("user.home"))),
        )

        fun require(): HyperEnvCli =
            locate()?.let { HyperEnvCli(it) } ?: throw CliException(HyperEnvBundle.message("error.cliMissing"))
    }

    fun status(): Status = Envelope.status(run("status"))

    fun projects(): List<EnvProject> = Envelope.projects(run("projects"))

    fun variables(project: String, profile: String): List<EnvVariable> =
        Envelope.variables(run("vars", "--project", project, "--profile", profile))

    fun createProject(name: String): EnvProject = Envelope.project(run("project", "create", name).asJsonObject)

    fun deleteProject(project: String) { run("project", "delete", "--project", project) }

    fun createProfile(project: String, name: String, kind: String): EnvProfile =
        Envelope.profile(run("profile", "create", "--project", project, "--name", name, "--kind", kind).asJsonObject)

    fun duplicateProfile(project: String, profile: String): EnvProfile =
        Envelope.profile(run("profile", "duplicate", "--project", project, "--profile", profile).asJsonObject)

    fun deleteProfile(project: String, profile: String) { run("profile", "delete", "--project", project, "--profile", profile) }

    fun setVariable(project: String, profile: String, key: String, value: String, secret: Boolean, enabled: Boolean, note: String?): EnvVariable {
        val args = mutableListOf("var", "set", "--project", project, "--profile", profile)
        if (secret) args += "--secret"
        args += if (enabled) "--enabled" else "--disabled"
        note?.takeIf { it.isNotBlank() }?.let { args += listOf("--note", it) }
        args += "$key=$value"
        return Envelope.variable(run(*args.toTypedArray()).asJsonObject)
    }

    fun toggleVariable(project: String, profile: String, key: String, enabled: Boolean) {
        run("var", if (enabled) "enable" else "disable", "--project", project, "--profile", profile, key)
    }

    fun deleteVariable(project: String, profile: String, key: String) {
        run("var", "delete", "--project", project, "--profile", profile, key)
    }

    fun apply(project: String, profile: String): ApplyResult =
        Envelope.applyResult(run("apply", "--project", project, "--profile", profile))

    fun unapply() { run("unapply") }

    fun installHook() { run("hook", "install") }

    private fun run(vararg args: String) = Envelope.parse(execute(*args))

    private fun execute(vararg args: String): String {
        val command = GeneralCommandLine(listOf(executable.absolutePath, "--json") + args)
            .withCharset(Charsets.UTF_8)
        val output = ExecUtil.execAndGetOutput(command, 30_000)
        if (output.isTimeout) throw CliException("the hyperenv command did not answer in 30 seconds")
        // The command prints its envelope on stdout even when it fails; stderr
        // only carries a crash, which is the case worth surfacing verbatim.
        val stdout = output.stdout.trim()
        if (stdout.isEmpty()) throw CliException(output.stderr.trim().ifEmpty { "the hyperenv command printed nothing (exit ${output.exitCode})" })
        return stdout
    }
}
