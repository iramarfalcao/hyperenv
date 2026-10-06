# `hyperenv` 2 — o comando

O mesmo motor do app (`hyperenv-engine`), pelo terminal, no macOS, no Linux e
no Windows. É a porta única dos plugins: um motor, um journal e um escritor do
arquivo de inicialização, não importa de onde veio o clique.

```sh
cargo build --release -p hyperenv-cli   # -> target/release/hyperenv
```

## Comandos

```
hyperenv [--json] <comando>

status                          o que está aplicado, hook, divergência
profiles                        lista os perfis
profile create|delete <nome>
profile rename|duplicate <nome> <novo>
vars <perfil> [--show]          segredos mascarados sem --show
var set <perfil> CHAVE=VALOR [--secret | --no-secret]
var enable|disable|delete <perfil> CHAVE
import <perfil> <arquivo.env>
export <perfil> [--dialect posix|dotenv|docker]
plan <perfil>                   o que aplicar mudaria, sem mudar nada
apply <perfil>
unapply
drift
hook install|remove
migrate                         perfis do HyperEnv 1.x (macOS)
version
```

Perfis são uma lista plana: não há mais `--project`/`--profile`. O primeiro
`=` de `CHAVE=VALOR` separa, então o valor pode ter `=`.

## JSON

Com `--json` toda resposta é um envelope, e o código de saída é 0 ou 1
(sem `--json`, erro de uso sai com 2):

```json
{ "ok": true,  "data": { … } }
{ "ok": false, "error": "Não existe perfil \"nope\"." }
```

Campo ausente é **ausente**, não `null` — `status` não tem `applied` quando
nada está aplicado. No JSON os valores vão sempre inteiros (o plugin decide
como mostrar segredos).

```
Profile  { id, name, variableCount, enabledCount, isApplied, updatedAt }
Variable { key, value, isSecret, isEnabled }
Status   { version, shell, hook: installed|notInstalled|notNeeded|malformed, hookDetail?,
           applied?: { profileId, profileName, appliedAt, exportedKeys },
           drift: [{ kind, key?, expected?, actual? }], pendingRecoveries,
           reloadCommand, undoCommand, sessionScript, startupFile?, store }
Plan     { exported, captured, restored: [{ key, to }] }   — `to: null` = volta a não existir
Apply    Plan + { applied, reloadCommand, undoCommand }
```

## Desempenho

Binário de 2,3 MB; um comando de leitura leva ~2,4 ms; aplicar 200 variáveis,
com a sondagem do zsh real, ~40 ms (Apple Silicon, release).

## Testes

`cargo test -p hyperenv-cli` roda a gramática inteira contra uma home
descartável (`--home`), inclusive aplicar e desfazer num zsh de verdade.
