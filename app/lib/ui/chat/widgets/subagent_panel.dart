import 'dart:convert';

import 'compact_output_header.dart';
import 'accordion_viewport.dart';
import 'accordion_expansion.dart';

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class SubagentInvocation {
  const SubagentInvocation({
    required this.tool,
    required this.name,
    required this.task,
    this.isWorkflow = false,
  });

  final ToolEvent tool;
  final String name;
  final String task;
  final bool isWorkflow;

  static SubagentInvocation? fromTool(ToolEvent tool) {
    if (!RegExp(
      r'(^|[.:/]|__)subagent$',
      caseSensitive: false,
    ).hasMatch(tool.tool)) {
      return null;
    }
    final args = tool.args;
    if (args is! Map || args['action'] != null) return null;
    final agent = args['agent'];
    final task = args['task'];
    if (agent is String &&
        agent.trim().isNotEmpty &&
        task is String &&
        task.trim().isNotEmpty) {
      return SubagentInvocation(tool: tool, name: agent, task: task);
    }
    final workflow = args['workflow'];
    final parameters = args['args'];
    final tasks = parameters is Map ? parameters['tasks'] : args['tasks'];
    if (!(workflow == true ||
            (workflow is String && workflow.trim().isNotEmpty)) &&
        tasks is! List) {
      return null;
    }
    final assignments = <String>[];
    if (tasks is List) {
      for (final child in tasks) {
        if (child is! Map ||
            child['agent'] is! String ||
            child['task'] is! String) {
          continue;
        }
        final agent = (child['agent'] as String).trim();
        final task = (child['task'] as String).trim();
        if (agent.isEmpty || task.isEmpty) continue;
        final label = child['label'];
        assignments.add(
          '$agent${label is String && label.trim().isNotEmpty ? ' · ${label.trim()}' : ''}: $task',
        );
      }
      if (assignments.isEmpty) return null;
    }
    return SubagentInvocation(
      tool: tool,
      isWorkflow: true,
      name: tasks is List
          ? '${workflow is String ? workflow : 'Parallel'} · ${assignments.length} tasks'
          : workflow is String
          ? workflow
          : 'Workflow',
      task: assignments.isNotEmpty
          ? assignments.join('\n')
          : task is String && task.isNotEmpty
          ? task
          : parameters != null
          ? const JsonEncoder.withIndent('  ').convert(parameters)
          : 'Subagent workflow',
    );
  }

  String get output {
    final result = tool.result;
    if (result == null) return '';
    return result is String
        ? result
        : const JsonEncoder.withIndent('  ').convert(result);
  }

  bool get detached =>
      RegExp(r'^Async:|\bDetached\.', multiLine: true).hasMatch(output);

  String get status => switch (tool.status) {
    ToolEventStatus.pending || ToolEventStatus.allowed => 'Running call',
    ToolEventStatus.completed => detached ? 'Launched' : 'Call returned',
    ToolEventStatus.failed => 'Failed',
    ToolEventStatus.denied => 'Denied',
    ToolEventStatus.expired => 'Expired',
  };

  Color statusColor(AppColors colors) => switch (tool.status) {
    ToolEventStatus.pending || ToolEventStatus.allowed => colors.working,
    ToolEventStatus.completed => detached ? colors.working : colors.success,
    ToolEventStatus.failed => colors.error,
    ToolEventStatus.denied || ToolEventStatus.expired => colors.muted2,
  };
}

class SubagentPanel extends StatefulWidget {
  const SubagentPanel({
    super.key,
    required this.invocations,
    required this.collapsed,
    required this.onCollapsedChanged,
    this.onClose,
  });

  final List<SubagentInvocation> invocations;
  final bool collapsed;
  final ValueChanged<bool> onCollapsedChanged;
  final VoidCallback? onClose;

  @override
  State<SubagentPanel> createState() => _SubagentPanelState();
}

class _SubagentPanelState extends State<SubagentPanel> {
  final _scroll = ScrollController();
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final invocations = widget.invocations;
    final collapsed = widget.collapsed;
    final onCollapsedChanged = widget.onCollapsedChanged;
    final onClose = widget.onClose;
    final colors = context.colors;
    if (invocations.isEmpty) {
      return const Center(child: Text('No sub-agents in this session'));
    }
    return AccordionViewport(
      controller: _scroll,
      child: Container(
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(bottom: BorderSide(color: colors.border)),
        ),
        child: ListView.separated(
          controller: _scroll,
          key: const PageStorageKey('subagent-panel'),
          primary: false,
          shrinkWrap: false,
          padding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: AppSpacing.xs,
          ),
          itemCount: invocations.length + 2,
          separatorBuilder: (_, _) => const SizedBox.shrink(),
          itemBuilder: (context, index) {
            if (index == invocations.length + 1) {
              return const AccordionEdgeSpace();
            }
            if (index == 0) {
              return Row(
                children: [
                  Expanded(
                    child: Text(
                      'Subagents · ${invocations.length}',
                      style: context.typo.monoSmall.copyWith(
                        color: colors.muted2,
                      ),
                    ),
                  ),
                  if (AccordionExpansion.commandOf(context) == null)
                    TextButton(
                      onPressed: () => onCollapsedChanged(!collapsed),
                      style: TextButton.styleFrom(
                        textStyle: context.typo.monoSmall,
                        foregroundColor: colors.muted2,
                        minimumSize: const Size(48, 48),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                      child: Text(collapsed ? 'Expand all' : 'Collapse all'),
                    ),
                  if (onClose != null)
                    IconButton(
                      tooltip: 'Close subagents',
                      onPressed: onClose,
                      icon: Icon(LucideIcons.x, size: 16, color: colors.muted2),
                    ),
                ],
              );
            }
            final invocation = invocations[invocations.length - index];
            return _SubagentCard(
              key: ValueKey(invocation.tool.id),
              invocation: invocation,
              collapsed: collapsed,
            );
          },
          findItemIndexCallback: (key) {
            if (key is! ValueKey<String>) return null;
            final index = invocations.indexWhere((i) => i.tool.id == key.value);
            return index < 0 ? null : invocations.length - index;
          },
        ),
      ),
    );
  }
}

class _SubagentCard extends StatefulWidget {
  const _SubagentCard({
    super.key,
    required this.invocation,
    required this.collapsed,
  });

  final SubagentInvocation invocation;
  final bool collapsed;

  @override
  State<_SubagentCard> createState() => _SubagentCardState();
}

class _SubagentCardState extends State<_SubagentCard>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => _touched;
  bool _touched = false;
  bool? _expanded;
  (int, bool?)? _accordionCommand;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final command = AccordionExpansion.commandOf(context);
    if (command != _accordionCommand) {
      _accordionCommand = command;
      if (command?.$2 != null) _expanded = command!.$2!;
    }
  }

  @override
  void didUpdateWidget(_SubagentCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.collapsed != widget.collapsed ||
        oldWidget.invocation.tool.id != widget.invocation.tool.id) {
      _expanded = _accordionCommand?.$2;
      _touched = false;
      updateKeepAlive();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final invocation = widget.invocation;
    final colors = context.colors;
    final expanded = _expanded ?? !widget.collapsed;
    final color = invocation.statusColor(colors);
    return AccordionAnchor(
      bulkCommand: _accordionCommand,
      expanded: expanded,
      onCollapse: () {
        setState(() {
          _expanded = false;
          _touched = true;
        });
        updateKeepAlive();
      },
      header: CompactOutputHeader(
        title:
            '${invocation.name} · ${invocation.task.replaceAll(RegExp(r'\s+'), ' ').trim()}',
        expanded: expanded,
        disclosureKey: ValueKey('subagent-${invocation.tool.id}'),
        onToggle: () {
          setState(() {
            _expanded = !expanded;
            _touched = true;
          });
          updateKeepAlive();
        },
        status: invocation.status,
        color: color,
        icon: switch (invocation.status) {
          'Running call' => LucideIcons.loader,
          'Launched' => LucideIcons.arrowUpRight,
          'Call returned' => LucideIcons.check,
          'Failed' => LucideIcons.circleAlert,
          _ => LucideIcons.circleMinus,
        },
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          0,
          AppSpacing.xs,
          AppSpacing.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableText(invocation.task, style: context.typo.sansBody),
            if (invocation.tool.error?.isNotEmpty ?? false) ...[
              const SizedBox(height: 8),
              SelectableText(
                invocation.tool.error!,
                style: context.typo.mono.copyWith(color: colors.error),
              ),
            ],
            if (invocation.output.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                invocation.isWorkflow
                    ? 'Shared workflow output'
                    : 'Launch-call output',
                style: context.typo.monoSmall,
              ),
              AgentMarkdown(invocation.output, selectable: true),
            ],
          ],
        ),
      ),
    );
  }
}
