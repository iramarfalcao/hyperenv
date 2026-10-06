package com.falcaosl.hyperenv.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The dialog's name rule has to agree with the command's. */
class VariableKeyTest {
    @Test fun `plain names pass`() { assertTrue(VariableDialog.isValidKey("API_URL")); assertTrue(VariableDialog.isValidKey("_x1")) }
    @Test fun `lowercase passes`() = assertTrue(VariableDialog.isValidKey("lower_x"))
    @Test fun `leading digit fails`() = assertFalse(VariableDialog.isValidKey("1BAD"))
    @Test fun `dash fails`() = assertFalse(VariableDialog.isValidKey("MY-VAR"))
    @Test fun `space fails`() = assertFalse(VariableDialog.isValidKey("MY VAR"))
    @Test fun `empty fails`() = assertFalse(VariableDialog.isValidKey(""))

    @Test fun `NAME=value splits at the first equals`() = assertEquals("URL" to "a=b", VariableDialog.split("URL=a=b"))
    @Test fun `a bare name has no value`() = assertEquals("URL" to null, VariableDialog.split(" URL "))
}
