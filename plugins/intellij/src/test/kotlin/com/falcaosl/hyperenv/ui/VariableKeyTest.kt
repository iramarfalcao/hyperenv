package com.falcaosl.hyperenv.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The dialog's name rule has to agree with the app's EnvKey. */
class VariableKeyTest {
    @Test fun `plain names pass`() { assertTrue(VariableDialog.isValidKey("API_URL")); assertTrue(VariableDialog.isValidKey("_x1")) }
    @Test fun `leading digit fails`() = assertFalse(VariableDialog.isValidKey("1BAD"))
    @Test fun `dash fails`() = assertFalse(VariableDialog.isValidKey("MY-VAR"))
    @Test fun `space fails`() = assertFalse(VariableDialog.isValidKey("MY VAR"))
    @Test fun `empty fails`() = assertFalse(VariableDialog.isValidKey(""))
}
