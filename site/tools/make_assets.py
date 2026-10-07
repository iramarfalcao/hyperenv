#!/usr/bin/env python3
"""Gera os recursos do site em site/assets/<VERSAO>/ a partir das fontes do app
e das capturas.

Entradas:
  - apps/macos/hyperenv/Fonts/*.ttf          (Schibsted Grotesk, JetBrains Mono; OFL)
  - CAPTURES/window-light.png [window-dark.png] — janela do app, capturada com
    dados de demonstração (HYPERENV_HOME apontando para uma pasta descartável)
  - docs/store/*.png                          — capturas dos plugins

A pasta leva a data porque o _headers serve assets/ como imutável: nome novo é
o único jeito de o visitante receber o arquivo novo.

Requer Pillow, fontTools e brotli.
  CAPTURES=/tmp/he-shots python3 site/tools/make_assets.py
"""
import os
import sys

from fontTools import subset
from PIL import Image

VERSION = "v20261007"
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "site", "assets", VERSION)
CAPTURES = os.environ.get("CAPTURES")


def webp(src, dst, width, crop=None, quality=86):
    im = Image.open(src).convert("RGBA")
    if crop:
        w, h = im.size
        im = im.crop(tuple(int(v * (w if i % 2 == 0 else h)) for i, v in enumerate(crop)))
    if im.width > width:
        im = im.resize((width, round(im.height * width / im.width)), Image.LANCZOS)
    im.save(os.path.join(OUT, dst), "WEBP", quality=quality, method=6)
    print(f"{dst}: {im.width}×{im.height}, {os.path.getsize(os.path.join(OUT, dst)) // 1024} KB")
    return im.size


def font(src, dst):
    opts = subset.Options()
    opts.flavor = "woff2"
    opts.layout_features = ["*"]
    opts.name_IDs = ["*"]
    f = subset.load_font(src, opts)
    sub = subset.Subsetter(opts)
    # Latim básico + Latin-1 + pontuação tipográfica e setas usadas na página.
    sub.populate(unicodes=list(range(0x20, 0x7F)) + list(range(0xA0, 0x100)) +
                 list(range(0x2010, 0x2028)) + [0x2190, 0x2192, 0x2197, 0x2318, 0x25CB, 0x25CF, 0x2713])
    sub.subset(f)
    subset.save_font(f, os.path.join(OUT, dst), opts)
    print(f"{dst}: {os.path.getsize(os.path.join(OUT, dst)) // 1024} KB")


def main():
    if not CAPTURES:
        sys.exit("defina CAPTURES com a pasta das capturas da janela")
    os.makedirs(OUT, exist_ok=True)
    fonts = os.path.join(ROOT, "apps", "macos", "hyperenv", "Fonts")
    font(os.path.join(fonts, "SchibstedGrotesk.ttf"), "schibsted-grotesk.woff2")
    font(os.path.join(fonts, "JetBrainsMono.ttf"), "jetbrains-mono.woff2")

    # Janela do app: a captura do macOS inclui a sombra; fica como está.
    for mode in ("light", "dark"):
        src = os.path.join(CAPTURES, f"window-{mode}.png")
        if os.path.exists(src):
            webp(src, f"app-macos-{mode}.webp", 2000)

    # Plugins: só o painel do HyperEnv, sem o editor vazio ao lado.
    store = os.path.join(ROOT, "docs", "store")
    webp(os.path.join(store, "vscode-1-profiles.png"), "plugin-vscode.webp", 1000,
         crop=(0.0, 0.0, 0.62, 0.66))
    webp(os.path.join(store, "intellij-2-applied.png"), "plugin-intellij.webp", 1300,
         crop=(0.34, 0.0, 1.0, 0.66))


if __name__ == "__main__":
    main()
