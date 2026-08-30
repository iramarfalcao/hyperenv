# Produto — HyperEnv

**Troca as variáveis de ambiente que seus terminais herdam — por projeto, por ambiente, com um clique para desfazer.**

| | |
|---|---|
| **Plataformas** | macOS 26.5+ |
| **Idioma da interface** | Inglês |
| **Site** | https://hyperenv.falcaosl.com |
| **Estado** | ver [`STATUS.md`](STATUS.md) |

## O problema

Quem trabalha em mais de um projeto acumula um `~/.zshrc` cheio de export comentado, e descobre que estava com a
variável de produção carregada só depois de rodar o comando. Alternar ambiente vira edição manual de arquivo, e
voltar atrás depende de lembrar o que havia antes.

## Para quem é

- **Desenvolvedores em macOS** que alternam entre projetos e ambientes no mesmo dia.
- **Times pequenos** que compartilham a configuração de um projeto sem um cofre corporativo.

## O que ele faz

- Um perfil por ambiente (dev, homologação, produção) dentro de cada projeto.
- Aplicar um perfil escreve um único arquivo gerado, lido no login do shell: todo terminal novo nasce configurado.
- Cada perfil carrega uma classe de risco; produção é vermelha em toda a interface e é a única que pede confirmação.
- Reverter restaura o valor anterior de cada variável — não apenas apaga — e avisa quando o shell sai de sincronia.

## Por que este e não outro

`direnv` e afins resolvem por diretório e exigem arquivo versionado; os gerenciadores de segredo comerciais
resolvem para a empresa e cobram por assento. O HyperEnv resolve para a máquina de uma pessoa, com interface,
undo real e sem servidor no meio.

## O que ele deliberadamente não faz

- Não é cofre de segredos: não criptografa nem sincroniza credenciais entre máquinas.
- Não injeta variável em processo já em execução — o efeito vale para terminais novos.
- Não gerencia ambiente de CI.

## Princípios de produto

1. **Produção pergunta antes.** Sempre.
2. **Desfazer é recurso de primeira classe**, não um botão escondido.
3. **Gratuito e auditável.** Software que mexe no ambiente do shell precisa ser lido — por isso MIT.
