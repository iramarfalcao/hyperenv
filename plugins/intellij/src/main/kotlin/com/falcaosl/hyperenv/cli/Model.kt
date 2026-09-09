package com.falcaosl.hyperenv.cli

/**
 * What the `hyperenv --json` command reports. Mirrors docs/CLI.md in the
 * repository root; a field the command leaves out is null here, never a crash.
 */
data class EnvProfile(
    val id: String,
    val name: String,
    val kind: String,
    val isDefault: Boolean,
    val canBeApplied: Boolean,
    val isApplied: Boolean,
    val variableCount: Int,
    val enabledCount: Int,
)

data class EnvProject(
    val id: String,
    val name: String,
    val isDefault: Boolean,
    val profiles: List<EnvProfile>,
)

data class EnvVariable(
    val id: String,
    val key: String,
    val value: String,
    val isEnabled: Boolean,
    val isSecret: Boolean,
    val note: String?,
    val isValid: Boolean,
)

data class Applied(val projectId: String, val projectName: String, val profileId: String, val profileName: String)

data class Status(
    val version: String,
    val applied: Applied?,
    val hook: String,
    val hookDetail: String?,
    val drift: List<String>,
    val reloadCommand: String,
    val dotfile: String,
)

data class ApplyResult(val exported: Int, val reloadCommand: String)

/** A failed command: the message the command itself printed. */
class CliException(message: String) : Exception(message)
