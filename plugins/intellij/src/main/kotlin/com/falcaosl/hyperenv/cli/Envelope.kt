package com.falcaosl.hyperenv.cli

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser

/**
 * Reads the `{"ok":…}` envelope every `--json` result is wrapped in. Pure, so
 * it is unit-tested without an IDE.
 */
object Envelope {

    fun parse(text: String): JsonElement {
        val root = try {
            JsonParser.parseString(text)
        } catch (e: Exception) {
            throw CliException("the hyperenv command returned something that is not JSON: ${text.take(200)}")
        }
        val obj = root as? JsonObject ?: throw CliException("unexpected output: ${text.take(200)}")
        if (obj["ok"]?.asBoolean != true) {
            throw CliException(obj["error"]?.takeUnless { it.isJsonNull }?.asString ?: "unknown error")
        }
        return obj["data"] ?: JsonObject()
    }

    fun profile(o: JsonObject) = EnvProfile(
        id = o.str("id"), name = o.str("name"), kind = o.str("kind", "custom"),
        isDefault = o.bool("isDefault"), canBeApplied = o.bool("canBeApplied", true),
        isApplied = o.bool("isApplied"), variableCount = o.int("variableCount"),
        enabledCount = o.int("enabledCount"),
    )

    fun project(o: JsonObject) = EnvProject(
        id = o.str("id"), name = o.str("name"), isDefault = o.bool("isDefault"),
        profiles = o.getAsJsonArray("profiles")?.map { profile(it.asJsonObject) } ?: emptyList(),
    )

    fun projects(data: JsonElement): List<EnvProject> = data.asJsonArray.map { project(it.asJsonObject) }

    fun variable(o: JsonObject) = EnvVariable(
        id = o.str("id"), key = o.str("key"), value = o.str("value"),
        isEnabled = o.bool("isEnabled", true), isSecret = o.bool("isSecret"),
        note = o.strOrNull("note"), isValid = o.bool("isValid", true),
    )

    fun variables(data: JsonElement): List<EnvVariable> = data.asJsonArray.map { variable(it.asJsonObject) }

    fun status(data: JsonElement): Status {
        val o = data.asJsonObject
        val applied = o.getAsJsonObject("applied")?.let {
            Applied(it.str("projectId"), it.str("projectName"), it.str("profileId"), it.str("profileName"))
        }
        return Status(
            version = o.str("version"), applied = applied,
            hook = o.str("hook", "notInstalled"), hookDetail = o.strOrNull("hookDetail"),
            drift = o.getAsJsonArray("drift")?.map { it.asString } ?: emptyList(),
            reloadCommand = o.str("reloadCommand"), dotfile = o.str("dotfile", "~/.zprofile"),
        )
    }

    fun applyResult(data: JsonElement): ApplyResult {
        val o = data.asJsonObject
        return ApplyResult(exported = o.int("exported"), reloadCommand = o.str("reloadCommand"))
    }

    private fun JsonObject.str(name: String, default: String = ""): String =
        this[name]?.takeUnless { it.isJsonNull }?.asString ?: default

    private fun JsonObject.strOrNull(name: String): String? = this[name]?.takeUnless { it.isJsonNull }?.asString
    private fun JsonObject.bool(name: String, default: Boolean = false): Boolean =
        this[name]?.takeUnless { it.isJsonNull }?.asBoolean ?: default

    private fun JsonObject.int(name: String, default: Int = 0): Int =
        this[name]?.takeUnless { it.isJsonNull }?.asInt ?: default
}
