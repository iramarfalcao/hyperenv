# Design — HyperEnv 2

Fonte única do visual, igual no macOS (SwiftUI), no Windows e no Linux (Slint).
As cores vêm do ícone do app: índigo-violeta para agir; verde, laranja e vermelho
dos três pontos para ativo, pendente e erro.

- `tokens.json` — cores (claro/escuro), tipografia, escala, espaço, raios, layout e movimento.
- Ícone do app: o já existente (`apps/macos/hyperenv/Assets.xcassets/AppIcon.appiconset`,
  `apps/macos/assets/HyperEnv.icns`, `apps/macos/assets/icon-1024.png`), igual nas três plataformas.
- `icons/` — 16 ícones de interface próprios: grade 24, traço 1,75, pontas retas, cantos vivos.
  Nada de SF Symbols nem ícones do sistema.

Os apps não leem estes arquivos em tempo de execução: um gerador (fase 4/5)
transforma `tokens.json` em código Swift e Slint, e os SVG entram como recurso.
Mudou aqui, regenere lá.

Fontes: Schibsted Grotesk (interface) e JetBrains Mono (nomes e valores), ambas OFL,
embutidas nos apps.
