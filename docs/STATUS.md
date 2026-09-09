# Status — HyperEnv

> Atualizado em **2026-08-30**. Este arquivo é a fonte única de "em que pé está".
> Ao mudar o estágio, mude também a linha correspondente no índice do portfólio
> (`~/Github/CLAUDE.md`) e o selo do site em `site/index.html`.

| Campo | Valor |
|---|---|
| **Estágio** | **Publicado** — release pública no GitHub, MIT |
| **Formato** | Monorepo: app macOS, `plugins/` (família IntelliJ), `site/` e `docs/` |
| **Plataformas** | macOS 26.5+ |
| **Stack** | Swift/SwiftUI, Xcode |
| **Site** | https://hyperenv.falcaosl.com |
| **Monetização** | Gratuito e open source (MIT) |
| **Próximo marco** | Distribuição por Homebrew Cask estável e primeira leva de usuários externos |
| **Data-alvo** | Contínuo |

## O que já está pronto

- App funcional: perfis por projeto e por ambiente, classe de risco por perfil, reversão em um clique.
- Site próprio no ar, com instalador de um comando.
- CI no GitHub Actions, releases assinadas e `Casks/` para Homebrew.
- `docs/ARCHITECTURE.md` e `docs/RELEASING.md` escritos.

## O que falta

- Divulgação: o app está pronto e quase ninguém sabe que existe (ver `docs/MARKETING.md`).
- Ampliar a cobertura de shells além de zsh/bash.
- **Plugin da família IntelliJ** (`plugins/intellij/`, unificado aqui em
  2026-09-09): hoje é o template da JetBrains com o pacote renomeado, sem
  nenhuma funcionalidade do HyperEnv. O primeiro passo é decidir como o plugin
  lê os perfis — pelos mesmos arquivos em disco, ou por uma interface do app.
- Coletar feedback dos primeiros usuários antes de acrescentar recurso novo.

## Riscos e bloqueios

- Mudança de política do macOS sobre arquivos lidos no login do shell.

## Definição de "pronto para publicar"

Já publicado. O gate de release é o `docs/RELEASING.md`.
