package com.falcaosl.hyperenv.cli

import java.io.File

/**
 * Finds the `hyperenv` command. In order: an explicit path from the settings,
 * the user's PATH, then the copy that ships inside the app bundle.
 *
 * Pure, so the order is unit-tested; the IDE-facing caller supplies the PATH
 * lookup and the home directory.
 */
object CliLocator {

    fun bundledCandidates(home: File): List<File> = listOf(
        File("/Applications/HyperEnv.app/Contents/Helpers/hyperenv"),
        File(home, "Applications/HyperEnv.app/Contents/Helpers/hyperenv"),
    )

    fun resolve(
        override: String?,
        findInPath: (String) -> File?,
        candidates: List<File>,
        exists: (File) -> Boolean = { it.isFile && it.canExecute() },
    ): File? {
        override?.trim()?.takeIf { it.isNotEmpty() }?.let { File(it) }?.let { if (exists(it)) return it }
        findInPath("hyperenv")?.let { if (exists(it)) return it }
        return candidates.firstOrNull(exists)
    }
}
