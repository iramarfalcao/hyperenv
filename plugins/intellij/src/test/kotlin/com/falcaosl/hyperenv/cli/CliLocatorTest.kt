package com.falcaosl.hyperenv.cli

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

/** Settings first, then PATH, then the copy inside the app bundle. */
class CliLocatorTest {
    private val bundled = File("/Applications/HyperEnv.app/Contents/Helpers/hyperenv")
    private val onPath = File("/opt/homebrew/bin/hyperenv")
    private val custom = File("/tmp/my/hyperenv")

    private fun existing(vararg files: File): (File) -> Boolean = { it in files }

    @Test
    fun `an explicit setting wins when it exists`() {
        val found = CliLocator.resolve(custom.path, { onPath }, listOf(bundled), existing(custom, onPath, bundled))
        assertEquals(custom, found)
    }

    @Test
    fun `a setting that points nowhere is ignored, not fatal`() {
        val found = CliLocator.resolve(custom.path, { onPath }, listOf(bundled), existing(onPath, bundled))
        assertEquals(onPath, found)
    }

    @Test
    fun `PATH beats the bundled copy`() {
        assertEquals(onPath, CliLocator.resolve("", { onPath }, listOf(bundled), existing(onPath, bundled)))
    }

    @Test
    fun `the bundled copy is the fallback`() {
        assertEquals(bundled, CliLocator.resolve(null, { null }, listOf(bundled), existing(bundled)))
    }

    @Test
    fun `nothing found is null so the caller can explain`() {
        assertNull(CliLocator.resolve(null, { null }, listOf(bundled), existing()))
    }

    @Test
    fun `blank setting is the same as none`() {
        assertEquals(bundled, CliLocator.resolve("   ", { null }, listOf(bundled), existing(bundled)))
    }
}
