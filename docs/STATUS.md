# Status — HyperEnv

> Atualizado em **2026-10-07**. Este arquivo é a fonte única de "em que pé está".
> Ao mudar o estágio, mude também a linha correspondente no índice do portfólio
> (`~/Github/CLAUDE.md`) e o selo do site em `site/index.html`.

| Campo | Valor |
|---|---|
| **Estágio** | **Em desenvolvimento** — versões de teste nas lojas de plugins (pré-lançamento); nenhuma release publicada no GitHub ainda; distribuição em andamento |
| **Formato** | Monorepo: app macOS (`apps/macos`), app desktop Windows/Linux (`apps/desktop`), núcleo e comando `hyperenv` em Rust (`crates/`), `plugins/` (IntelliJ e VS Code), `site/` e `docs/` |
| **Plataformas** | macOS 26.5+ (app nativo); Windows e Linux (app desktop 2.0.0); comando `hyperenv` nos três |
| **Stack** | Swift/SwiftUI sobre o núcleo Rust (macOS); Rust + Slint (desktop); Rust (núcleo e comando); Kotlin e TypeScript (plugins) |
| **Site** | https://hyperenv.falcaosl.com |
| **Monetização** | Gratuito e open source (MIT) |
| **Próximo marco** | Plugins estáveis (2.2.0) e primeira leva de usuários externos |
| **Data-alvo** | Contínuo |

## O que já está pronto

- **Publicador em todas as lojas: Iramar Falcao** (pessoa física; decidido em
  2026-10-06). O app macOS é assinado com Developer ID e notarizado nesse nome.
- **Onde está publicado:** Visual Studio Marketplace, Open VSX e JetBrains
  Marketplace — plugins 2.1.x no canal de pré-lançamento (alpha na JetBrains);
  no Visual Studio Marketplace a página ainda dava 404 em 2026-10-06 (issue #20).
  **GitHub Releases: nenhuma publicada** (0 releases em 2026-10-07; as tags
  `v2.0.0` e `cli-v*` existem). Por isso o cask em `Casks/` (aponta para a
  2.0.0), o `install.sh` do site e o link do DMG dão 404.

- App funcional (2.x): lista plana de perfis (sem projetos nem classe de risco), aplicar e desfazer em um clique, drift, `.env`, segredos mascarados e migração dos perfis do 1.x.
- **Comando `hyperenv`** dentro do app (`Contents/Helpers`): mesmo núcleo Rust
  (`crates/core`, `crates/engine`), mesmo `profiles.json` e journal. É a porta
  única dos plugins — um motor, um escritor no arquivo de startup do shell (ou
  no registro, no Windows). Testado por `cargo test -p hyperenv-cli` contra um
  home descartável.
- **Plugin IntelliJ** (Kotlin, Gradle 9.7.1, plataforma 2025.2, `verifyPlugin`
  compatível) e **extensão VS Code** (TypeScript, `.vsix` empacotado): os
  mesmos fluxos do app sobre a lista plana de perfis — criar, renomear,
  duplicar e apagar perfil, criar e editar variáveis, aplicar, desfazer,
  status com drift, `.env` e comando de reload.
- Site próprio no ar, com instalador de um comando (hoje sem release para baixar; botões de download desligados).
- CI no GitHub Actions, workflow de release com assinatura e notarização, e `Casks/` para Homebrew.
- `docs/ARCHITECTURE.md` e `docs/RELEASING.md` escritos.
- Suítes de verificação na CI (`cargo test --workspace` em macOS, Linux e
  Windows): núcleo (shells reais zsh, bash, fish e PowerShell), motor contra
  um home descartável, ponta a ponta num shell de login real, comando e ffi.

## O que falta

As pendências de distribuição estão como issues no GitHub (rótulo
`distribuicao`): assinatura no Windows, Microsoft Store, verificação no Open
VSX, prints do app desktop, plugins estáveis e lojas Linux.

- Divulgação: o app está pronto e quase ninguém sabe que existe (ver `docs/MARKETING.md`).
- Smoke test dos plugins dentro dos editores (`./gradlew runIde`, F5 no VS
  Code): a lógica está provada por 19 + 11 testes de unidade e pelo cliente
  rodando contra o binário real, mas a árvore e os diálogos ainda não foram
  clicados por uma pessoa.
- O app não percebe na hora uma mudança feita por plugin: os processos leem e
  gravam o mesmo `profiles.json`, e o app não observa o arquivo — só relê ao
  trocar de perfil ou editar.
- Coletar feedback dos primeiros usuários antes de acrescentar recurso novo.

## Riscos e bloqueios

- Mudança de política do macOS sobre arquivos lidos no login do shell.

## Definição de "pronto para publicar"

Ainda não há release publicada no GitHub (só versões de teste dos plugins nas lojas); o lançamento estável depende das issues de distribuição (#16 a #23). O gate de release é o `docs/RELEASING.md`.
