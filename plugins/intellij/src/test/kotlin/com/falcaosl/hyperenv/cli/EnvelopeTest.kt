package com.falcaosl.hyperenv.cli

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** The envelope and the shapes, exactly as docs/CLI.md describes them. */
class EnvelopeTest {

    @Test
    fun `ok envelope yields its data`() {
        val data = Envelope.parse("""{"ok":true,"data":{"version":"1.2.3"}}""")
        assertEquals("1.2.3", data.asJsonObject["version"].asString)
    }

    @Test
    fun `error envelope becomes an exception carrying the command's message`() {
        try {
            Envelope.parse("""{"ok":false,"error":"no project named \"nope\""}""")
            fail("expected CliException")
        } catch (e: CliException) {
            assertEquals("no project named \"nope\"", e.message)
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
    fun `status without applied means nothing is applied`() {
        val status = Envelope.status(Envelope.parse(
            """{"ok":true,"data":{"version":"dev","hook":"notInstalled","drift":[],
               "reloadCommand":"source ~/.config/hyperenv/session.zsh","dotfile":"~/.zprofile"}}"""))
        assertNull(status.applied)
        assertEquals("notInstalled", status.hook)
        assertEquals("~/.zprofile", status.dotfile)
    }

    @Test
    fun `status with applied names the profile`() {
        val status = Envelope.status(Envelope.parse(
            """{"ok":true,"data":{"version":"dev","hook":"installed","drift":["managedFileEdited"],
               "applied":{"projectId":"p1","projectName":"payments","profileId":"f1","profileName":"dev",
                          "appliedAt":"2026-09-09T00:00:00Z","exportedKeys":["API_URL"]},
               "reloadCommand":"source x","dotfile":"~/.zprofile"}}"""))
        assertEquals("payments", status.applied?.projectName)
        assertEquals("dev", status.applied?.profileName)
        assertEquals(listOf("managedFileEdited"), status.drift)
    }

    @Test
    fun `projects carry their profiles in order`() {
        val projects = Envelope.projects(Envelope.parse(
            """{"ok":true,"data":[{"id":"p1","name":"payments","isDefault":false,"sortIndex":0,"profiles":[
                 {"id":"f1","name":"dev","kind":"dev","isDefault":false,"canBeApplied":true,"isApplied":true,"variableCount":3,"enabledCount":2,"sortIndex":0},
                 {"id":"f2","name":"prd","kind":"prd","isDefault":false,"canBeApplied":true,"isApplied":false,"variableCount":0,"enabledCount":0,"sortIndex":1}]}]}"""))
        assertEquals(1, projects.size)
        assertEquals(listOf("dev", "prd"), projects[0].profiles.map { it.name })
        assertTrue(projects[0].profiles[0].isApplied)
        assertFalse(projects[0].profiles[1].isApplied)
        assertEquals(2, projects[0].profiles[0].enabledCount)
    }

    @Test
    fun `a variable without a note has a null note`() {
        val vars = Envelope.variables(Envelope.parse(
            """{"ok":true,"data":[{"id":"v1","key":"TOKEN","value":"s","isEnabled":true,"isSecret":true,"origin":"authored","isValid":true,"sortIndex":0}]}"""))
        assertNull(vars[0].note)
        assertTrue(vars[0].isSecret)
    }

    @Test
    fun `a missing optional field never throws`() {
        val profile = Envelope.profile(Envelope.parse("""{"ok":true,"data":{"id":"f","name":"x"}}""").asJsonObject)
        assertEquals("custom", profile.kind)
        assertTrue(profile.canBeApplied)
        assertFalse(profile.isApplied)
    }
}
