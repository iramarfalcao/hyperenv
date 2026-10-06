package com.falcaosl.hyperenv.cli

/**
 * Whether a profile was edited after it was applied. New terminals keep
 * getting what Apply wrote until Apply runs again, so the panel says so —
 * the same comparison the desktop apps make: the profile's enabled variables
 * against `status.applied.exports`.
 */
object AppliedCheck {
    fun changedSinceApplied(variables: List<Variable>, applied: Applied): Boolean {
        val now = variables.filter { it.isEnabled }.associate { it.key to it.value }
        return now != applied.exports
    }
}
