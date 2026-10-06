package com.falcaosl.hyperenv.cli

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** The envelope and every shape the plugin reads, against real output. */
class EnvelopeTest {

    private fun data(fixture: String) = Envelope.parse(Fixtures.read(fixture))

    @Test
    fun `version`() {
        assertEquals("2.0.0-alpha.3", Envelope.version(data("version.json")))
    }

    @Test
    fun `error envelope becomes an exception carrying the command's message`() {
        try {
            Envelope.parse(Fixtures.read("error.json"))
            fail("expected CliException")
        } catch (e: CliException) {
            assertEquals("No profile named \"nope\".", e.message)
        }
    }

    @Test
    fun `non-JSON output is an exception, not a crash`() {
        try {
            Envelope.parse("Segmentation fault")
            fail("expected CliException")
        } catch (e: CliException) {
            assertTrue(e.message!!.contains("not JSON"))
        }
    }

    @Test
    fun `an envelope without ok is a failure`() {
        try {
            Envelope.parse("""{"data":{}}""")
            fail("expected CliException")
        } catch (_: CliException) {
        }
    }

    @Test
    fun `message-only results parse`() {
        assertTrue(data("profile-create.json").isJsonObject)
    }

    @Test
    fun `profiles are a flat list with the applied one marked`() {
        val profiles = Envelope.profiles(data("profiles.json"))
        assertEquals(listOf("dev", "prod"), profiles.map { it.name })
        assertTrue(profiles[0].isApplied)
        assertFalse(profiles[1].isApplied)
        assertEquals(3, profiles[0].variableCount)
        assertEquals(2, profiles[0].enabledCount)
        assertEquals("23153ceb-a2c1-4523-ac1b-1592c89a4b3e", profiles[0].id)
        assertTrue(profiles[0].updatedAt.startsWith("2026-"))
    }

    @Test
    fun `variables carry secret and enabled, values in full`() {
        val vars = Envelope.variables(data("vars.json"))
        assertEquals(listOf("API_URL", "TOKEN", "DEBUG"), vars.map { it.key })
        assertEquals("https://api.test/v1?a=b", vars[0].value)
        assertTrue(vars[1].isSecret)
        assertEquals("s3cret", vars[1].value)
        assertFalse(vars[2].isEnabled)
    }

    @Test
    fun `status with nothing applied has no applied`() {
        val s = Envelope.status(data("status-nothing-applied.json"))
        assertNull(s.applied)
        assertEquals("notInstalled", s.hook)
        assertEquals("zsh", s.shell)
        assertEquals("~/.zprofile", s.startupFile)
        assertEquals("source ~/.config/hyperenv/session.zsh", s.reloadCommand)
        assertEquals("source ~/.config/hyperenv/unsession.zsh", s.undoCommand)
        assertTrue(s.drift.isEmpty())
        assertEquals(0, s.pendingRecoveries)
    }

    @Test
    fun `status with a profile applied carries its exports`() {
        val s = Envelope.status(data("status-applied.json"))
        val a = s.applied!!
        assertEquals("dev", a.profileName)
        assertEquals("23153ceb-a2c1-4523-ac1b-1592c89a4b3e", a.profileId)
        assertEquals(listOf("API_URL", "TOKEN"), a.exportedKeys)
        assertEquals(mapOf("API_URL" to "https://api.test/v1?a=b", "TOKEN" to "s3cret"), a.exports)
        assertEquals("installed", s.hook)
    }

    @Test
    fun `drift items keep kind, key and values`() {
        // Hand-written: drift needs a shell that disagrees, which a fixture
        // run cannot produce. The kinds are the ones crates/cli/src/lib.rs emits.
        val s = Envelope.status(Envelope.parse(
            """{"ok":true,"data":{"version":"2.0.0","shell":"zsh","hook":"installed","pendingRecoveries":1,
               "reloadCommand":"r","undoCommand":"u","drift":[{"kind":"sessionEdited"},
               {"kind":"shadowed","key":"A","expected":"1","actual":"2"},{"kind":"missing","key":"B","expected":"x"}]}}"""))
        assertEquals(listOf("sessionEdited", "shadowed", "missing"), s.drift.map { it.kind })
        assertEquals(DriftItem("shadowed", "A", "1", "2"), s.drift[1])
        assertNull(s.drift[0].key)
        assertEquals(1, s.pendingRecoveries)
        assertNull(s.startupFile)
    }

    @Test
    fun `apply result`() {
        val r = Envelope.applyResult(data("apply.json"))
        assertEquals("dev", r.applied)
        assertEquals(listOf("API_URL", "TOKEN"), r.exported)
        assertEquals(listOf("API_URL", "TOKEN"), r.captured)
        assertTrue(r.restored.isEmpty())
        assertEquals("source ~/.config/hyperenv/session.zsh", r.reloadCommand)
    }

    @Test
    fun `unapply restores to nothing as a null target`() {
        val r = Envelope.applyResult(data("unapply.json"))
        assertNull(r.applied)
        assertNull(r.reloadCommand)
        assertEquals(listOf(Restore("API_URL", null), Restore("TOKEN", null)), r.restored)
        assertEquals("source ~/.config/hyperenv/unsession.zsh", r.undoCommand)
    }

    @Test
    fun `import reports its count and diagnostics`() {
        val r = Envelope.importResult(data("import.json"))
        assertEquals(2, r.imported)
        assertEquals(listOf(ImportDiagnostic(3, "error", "No '=' found. Line skipped.")), r.diagnostics)
    }

    @Test
    fun `export returns the dotenv text`() {
        assertEquals("# HyperEnv — profile prod\n\nA=\"1\"\nB=\"two\"\n", Envelope.exportText(data("export.json")))
    }

    @Test
    fun `a missing optional field never throws`() {
        val p = Envelope.profile(Envelope.parse("""{"ok":true,"data":{"id":"f","name":"x"}}""").asJsonObject)
        assertFalse(p.isApplied)
        assertEquals(0, p.variableCount)
        val v = Envelope.variable(Envelope.parse("""{"ok":true,"data":{"key":"K"}}""").asJsonObject)
        assertTrue(v.isEnabled)
        assertFalse(v.isSecret)
    }
}
