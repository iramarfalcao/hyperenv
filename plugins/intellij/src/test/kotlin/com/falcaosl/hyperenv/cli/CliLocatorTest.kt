package com.falcaosl.hyperenv.cli

import com.falcaosl.hyperenv.cli.CliLocator.Os
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Settings, then the app bundle (macOS), then PATH, then the installers' locations. */
class CliLocatorTest {
    private val home = File("/Users/me")
    private val custom = File("/tmp/my/hyperenv")
    private val app = File("/Applications/HyperEnv.app/Contents/Helpers/hyperenv")
    private val userApp = File("/Users/me/Applications/HyperEnv.app/Contents/Helpers/hyperenv")
    private val onPath = File("/opt/homebrew/bin/hyperenv")
    private val local = File("/Users/me/.local/bin/hyperenv")
    private val pluginDir = File("/Users/me/Library/plugins/hyperenv-intellij")
    private val bundled = File("/Users/me/Library/plugins/hyperenv-intellij/bin/macos/hyperenv")

    private fun existing(vararg files: File): (File) -> Boolean = { it in files }

    private fun mac(override: String?, vararg present: File) = CliLocator.resolve(
        override,
        CliLocator.appCandidates(Os.MAC, home),
        CliLocator.pathCandidates("/usr/bin:/opt/homebrew/bin", Os.MAC, ":"),
        CliLocator.installerCandidates(Os.MAC, home, null),
        CliLocator.bundledCandidate(pluginDir, Os.MAC),
        existing(*present),
    )

    @Test fun `an explicit setting wins when it exists`() = assertEquals(custom, mac(custom.path, custom, app, onPath, local))
    @Test fun `a setting that points nowhere is ignored, not fatal`() = assertEquals(app, mac(custom.path, app, onPath))
    @Test fun `blank setting is the same as none`() = assertEquals(app, mac("   ", app))
    @Test fun `the app bundle beats PATH on macOS`() = assertEquals(app, mac(null, app, onPath, local))
    @Test fun `then the user's Applications folder`() = assertEquals(userApp, mac(null, userApp, onPath))
    @Test fun `then PATH, in PATH order`() = assertEquals(onPath, mac(null, onPath, local))
    @Test fun `then the installer's location`() = assertEquals(local, mac(null, local))
    @Test fun `the bundled copy is the last resort`() = assertEquals(bundled, mac(null, bundled))
    @Test fun `the installer's location beats the bundled copy`() = assertEquals(local, mac(null, local, bundled))
    @Test fun `PATH beats the bundled copy`() = assertEquals(onPath, mac(null, onPath, bundled))
    @Test fun `a setting beats the bundled copy`() = assertEquals(custom, mac(custom.path, custom, bundled))

    @Test
    fun `bundled folder per os and arch`() {
        assertEquals("macos", CliLocator.bundledFolder(Os.MAC, "aarch64"))
        assertEquals("macos", CliLocator.bundledFolder(Os.MAC, "x86_64"))
        assertEquals("linux-x64", CliLocator.bundledFolder(Os.LINUX, "amd64"))
        assertEquals("linux-x64", CliLocator.bundledFolder(Os.LINUX, "x86_64"))
        assertEquals("linux-arm64", CliLocator.bundledFolder(Os.LINUX, "aarch64"))
        assertEquals("windows-x64", CliLocator.bundledFolder(Os.WINDOWS, "amd64"))
        assertEquals("windows-arm64", CliLocator.bundledFolder(Os.WINDOWS, "arm64"))
        assertNull(CliLocator.bundledFolder(Os.LINUX, "riscv64"))
        assertEquals(
            File(File(File(File("C:\\p"), "bin"), "windows-x64"), "hyperenv.exe"),
            CliLocator.bundledCandidate(File("C:\\p"), Os.WINDOWS, "amd64"),
        )
        assertNull(CliLocator.bundledCandidate(null, Os.MAC))
    }

    @Test fun `nothing found is null so the caller can explain`() = assertNull(mac(null))

    @Test
    fun `linux has no app bundle and uses local bin last`() {
        assertTrue(CliLocator.appCandidates(Os.LINUX, home).isEmpty())
        assertEquals(listOf(local), CliLocator.installerCandidates(Os.LINUX, home, null))
    }

    @Test
    fun `windows looks for hyperenv exe on PATH and in LOCALAPPDATA`() {
        val path = CliLocator.pathCandidates("C:\\bin;;C:\\tools", Os.WINDOWS, ";")
        assertEquals(listOf(File("C:\\bin", "hyperenv.exe"), File("C:\\tools", "hyperenv.exe")), path)
        val installer = CliLocator.installerCandidates(Os.WINDOWS, home, "C:\\Users\\me\\AppData\\Local")
        assertEquals(
            listOf(File(File(File("C:\\Users\\me\\AppData\\Local", "Programs"), "hyperenv"), "hyperenv.exe")),
            installer,
        )
        assertTrue(CliLocator.installerCandidates(Os.WINDOWS, home, null).isEmpty())
    }

    @Test
    fun `os detection`() {
        assertEquals(Os.MAC, CliLocator.currentOs("Mac OS X"))
        assertEquals(Os.WINDOWS, CliLocator.currentOs("Windows 11"))
        assertEquals(Os.LINUX, CliLocator.currentOs("Linux"))
    }

    @Test
    fun `version 2 or later is required`() {
        assertTrue(CliLocator.isSupportedVersion("2.0.0-alpha.3"))
        assertTrue(CliLocator.isSupportedVersion("2.0.0"))
        assertTrue(CliLocator.isSupportedVersion("10.1"))
        assertFalse(CliLocator.isSupportedVersion("1.4.2"))
        assertFalse(CliLocator.isSupportedVersion("dev"))
        assertFalse(CliLocator.isSupportedVersion(""))
    }
}
