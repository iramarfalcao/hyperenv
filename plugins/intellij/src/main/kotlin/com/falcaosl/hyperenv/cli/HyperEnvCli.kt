package com.falcaosl.hyperenv.cli

import java.io.File
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/**
 * Runs the command. Every call is a fresh process; the command owns the store
 * and the journal, so there is nothing to cache here that could go stale.
 *
 * Plain `ProcessBuilder` rather than the platform's `ExecUtil`, so the same
 * class runs in the IDE and in the integration test without an application.
 *
 * Blocking — always call from a background thread, never the EDT: apply,
 * unapply and status start the user's login shell to see what a new terminal
 * would get.
 *
 * [globalArgs] go before `--json`; the integration test passes the command's
 * hidden `--home <dir>` and `--shell` there so it never touches the real home.
 */
class HyperEnvCli(
    val executable: File,
    private val globalArgs: List<String> = emptyList(),
    private val timeoutSeconds: Long = 60,
) {

    fun version(): String = Envelope.version(run("version"))

    fun status(): Status = Envelope.status(run("status"))

    fun profiles(): List<Profile> = Envelope.profiles(run("profiles"))

    fun createProfile(name: String) { run("profile", "create", name) }
    fun deleteProfile(name: String) { run("profile", "delete", name) }
    fun renameProfile(name: String, newName: String) { run("profile", "rename", name, newName) }
    fun duplicateProfile(name: String, newName: String) { run("profile", "duplicate", name, newName) }

    fun variables(profile: String): List<Variable> = Envelope.variables(run("vars", profile))

    /** [secret] null leaves the secret flag as it is (the command's default when neither flag is given). */
    fun setVariable(profile: String, key: String, value: String, secret: Boolean? = null) {
        val args = mutableListOf("var", "set", profile, "$key=$value")
        when (secret) {
            true -> args += "--secret"
            false -> args += "--no-secret"
            null -> Unit
        }
        run(*args.toTypedArray())
    }

    fun setEnabled(profile: String, key: String, enabled: Boolean) {
        run("var", if (enabled) "enable" else "disable", profile, key)
    }

    fun deleteVariable(profile: String, key: String) { run("var", "delete", profile, key) }

    fun importFile(profile: String, file: File): ImportResult =
        Envelope.importResult(run("import", profile, file.absolutePath))

    fun exportDotenv(profile: String): String = Envelope.exportText(run("export", profile, "--dialect", "dotenv"))

    fun apply(profile: String): ApplyResult = Envelope.applyResult(run("apply", profile))

    fun unapply(): ApplyResult = Envelope.applyResult(run("unapply"))

    private fun run(vararg args: String) = Envelope.parse(execute(*args))

    private fun execute(vararg args: String): String {
        val process = try {
            ProcessBuilder(listOf(executable.absolutePath) + globalArgs + "--json" + args)
                .redirectInput(ProcessBuilder.Redirect.from(nullDevice()))
                .start()
        } catch (e: Exception) {
            throw CliException("Could not start ${executable.path}: ${e.message}")
        }
        // Drain both streams at once: a command that fills one pipe while we
        // wait on the other would otherwise hang.
        val stdout = CompletableFuture.supplyAsync { process.inputStream.readBytes().toString(Charsets.UTF_8) }
        val stderr = CompletableFuture.supplyAsync { process.errorStream.readBytes().toString(Charsets.UTF_8) }
        if (!process.waitFor(timeoutSeconds, TimeUnit.SECONDS)) {
            process.destroyForcibly()
            throw CliException("The hyperenv command did not answer in $timeoutSeconds seconds.")
        }
        // The command prints its envelope on stdout even when it fails; stderr
        // only carries a crash, which is the case worth surfacing verbatim.
        val out = stdout.get(5, TimeUnit.SECONDS).trim()
        if (out.isEmpty()) {
            val err = stderr.get(5, TimeUnit.SECONDS).trim()
            throw CliException(err.ifEmpty { "The hyperenv command printed nothing (exit ${process.exitValue()})." })
        }
        return out
    }

    private fun nullDevice() = File(if (File.separatorChar == '\\') "NUL" else "/dev/null")
}
