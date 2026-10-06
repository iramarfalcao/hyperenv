package com.falcaosl.hyperenv.cli

/**
 * What `hyperenv --json` reports, as described in crates/cli/README.md. The
 * command leaves a field out rather than sending null, so every optional field
 * here is nullable and a missing one is never a crash.
 */
data class Profile(
    val id: String,
    val name: String,
    val variableCount: Int,
    val enabledCount: Int,
    val isApplied: Boolean,
    val updatedAt: String,
)

data class Variable(
    val key: String,
    val value: String,
    val isSecret: Boolean,
    val isEnabled: Boolean,
)

data class Applied(
    val profileId: String,
    val profileName: String,
    val appliedAt: String,
    val exportedKeys: List<String>,
    /** The values a new terminal receives, as they were when Apply ran. */
    val exports: Map<String, String>,
)

/** One way the live environment no longer matches what was applied. */
data class DriftItem(
    /** sessionEdited, hookMissing, missing, shadowed — or a kind this build does not know yet. */
    val kind: String,
    val key: String?,
    val expected: String?,
    val actual: String?,
)

data class Status(
    val version: String,
    val shell: String,
    /** installed, notInstalled, notNeeded or malformed. */
    val hook: String,
    val hookDetail: String?,
    val applied: Applied?,
    val drift: List<DriftItem>,
    val pendingRecoveries: Int,
    val reloadCommand: String,
    val undoCommand: String,
    val startupFile: String?,
)

data class Restore(val key: String, val to: String?)

data class ApplyResult(
    val applied: String?,
    val exported: List<String>,
    val captured: List<String>,
    val restored: List<Restore>,
    val reloadCommand: String?,
    val undoCommand: String?,
)

data class ImportDiagnostic(val line: Int, val severity: String, val message: String)

data class ImportResult(val imported: Int, val diagnostics: List<ImportDiagnostic>)

/** A failed command: the message the command itself printed. */
class CliException(message: String) : Exception(message)
