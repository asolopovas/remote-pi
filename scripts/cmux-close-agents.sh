#!/usr/bin/env bash
set -euo pipefail

# Fecha os 4 panes (App, Relay, Extension, Site) criados por
# scripts/cmux-bootstrap-agents.sh. Localiza surfaces pelo título no
# workspace atual e chama `cmux close-surface` em cada um.
#
# Uso:
#   scripts/cmux-close-agents.sh         # fecha App, Relay, Extension, Site
#   scripts/cmux-close-agents.sh --help  # esta mensagem
#
# Pré-requisitos:
#   - cmux no PATH
#   - rodar de dentro de um terminal cmux do workspace alvo
#     (CMUX_WORKSPACE_ID; cai pra `cmux identify` se não estiver setado)
#
# Idempotente: títulos ausentes geram aviso, não erro. Surfaces com nomes
# diferentes (ex: "✳ Review...") não são tocadas.

usage() {
  awk '
    /^# Fecha/ { on = 1 }
    on {
      if (!/^#/) exit
      sub(/^# /, "")
      sub(/^#$/, "")
      print
    }
  ' "$0"
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    *)         echo "argumento desconhecido: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

command -v cmux >/dev/null || { echo "erro: cmux não encontrado no PATH" >&2; exit 1; }

# `cmux tree` sempre usa short refs (workspace:N). $CMUX_WORKSPACE_ID pode ser
# UUID. Sempre derive o short ref via `cmux identify` pra casar com o tree.
WS_REF=$(cmux identify 2>/dev/null \
  | awk -F'"' '/"workspace_ref"/ {print $4; exit}')
[ -n "$WS_REF" ] || { echo "erro: workspace cmux não identificado" >&2; exit 1; }

targets=(App Relay Extension Site)

# emite "Título<TAB>surface:NN" pra cada surface do workspace alvo
surfaces_in_workspace() {
  cmux tree 2>/dev/null | awk -v target="$WS_REF" '
    /workspace workspace:/ {
      in_ws = 0
      for (i = 1; i <= NF; i++) if ($i == target) in_ws = 1
      next
    }
    in_ws && /surface surface:/ {
      sid = ""
      for (i = 1; i <= NF; i++) if ($i ~ /^surface:/) sid = $i
      if (sid != "" && match($0, /"[^"]+"/)) {
        title = substr($0, RSTART + 1, RLENGTH - 2)
        print title "\t" sid
      }
    }
  '
}

mapping=$(surfaces_in_workspace)

closed=0
missing=0
failed=0
for name in "${targets[@]}"; do
  sid=$(awk -F'\t' -v n="$name" '$1 == n {print $2; exit}' <<<"$mapping")
  if [ -z "$sid" ]; then
    echo "  -   $name: não encontrado, pulando"
    missing=$((missing + 1))
    continue
  fi
  if cmux close-surface --surface "$sid" >/dev/null 2>&1; then
    printf "  ok  %-10s %s fechado\n" "$name" "$sid"
    closed=$((closed + 1))
  else
    echo "  !!  $name ($sid): falhou ao fechar" >&2
    failed=$((failed + 1))
  fi
done

echo "pronto. fechados=$closed, ausentes=$missing, falhas=$failed."
[ "$failed" -eq 0 ] || exit 4
