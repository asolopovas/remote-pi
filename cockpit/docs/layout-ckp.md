# `*.ckp` — Layouts de orquestração de panes

[Project index](../../README.md#project-map) · [Cockpit guide](../README.md)

Um arquivo `.ckp` é um YAML **versionável** que descreve os terminais a abrir
num workspace do Cockpit — o equivalente a um layout de tmuxinator. Um arquivo
= um layout; o nome do layout é o nome do arquivo (`dev.ckp` → layout "dev").

Três formas de aplicar:

1. **GUI** — botão direito no arquivo `.ckp` na árvore → **Open layout**.
2. **CLI interna** — `cockpit orchestrate dev.ckp` (de dentro de uma tab).
3. **Autorun em worktree** — `autorun: worktree` no arquivo: ao criar uma
   worktree do workspace, o layout é aplicado sozinho (a worktree nasce vazia,
   então a geometria sai exata).

## Exemplo

```yaml
# dev.ckp — na raiz do projeto (qualquer pasta serve; cwd é relativo a ele)
autorun: worktree        # opcional
panes:
  - name: Frontend       # obrigatório, único — vira o rótulo estável da tab
    cwd: frontend        # relativo a este arquivo, SEMPRE com "/"
    command: claude      # opcional: digitado no shell após abrir
  - name: Backend
    cwd: backend
    split: right         # tab (default) | right (lado a lado) | down (empilha)
    command: npm run dev
  - name: Sign
    cwd: .
    command: ./sign.sh
    platforms: [macos]   # opcional: macos | windows | linux (string ou lista)
```

## Campos

### Raiz

| Campo     | Tipo   | Obrigatório | Descrição |
|-----------|--------|-------------|-----------|
| `panes`   | array  | **sim**     | Lista de panes, na ordem de criação. |
| `autorun` | string | não         | Só `worktree`: aplica ao criar worktree do workspace. Com **2+** arquivos autorun na raiz, nenhum roda (ambiguidade nunca é chutada). |

### `panes[]`

| Campo       | Tipo               | Obrigatório | Default | Descrição |
|-------------|--------------------|-------------|---------|-----------|
| `name`      | string             | **sim**     | —       | Único (case-insensitive). Vira o rótulo manual da tab e é a chave do merge em modo append. |
| `cwd`       | string             | não         | `.`     | **Relativo à pasta do arquivo**, só `/`. Absolutos e `\` são rejeitados (portabilidade macOS/Linux/Windows). |
| `split`     | string             | não         | `tab`   | Onde nasce, relativo ao **pane anterior criado**: `tab` (aba na mesma pane), `right`, `down`. |
| `command`   | string             | não         | —       | Comando digitado no terminal (executado pelo shell da tab; resolve pelo PATH da máquina). |
| `platforms` | string \| string[] | não         | todos   | `macos`/`windows`/`linux` — mesma semântica do `platforms` do tasks.json. |

## Semântica de aplicação

- **Replace é o padrão** na CLI e na aplicação pela GUI: substitui o layout do workspace de destino e pode fechar abas/processos existentes. A GUI confirma o impacto; não aplique um layout sobre trabalho ativo sem autorização.
- **Append** (`cockpit orchestrate --append dev.ckp`) preserva as abas existentes e faz merge. Nesse modo, um `name` já presente como rótulo/título é pulado; a idempotência vale para o merge, não para o replace padrão. Opções de comando pertencem à [referência da CLI](../cli/text/skill.md#layout-files-ckp).
- O `split` ancora no pane **anterior criado nesta execução**; se o anterior
  foi pulado pelo merge, o próximo abre como aba normal (geometria perfeita
  só em workspace vazio — o caso do worktree/autorun).
- `cwd` inexistente ou YAML inválido → erro legível (dialog na GUI, stderr na
  CLI); nada é aplicado pela metade a partir do pane com erro.
- O `command` é digitado ~700ms após abrir a tab (folga pro shell terminar o
  boot) com Enter ao final.

## Editor

O Cockpit trata `.ckp` como YAML (highlight) e mostra o logo do Cockpit como
ícone do arquivo na árvore.
