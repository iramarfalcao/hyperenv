package com.falcaosl.hyperenv.cli

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser

/**
 * Reads the `{"ok":…}` envelope every `--json` result is wrapped in, and the
 * shapes inside it. Pure, so it is unit-tested against output captured from
 * the real command.
 */
object Envelope {

    fun parse(text: String): JsonElement {
        val root = try {
            JsonParser.parseString(text)
        } catch (_: Exception) {
            throw CliException("The hyperenv command returned something that is not JSON: ${text.take(200)}")
        }
        val obj = root as? JsonObject ?: throw CliException("Unexpected output from hyperenv: ${text.take(200)}")
        if (obj["ok"]?.takeIf { it.isJsonPrimitive }?.asBoolean != true) {
            throw CliException(obj.strOrNull("error") ?: "The hyperenv command failed without saying why.")
        }
        return obj["data"] ?: JsonObject()
    }

    fun version(data: JsonElement): String = data.asJsonObject.str("version")

    fun profile(o: JsonObject) = Profile(
        id = o.str("id"),
        name = o.str("name"),
        variableCount = o.int("variableCount"),
        enabledCount = o.int("enabledCount"),
        isApplied = o.bool("isApplied"),
        updatedAt = o.str("updatedAt"),
    )

    fun profiles(data: JsonElement): List<Profile> = data.asJsonArray.map { profile(it.asJsonObject) }

    fun variable(o: JsonObject) = Variable(
        key = o.str("key"),
        value = o.str("value"),
        isSecret = o.bool("isSecret"),
        isEnabled = o.bool("isEnabled", true),
    )

    fun variables(data: JsonElement): List<Variable> = data.asJsonArray.map { variable(it.asJsonObject) }

    fun status(data: JsonElement): Status {
        val o = data.asJsonObject
        val applied = o.obj("applied")?.let { a ->
            Applied(
                profileId = a.str("profileId"),
                profileName = a.str("profileName"),
                appliedAt = a.str("appliedAt"),
                exportedKeys = a.strings("exportedKeys"),
                exports = a.obj("exports")?.entrySet()
                    ?.associate { (k, v) -> k to (if (v.isJsonPrimitive) v.asString else "") }
                    ?: emptyMap(),
            )
        }
        val drift = o.array("drift").mapNotNull { item ->
            // Anything that is not an object is read as a bare kind, so one
            // odd item never hides the rest.
            when {
                item.isJsonObject -> item.asJsonObject.let { d ->
                    DriftItem(d.str("kind"), d.strOrNull("key"), d.strOrNull("expected"), d.strOrNull("actual"))
                }
                item.isJsonPrimitive -> DriftItem(item.asString, null, null, null)
                else -> null
            }
        }
        return Status(
            version = o.str("version"),
            shell = o.str("shell"),
            hook = o.str("hook", "notInstalled"),
            hookDetail = o.strOrNull("hookDetail"),
            applied = applied,
            drift = drift,
            pendingRecoveries = o.int("pendingRecoveries"),
            reloadCommand = o.str("reloadCommand"),
            undoCommand = o.str("undoCommand"),
            startupFile = o.strOrNull("startupFile"),
        )
    }

    /** `apply` and `unapply` share this shape; unapply leaves out `applied` and `reloadCommand`. */
    fun applyResult(data: JsonElement): ApplyResult {
        val o = data.asJsonObject
        return ApplyResult(
            applied = o.strOrNull("applied"),
            exported = o.strings("exported"),
            captured = o.strings("captured"),
            restored = o.array("restored").filter { it.isJsonObject }.map { r ->
                val ro = r.asJsonObject
                Restore(ro.str("key"), ro.strOrNull("to"))
            },
            reloadCommand = o.strOrNull("reloadCommand"),
            undoCommand = o.strOrNull("undoCommand"),
        )
    }

    fun importResult(data: JsonElement): ImportResult {
        val o = data.asJsonObject
        return ImportResult(
            imported = o.int("imported"),
            diagnostics = o.array("diagnostics").filter { it.isJsonObject }.map { d ->
                val dobj = d.asJsonObject
                ImportDiagnostic(dobj.int("line"), dobj.str("severity", "warning"), dobj.str("message"))
            },
        )
    }

    fun exportText(data: JsonElement): String = data.asJsonObject.str("text")

    private fun JsonObject.str(name: String, default: String = ""): String = strOrNull(name) ?: default

    private fun JsonObject.strOrNull(name: String): String? =
        this[name]?.takeIf { it.isJsonPrimitive }?.asString

    private fun JsonObject.bool(name: String, default: Boolean = false): Boolean =
        this[name]?.takeIf { it.isJsonPrimitive }?.asBoolean ?: default

    private fun JsonObject.int(name: String, default: Int = 0): Int =
        this[name]?.takeIf { it.isJsonPrimitive }?.asInt ?: default

    private fun JsonObject.obj(name: String): JsonObject? = this[name]?.takeIf { it.isJsonObject }?.asJsonObject

    private fun JsonObject.array(name: String): List<JsonElement> =
        this[name]?.takeIf { it.isJsonArray }?.asJsonArray?.toList() ?: emptyList()

    private fun JsonObject.strings(name: String): List<String> =
        array(name).filter { it.isJsonPrimitive }.map { it.asString }
}
