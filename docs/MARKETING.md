# Marketing — HyperEnv

Material de apoio para campanha: posicionamento, mensagens prontas e onde usar.
Nada aqui promete o que o app não faz — a lista do que ele faz está em
[`PRODUTO.md`](PRODUTO.md) e o que existe hoje, em [`STATUS.md`](STATUS.md).

## Posicionamento em uma frase

> O gerenciador de variáveis de ambiente do macOS em que produção é vermelha e o desfazer funciona.

## Público e o gancho de cada um

- **Dev que alterna projetos**: acabou o `~/.zshrc` cheio de export comentado.
- **Quem já rodou comando no ambiente errado**: produção pede confirmação, e dá para voltar atrás.
- **Time pequeno**: um perfil por ambiente, igual para todo mundo.

## Mensagens prontas

- "Todo terminal novo já nasce com as variáveis do projeto certo."
- "Produção é vermelha em todo lugar — e é a única que pergunta antes."
- "Reverter restaura o valor anterior de cada variável. Não é só apagar."
- "Grátis, MIT, e o código está lá para você ler antes de rodar."

## Canais

- **GitHub**: README, releases e Homebrew Cask — é onde o público está.
- **Hacker News / Lobsters**: um post de lançamento honesto, sem superlativo.
- **Reddit** r/macapps e r/commandline.
- **Site próprio** com instalador de um comando.

## Ativos necessários

- Capturas clara e escura da janela principal (já existem em `site/assets/`).
- GIF curto de trocar de perfil e ver um terminal novo herdar a mudança.
- Texto de release por versão (o `docs/RELEASING.md` já define o formato).

## O que não dizer

- Não chamar de cofre de segredos: ele não criptografa nem sincroniza.
- Não prometer efeito em processo já aberto.
