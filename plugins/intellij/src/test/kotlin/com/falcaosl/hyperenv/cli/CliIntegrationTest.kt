package com.falcaosl.hyperenv.cli

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * Drives the real command end to end against a throwaway `--home`, so it
 * never touches the real startup file or store.
 *
 * The command comes from `-Dhyperenv.cli=…` or `HYPERENV_CLI`, else the
 * repository's own `target/release/hyperenv`; with none, the test is skipped.
 */
class CliIntegrationTest {
    private lateinit var home: File
    private lateinit var cli: HyperEnvCli

    @Before
    fun setUp() {
        val path = System.getProperty("hyperenv.cli")?.takeIf { it.isNotBlank() }
            ?: System.getenv("HYPERENV_CLI")?.takeIf { it.isNotBlank() }
            ?: File("../../target/release/hyperenv").absolutePath
        val exe = File(path)
        assumeTrue("no hyperenv command at $path", exe.canExecute())
        assumeTrue("zsh is needed for apply", File("/bin/zsh").canExecute())
        home = Files.createTempDirectory("hyperenv-it").toFile()
        cli = HyperEnvCli(exe, listOf("--home", home.absolutePath, "--shell", "/bin/zsh"))
    }

    @After
    fun tearDown() {
        if (::home.isInitialized) home.deleteRecursively()
    }

    @Test
    fun `create, set, list, apply, status, unapply`() {
        assertTrue(CliLocator.isSupportedVersion(cli.version()))

        cli.createProfile("dev")
        cli.setVariable("dev", "API_URL", "https://x.test/?a=b")
        cli.setVariable("dev", "TOKEN", "s3cret", secret = true)
        cli.setVariable("dev", "OFF", "1")
        cli.setEnabled("dev", "OFF", false)

        val profiles = cli.profiles()
        assertEquals(listOf("dev"), profiles.map { it.name })
        assertEquals(3, profiles[0].variableCount)
        assertEquals(2, profiles[0].enabledCount)

        val vars = cli.variables("dev").associateBy { it.key }
        assertEquals("https://x.test/?a=b", vars.getValue("API_URL").value)
        assertTrue(vars.getValue("TOKEN").isSecret)
        assertFalse(vars.getValue("OFF").isEnabled)

        // Flipping the secret flag keeps the value.
        cli.setVariable("dev", "TOKEN", "s3cret", secret = false)
        assertFalse(cli.variables("dev").first { it.key == "TOKEN" }.isSecret)

        val applied = cli.apply("dev")
        assertEquals("dev", applied.applied)
        assertEquals(setOf("API_URL", "TOKEN"), applied.exported.toSet())
        assertTrue(applied.reloadCommand!!.isNotBlank())

        val status = cli.status()
        assertEquals("dev", status.applied?.profileName)
        assertFalse(AppliedCheck.changedSinceApplied(cli.variables("dev"), status.applied!!))
        assertTrue(cli.profiles().single().isApplied)

        cli.setVariable("dev", "API_URL", "changed")
        assertTrue(AppliedCheck.changedSinceApplied(cli.variables("dev"), cli.status().applied!!))

        // The applied profile cannot be deleted.
        try {
            cli.deleteProfile("dev")
            fail("deleting the applied profile should fail")
        } catch (_: CliException) {
        }

        val undone = cli.unapply()
        assertEquals(setOf("API_URL", "TOKEN"), undone.restored.map { it.key }.toSet())
        assertNull(cli.status().applied)
    }

    @Test
    fun `rename, duplicate, import, export, delete`() {
        cli.createProfile("a")
        cli.renameProfile("a", "b")
        cli.duplicateProfile("b", "c")
        assertEquals(setOf("b", "c"), cli.profiles().map { it.name }.toSet())

        val env = File(home, "in.env").apply { writeText("X=1\nexport Y=\"two words\"\n") }
        val result = cli.importFile("c", env)
        assertEquals(2, result.imported)
        assertTrue(cli.exportDotenv("c").contains("Y=\"two words\""))

        cli.deleteVariable("c", "X")
        assertEquals(listOf("Y"), cli.variables("c").map { it.key })
        cli.deleteProfile("c")
        assertEquals(listOf("b"), cli.profiles().map { it.name })
    }
}
