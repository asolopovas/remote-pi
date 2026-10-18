# Remote Pi — Orquestrador

[Project index](README.md#project-map)

## Escopo e execução
- A raiz coordena o monorepo, mas não bloqueia implementação/deploy autorizados. Execute diretamente ou use workers nativos com escopo explícito; não exija Claude, Cockpit ou cmux.
- Consulte o [mapa dos projetos](README.md#project-map) para todos os subprojetos, localizações, dependências e guias; não mantenha um segundo inventário aqui.
- Antes de editar um subprojeto, leia suas instruções e defina arquivos, cwd, validação e responsabilidade. Rode builds/testes no cwd dele, não implicitamente na raiz.
- Um único writer por checkout. Use worktrees para writers concorrentes; o coordenador não edita enquanto um worker possui o checkout. Preserve trabalho alheio, credenciais e serviços fora do escopo.
- Pedido de implementação/deploy, inclusive seguido de “continue” ou “sem mais perguntas”, mantém a autorização do mesmo escopo. Não repita aprovação; escolha defaults conservadores e continue as partes independentes.
- Após falha de worker, preserve estado, reporte a causa específica e siga o contrato de recuperação; não troque silenciosamente de CLI. Não enfraqueça TLS nem invente credenciais ou resultados para contornar bloqueios.

## Planos e isolamento
- Trabalho simples não precisa de plano. Se necessário, crie uma vez em `.pi/tmp/plans/<session-id>/<task>.md`, confirme que está gitignored e atualize o mesmo arquivo com escopo, passos e verificação.
- Remova o plano após conclusão verificada ou cancelamento explícito; retenha estado inacabado apenas para retomada. Não crie planos permanentes em `plan/`, `plans/` ou arquivos de concluídos sem pedido explícito.
- Não carregue planos históricos por padrão nem apague registros compartilhados indiscriminadamente. Use os READMEs e `PROTOCOL.md` como referências atuais; não reabra decisões fechadas sem evidência forte e discussão explícita.
- Workers recebem cwd explícito, `context: "fresh"` e handoff mínimo. Não importe históricos, planos ou resultados de agentes independentes. Para scout/revisão, descubra os agentes realmente disponíveis; não assuma nomes ou ferramentas instalados.

## Documentação
- Não adicione GitHub workflows; todos os testes, builds, auditorias e publicações são locais/manuais.
- Cada assunto durável tem um documento dono; outros guias usam links Markdown relativos em vez de copiar especificações/receitas.
- Todo projeto aponta ao [índice](README.md#project-map); cada guia especializado aponta ao projeto e aos contratos com que integra. Nenhum guia fica órfão.
- Skills embarcadas mantêm instruções operacionais suficientes para uso instalado; detalhes de formato têm uma referência canônica, sem copiar seções inteiras.
- Valide links, âncoras, navegação e duplicações com `python3 scripts/check-docs.py`; não use planos históricos como documentação atual.
- Siga [SECURITY.md](SECURITY.md) para credenciais, dependências e publicação; não publique com bloqueios de segurança pendentes.

## Transportes opcionais
- Prefira execução direta/workers nativos. Use Cockpit ou cmux somente quando disponíveis e escolhidos para a tarefa; leia a skill correspondente antes de operá-los. Ausência de panes não é bloqueio.
- Não crie, feche, limpe, interrompa ou retome panes/sessões visíveis sem autorização específica. Não reutilize sessões/worktrees alheias por estarem online ou terem título parecido.
- Cockpit: descubra panes com `cockpit list-panes --json`; resolva por label manual único (exato, case-insensitive) ou tab-id descoberto agora, nunca por título dinâmico/cwd/workspaceId. Dispatch: `scripts/cockpit-dispatch.sh <label-ou-tab-id> <task-id> "<handoff>"`.
- cmux: descubra surfaces por título com `cmux tree`, nunca hardcode IDs. Dispatch orquestrado exige `scripts/cmux-dispatch.sh <título> <task-id> "<handoff>"`; ele injeta `[ORCH:<id>]`. Leia as [instruções de orquestração](.orchestration/INSTRUCTIONS.md) ao usar esse protocolo. Conversa solo usa send + Enter separado.
- `--wait` nos dispatchers deve rodar em background com suporte do runtime, não prender a conversa. Resultados ficam em `.orchestration/results/<task-id>.md`; valide conteúdo novo, não apenas existência de arquivo antigo.
- Scripts `cmux-bootstrap-agents.sh`, `cmux-close-agents.sh` e `cmux-clear-agents.sh` só rodam com autorização explícita. Bootstrap cobre App/Relay/Extension/Site, não Cockpit; clear exige agentes ociosos.
- Indicadores de progresso são opcionais: use somente a tarefa ativa e verificações reais; não varra planos históricos. Atualize apenas quando o estado mudar e limpe ao concluir.
