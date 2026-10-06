package com.falcaosl.hyperenv.cli

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** "Changed since applied": the profile's enabled variables against what Apply exported. */
class AppliedCheckTest {
    private val applied = Envelope.status(Envelope.parse(Fixtures.read("status-applied.json"))).applied!!
    private val vars = Envelope.variables(Envelope.parse(Fixtures.read("vars.json")))

    @Test
    fun `just applied is unchanged, disabled variables do not count`() =
        assertFalse(AppliedCheck.changedSinceApplied(vars, applied))

    @Test
    fun `an edited value is a change`() =
        assertTrue(AppliedCheck.changedSinceApplied(vars.map { if (it.key == "TOKEN") it.copy(value = "new") else it }, applied))

    @Test
    fun `enabling a variable is a change`() =
        assertTrue(AppliedCheck.changedSinceApplied(vars.map { it.copy(isEnabled = true) }, applied))

    @Test
    fun `removing a variable is a change`() =
        assertTrue(AppliedCheck.changedSinceApplied(vars.filter { it.key != "API_URL" }, applied))
}
