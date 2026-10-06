package com.falcaosl.hyperenv.cli

/** Output captured from the real `hyperenv --json` (2.0.0-alpha.3) run against a throwaway --home. */
object Fixtures {
    fun read(name: String): String =
        Fixtures::class.java.getResource("/fixtures/$name")?.readText()?.trim()
            ?: error("missing fixture $name")
}
