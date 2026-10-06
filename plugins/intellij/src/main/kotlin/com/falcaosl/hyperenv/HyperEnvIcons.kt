package com.falcaosl.hyperenv

import com.intellij.openapi.util.IconLoader
import javax.swing.Icon

/**
 * HyperEnv's own interface icons (design/icons), at 16×16. Each has a
 * `_dark` twin with a light stroke; IconLoader picks it under a dark theme,
 * the IDE's usual convention.
 */
object HyperEnvIcons {
    private fun load(name: String): Icon = IconLoader.getIcon("/icons/$name.svg", HyperEnvIcons::class.java)

    @JvmField val ToolWindow = load("profile")
    @JvmField val Profile = load("profile")
    @JvmField val Add = load("add")
    @JvmField val Apply = load("apply")
    @JvmField val Undo = load("undo")
    @JvmField val Delete = load("delete")
    @JvmField val Copy = load("copy")
    @JvmField val Reveal = load("reveal")
    @JvmField val Conceal = load("conceal")
    @JvmField val Secret = load("secret")
    @JvmField val Import = load("import")
    @JvmField val Export = load("export")
    @JvmField val Drift = load("drift")
    @JvmField val Terminal = load("terminal")
    @JvmField val Confirm = load("confirm")
}
