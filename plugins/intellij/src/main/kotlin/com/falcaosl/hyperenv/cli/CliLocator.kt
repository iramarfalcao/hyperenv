package com.falcaosl.hyperenv.cli

import java.io.File

/**
 * Finds the `hyperenv` command. In order:
 *
 * 1. the explicit path from the settings;
 * 2. on macOS, the copy inside HyperEnv.app (`/Applications`, then `~/Applications`) —
 *    it ships with the app, so it is the one that matches the app's store;
 * 3. `hyperenv` on the PATH;
 * 4. where the installers put it: `~/.local/bin/hyperenv` on macOS and Linux,
 *    `%LOCALAPPDATA%\Programs\hyperenv\hyperenv.exe` on Windows. The IDE often
 *    starts without the shell's PATH, so this catches a fresh install anyway.
 *
 * Pure, so the order is unit-tested; the IDE-facing caller supplies the
 * operating system, the home directory and the PATH.
 */
object CliLocator {

    enum class Os { MAC, LINUX, WINDOWS }

    const val INSTALL_UNIX = "curl -fsSL https://hyperenv.falcaosl.com/install-cli.sh | sh"
    const val INSTALL_WINDOWS = "irm https://hyperenv.falcaosl.com/install.ps1 | iex"

    fun currentOs(osName: String = System.getProperty("os.name") ?: ""): Os {
        val n = osName.lowercase()
        return when {
            n.startsWith("mac") || n.contains("darwin") -> Os.MAC
            n.startsWith("windows") -> Os.WINDOWS
            else -> Os.LINUX
        }
    }

    fun executableName(os: Os) = if (os == Os.WINDOWS) "hyperenv.exe" else "hyperenv"

    fun appCandidates(os: Os, home: File): List<File> =
        if (os != Os.MAC) {
            emptyList()
        } else {
            listOf(
                File("/Applications/HyperEnv.app/Contents/Helpers/hyperenv"),
                File(home, "Applications/HyperEnv.app/Contents/Helpers/hyperenv"),
            )
        }

    fun installerCandidates(os: Os, home: File, localAppData: String?): List<File> =
        if (os == Os.WINDOWS) {
            listOfNotNull(
                localAppData?.takeIf { it.isNotBlank() }
                    ?.let { File(File(File(it, "Programs"), "hyperenv"), "hyperenv.exe") },
            )
        } else {
            listOf(File(home, ".local/bin/hyperenv"))
        }

    /** Every directory of a PATH string, in order, with the executable appended. */
    fun pathCandidates(path: String?, os: Os, separator: String = File.pathSeparator): List<File> =
        path.orEmpty().split(separator).filter { it.isNotBlank() }.map { File(it, executableName(os)) }

    fun resolve(
        override: String?,
        appCandidates: List<File>,
        pathCandidates: List<File>,
        installerCandidates: List<File>,
        exists: (File) -> Boolean = { it.isFile && it.canExecute() },
    ): File? {
        override?.trim()?.takeIf { it.isNotEmpty() }?.let { File(it) }?.let { if (exists(it)) return it }
        return (appCandidates + pathCandidates + installerCandidates).firstOrNull(exists)
    }

    /** HyperEnv 2 changed the grammar; a 1.x command would only produce confusing errors. */
    fun isSupportedVersion(version: String): Boolean =
        version.trim().removePrefix("v").substringBefore('.').toIntOrNull()?.let { it >= 2 } ?: false
}
