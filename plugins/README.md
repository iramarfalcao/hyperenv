# plugins/

Integrações do HyperEnv com editores e IDEs. Cada subpasta é um plugin
independente, com o próprio build e o próprio ciclo de versão — o que
compartilham é o repositório, a licença e a documentação em `docs/`.

| Pasta | Alvo | Estado |
|---|---|---|
| `intellij/` | Família IntelliJ — IDEA, PyCharm, WebStorm, GoLand, RustRover, CLion | **Esqueleto** — template da JetBrains, sem funcionalidade do HyperEnv ainda |

## intellij/

Gradle, Kotlin, IntelliJ Platform Gradle Plugin. Para trabalhar nele:

```bash
cd plugins/intellij
./gradlew build          # compila e testa
./gradlew runIde         # sobe uma IDE com o plugin carregado
./gradlew verifyPlugin   # checa compatibilidade com as builds declaradas
```

As faixas de build suportadas e a versão da plataforma estão em
`intellij/gradle.properties`.

### Estado real, sem enfeite

O que existe hoje é o **template da JetBrains com o pacote renomeado**:
`MyToolWindowFactory`, `MyProjectService` e um botão que sorteia um número.
Nenhuma linha lê perfil, projeto ou variável do HyperEnv. Está no repositório
porque monorepo é o lugar certo para ele nascer, não porque esteja pronto.

O primeiro trabalho de verdade é decidir **como o plugin conversa com o app**:
lendo os mesmos arquivos de perfil no disco, ou por uma interface que o app
exponha. Essa decisão vem antes de qualquer tela.

## CI

`.github/workflows/plugin-build.yml`, na raiz do repositório, compila e
verifica o plugin quando algo em `plugins/**` muda. Os workflows que vieram do
template continuam em `intellij/.github/workflows/` como referência e estão
inertes — o GitHub só executa o que está na raiz.

O `release.yml` do template **não** foi promovido de propósito: ele dispara em
qualquer release do repositório, e neste monorepo quem lança release é o
aplicativo macOS. Publicar na JetBrains Marketplace a cada versão do app não é
o que se quer. Quando houver o que publicar, ele volta com gatilho próprio.
