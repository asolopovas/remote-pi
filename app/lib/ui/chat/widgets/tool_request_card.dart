import 'dart:convert';

import 'compact_output_header.dart';
import 'source_code.dart';
import 'codemode_preview.dart';
import 'tool_presentation.dart';
import 'accordion_expansion.dart';

import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/widgets/code_viewport.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Inline tool execution card that appears in the chat flow.
//
// Historically this widget rendered Allow/Deny buttons + a 60s countdown
// assuming the Pi paused execution until the user decided. With the current
// Claude SDK integration the pi-extension emits `tool_request` AFTER the
// SDK has already accepted the tool (`tool_execution_start` fires post
// auto-approval), so the buttons could only blink for a few hundred
// milliseconds before `tool_result` arrived — confusing UX with no real
// gating. The card is now purely informational.
//
// `onDecide` is kept on the API for forward compat — when the Pi adds a
// real approval pause we can re-enable the controls. Today it is unused.

class ToolRequestCard extends StatefulWidget {
  final ToolEvent tool;
  final void Function(String toolCallId, ApproveDecision decision)? onDecide;

  const ToolRequestCard({super.key, required this.tool, this.onDecide});

  @override
  State<ToolRequestCard> createState() => _ToolRequestCardState();
}

class _ToolRequestCardState extends State<ToolRequestCard>
    with AutomaticKeepAliveClientMixin {
  bool _expanded = false;
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

  // Retain explicit choices, not every default collapsed row in the lazy list.
  bool _touched = false;
  String? _parsedScript;
  List<EmbeddedSource> _embedded = const [];

  List<EmbeddedSource> _previews(String script) {
    if (_parsedScript != script) {
      _parsedScript = script;
      _embedded = embeddedCodemodeSource(script);
    }
    return _embedded;
  }

  @override
  bool get wantKeepAlive => _touched;

  @override
  void didUpdateWidget(ToolRequestCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tool.id != tool.id ||
        oldWidget.tool.toolCallId != tool.toolCallId) {
      _expanded = _accordionCommand?.$2 ?? false;
      _touched = false;
      _parsedScript = null;
      _embedded = const [];
      updateKeepAlive();
    }
  }

  ToolEvent get tool => widget.tool;

  Color _statusColor(BuildContext context) {
    final colors = context.colors;
    return switch (tool.status) {
      ToolEventStatus.pending || ToolEventStatus.allowed => colors.accent,
      ToolEventStatus.completed => colors.success,
      ToolEventStatus.failed => colors.error,
      ToolEventStatus.denied || ToolEventStatus.expired => colors.muted,
    };
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final color = _statusColor(context);
    // Dim only the inert states (denied/expired); keep done/failed at full
    // opacity so their green/red read clearly.
    final dimmed =
        tool.status == ToolEventStatus.denied ||
        tool.status == ToolEventStatus.expired;

    return Opacity(
      opacity: dimmed ? 0.65 : 1.0,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        decoration: BoxDecoration(
          color: _expanded ? context.colors.codeBg : null,
          border: _expanded ? Border.all(color: context.colors.border) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: LayoutBuilder(
          builder: (context, constraints) =>
              _buildCodeBlock(context, color, constraints.maxWidth),
        ),
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    Color color,
    List<Widget> controls,
  ) {
    final statusLabel = switch (tool.status) {
      ToolEventStatus.pending || ToolEventStatus.allowed => 'RUNNING',
      ToolEventStatus.completed => 'DONE',
      ToolEventStatus.failed => 'FAILED',
      ToolEventStatus.denied => 'DENIED',
      ToolEventStatus.expired => 'EXPIRED',
    };

    return CompactOutputHeader(
      title: _compactTitle(),
      expanded: _expanded,
      disclosureKey: const Key('tool-disclosure'),
      onToggle: () {
        setState(() {
          _expanded = !_expanded;
          _touched = true;
        });
        updateKeepAlive();
      },
      status: statusLabel,
      statusAction: !_expanded || tool.result == null
          ? null
          : IconButton(
              tooltip: 'Copy output',
              iconSize: 18,
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: () => Clipboard.setData(
                ClipboardData(
                  text:
                      readableToolOutput(_toolName(tool.tool), tool.result) ??
                      toolFields(tool.result),
                ),
              ),
              icon: Icon(Icons.copy, color: context.colors.muted2),
            ),
      color: color,
      icon: switch (tool.status) {
        ToolEventStatus.pending || ToolEventStatus.allowed => Icons.sync,
        ToolEventStatus.completed => Icons.check_circle,
        ToolEventStatus.failed => Icons.error,
        _ => Icons.info,
      },
      controls: _expanded ? controls : const [],
    );
  }

  Widget _buildCodeBlock(
    BuildContext context,
    Color color,
    double nestedFrameWidth,
  ) {
    final source = _source(tool.tool, tool.args);
    final toolName = _toolName(tool.tool);
    final codemode = toolName == 'codemode';
    final embedded =
        _expanded &&
            codemode &&
            source != null &&
            {
              'javascript',
              'typescript',
            }.contains(SourceCode.normalizeLanguage(source.language))
        ? _previews(source.text)
        : const <EmbeddedSource>[];
    final fullDetails = _expanded
        ? [
            _fullText(tool.args),
            if (tool.result != null) _fullText(tool.result),
            if (tool.error?.isNotEmpty ?? false) tool.error!,
          ].join('\n\n')
        : '';
    final text = _expanded ? source?.text ?? fullDetails : '';
    final originalOutput = _expanded && tool.result != null
        ? _fullText(tool.result)
        : '';
    final output = _expanded && tool.result != null
        ? readableToolOutput(toolName, tool.result) ?? toolFields(tool.result)
        : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CodeViewport(
          key: ValueKey('tool-code-${tool.id}'),
          onCollapse: () {
            setState(() {
              _expanded = false;
              _touched = true;
            });
            updateKeepAlive();
          },
          bodyWrapWidth: embedded.isNotEmpty ? nestedFrameWidth : null,
          headerBuilder: (context, controls) =>
              _buildHeader(context, color, controls),
          text: text,
          copyTooltip: source == null
              ? 'Copy full details'
              : source.label == 'Command'
              ? 'Copy command'
              : 'Copy source',
          collapsible: false,
          headerExpanded: _expanded,
          showContent: _expanded,
          child: !_expanded
              ? const SizedBox.shrink()
              : SelectionArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (embedded.isNotEmpty) ...[
                        Text(
                          'Static embedded source · not execution records',
                          style: context.typo.monoSmall,
                        ),
                        // Outer Scroll unbounds its body, not nested frames.
                        for (final preview in embedded)
                          SizedBox(
                            width: nestedFrameWidth,
                            child: CodeViewport(
                              key: ValueKey(
                                'tool-embedded-${tool.id}-${preview.offset}',
                              ),
                              label: '${preview.label} · ${preview.language}',
                              text: preview.text,
                              copyTooltip: 'Copy decoded embedded string',
                              child: SourceCode(
                                preview.text,
                                language: preview.language,
                              ),
                            ),
                          ),
                        SizedBox(
                          width: nestedFrameWidth,
                          child: CodeViewport(
                            key: ValueKey('tool-original-${tool.id}'),
                            label: 'Original Script · ${source!.language}',
                            text: source.text,
                            copyTooltip: 'Copy original script',
                            child: SourceCode(
                              source.text,
                              language: source.language,
                            ),
                          ),
                        ),
                      ] else if (source != null) ...[
                        Text(
                          '${source.label} · ${source.language}',
                          style: context.typo.monoSmall,
                        ),
                        const SizedBox(height: 8),
                        SourceCode(source.text, language: source.language),
                      ] else
                        _buildToolSummary(context),
                      if (tool.result != null) ...[
                        const SizedBox(height: 8),
                        if (tool.status == ToolEventStatus.completed &&
                            _formatToolDisplay(tool.tool, tool.args) != null)
                          CodeViewport(
                            label: 'Execution output',
                            text: output,
                            child: SourceCode(
                              output,
                              language: _outputLanguage(),
                            ),
                          )
                        else ...[
                          Text('Output', style: context.typo.monoSmall),
                          SourceCode(output, language: _outputLanguage()),
                        ],
                      ],
                      if (tool.error?.isNotEmpty ?? false) ...[
                        const SizedBox(height: 8),
                        Text('Error', style: context.typo.monoSmall),
                        Text(
                          '✗ ${tool.error}',
                          style: context.typo.mono.copyWith(color: color),
                        ),
                      ],
                    ],
                  ),
                ),
        ),
        if (_expanded && tool.result != null && output != originalOutput)
          CodeViewport(
            key: ValueKey('tool-original-output-${tool.id}'),
            label: 'Original Output',
            text: originalOutput,
            copyTooltip: 'Copy original output',
            child: SelectionArea(
              child: SourceCode(
                originalOutput,
                language: tool.result is String ? '' : 'json',
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildToolSummary(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    final display = _formatToolDisplay(tool.tool, tool.args);
    if (display == null) {
      return Text(_formatArgs(tool.tool, tool.args), style: typo.mono);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            style: typo.mono,
            children: [
              TextSpan(text: display.command),
              for (final line in display.lines) ...[
                const TextSpan(text: '\n'),
                TextSpan(
                  text: line.text,
                  style: TextStyle(color: line.color(colors)),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  String _compactTitle() {
    final args = tool.args;
    final normalized = _toolName(tool.tool);
    String action = '';
    if (args is Map) {
      if (normalized == 'bash' || normalized == 'powershell') {
        action = _stringArg(args, const ['command']);
      } else if (normalized == 'read' ||
          normalized == 'write' ||
          normalized == 'edit') {
        action = _stringArg(args, const ['file_path', 'path']);
      } else {
        action = _stringArg(args, const ['path', 'query', 'pattern', 'task']);
      }
    }
    action = action.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (action.isEmpty) return tool.tool;
    final brief = action.split('\n').first;
    final diff = _formatToolDisplay(tool.tool, args);
    final stats = diff == null
        ? ''
        : ' · +${diff.lines.where((l) => l.text.startsWith('+')).length} −${diff.lines.where((l) => l.text.startsWith('-')).length}';
    return '${tool.tool.toUpperCase()} · $brief$stats';
  }

  static String _fullText(Object? value) => value is String
      ? value
      : const JsonEncoder.withIndent('  ').convert(value);

  static String _formatArgs(String tool, dynamic args) {
    if (args == null) return '';
    return toolFields(args);
  }

  String _outputLanguage() {
    if (tool.args is! Map) return '';
    final args = tool.args as Map;
    final explicit = _stringArg(args, const ['language', 'lang']);
    final language = SourceCode.normalizeLanguage(explicit);
    if (language != null) return language;
    final path = _stringArg(args, const ['file_path', 'path', 'file']);
    final name = path.split(RegExp(r'[/\\]')).last;
    if (!name.contains('.')) return '';
    return SourceCode.normalizeLanguage(name.split('.').last) ?? '';
  }

  static String _toolName(String name) {
    final match = RegExp(
      r'(^|[.:/]|__)(bash|powershell|codemode|write|edit|read)$',
      caseSensitive: false,
    ).firstMatch(name);
    return match?.group(2)?.toLowerCase() ?? name.toLowerCase();
  }

  static _Source? _source(String name, dynamic args) {
    if (args is! Map) return null;
    final tool = _toolName(name);
    if ((tool == 'bash' || tool == 'powershell') && args['command'] is String) {
      return _Source(args['command'] as String, 'Command', tool);
    }
    if (tool == 'codemode' && args['code'] is String) {
      final language = args['language'];
      return _Source(
        args['code'] as String,
        'Script',
        language is String ? language : 'javascript',
      );
    }
    if (tool == 'write' && args['content'] is String) {
      final path = _stringArg(args, const ['file_path', 'path']);
      final extension = path.split(RegExp(r'[/\\]')).last.split('.');
      final language = extension.length > 1
          ? SourceCode.normalizeLanguage(extension.last)
          : null;
      return _Source(args['content'] as String, 'Source', language ?? 'text');
    }
    return null;
  }

  static _ToolDisplay? _formatToolDisplay(String tool, dynamic args) {
    if (args is! Map) return null;
    return switch (_toolName(tool)) {
      'edit' => _formatEditDisplay(args),
      _ => null,
    };
  }

  static _ToolDisplay? _formatEditDisplay(Map args) {
    final filePath = _stringArg(args, const ['file_path', 'path']);
    final lines = <_DiffLine>[];
    final hunks = args['hunks'];
    if (hunks is! Iterable) {
      final edits =
          args['edits'] ??
          (args['old_string'] is String && args['new_string'] is String
              ? [
                  {
                    'oldText': args['old_string'],
                    'newText': args['new_string'],
                  },
                ]
              : null);
      if (edits is! Iterable) return null;
      for (final edit in edits) {
        if (edit is! Map ||
            edit['oldText'] is! String ||
            edit['newText'] is! String) {
          return null;
        }
        if (lines.isNotEmpty) lines.add(_DiffLine.context('…'));
        for (final text in (edit['oldText'] as String).split('\n')) {
          lines.add(_DiffLine.removed('- $text'));
        }
        for (final text in (edit['newText'] as String).split('\n')) {
          lines.add(_DiffLine.added('+ $text'));
        }
      }
      return lines.isEmpty
          ? null
          : _ToolDisplay(command: 'edit $filePath', lines: lines);
    }

    for (final hunk in hunks) {
      if (hunk is! Map || hunk['lines'] is! Iterable) continue;
      if (lines.isNotEmpty) lines.add(_DiffLine.context('      ...'));
      for (final rawLine in hunk['lines'] as Iterable) {
        if (rawLine is! Map) continue;
        final text = _lineText(rawLine);
        switch (rawLine['kind']) {
          case 'context':
            lines.add(_DiffLine.context(text));
          case 'remove':
            lines.add(_DiffLine.removed(text));
          case 'add':
            lines.add(_DiffLine.added(text));
          case 'ellipsis':
            lines.add(_DiffLine.context('      ...'));
        }
      }
    }

    if (lines.isEmpty) return null;
    return _ToolDisplay(command: 'edit $filePath', lines: lines);
  }

  static String _lineText(Map rawLine) {
    final sign = switch (rawLine['kind']) {
      'remove' => '-',
      'add' => '+',
      _ => ' ',
    };
    final lineNumber = rawLine['oldLine'] ?? rawLine['newLine'];
    final number = lineNumber is int ? lineNumber.toString().padLeft(3) : '   ';
    return '$sign $number ${rawLine['text'] ?? ''}';
  }

  static String _stringArg(Map args, List<String> keys) {
    for (final key in keys) {
      final value = args[key];
      if (value is String) return value;
    }
    return '';
  }
}

class _ToolDisplay {
  final String command;
  final List<_DiffLine> lines;

  const _ToolDisplay({required this.command, required this.lines});
}

class _DiffLine {
  final String text;
  final Color Function(AppColors colors) color;

  const _DiffLine._(this.text, this.color);

  factory _DiffLine.removed(String text) =>
      _DiffLine._(text, (colors) => colors.error);

  factory _DiffLine.added(String text) =>
      _DiffLine._(text, (colors) => colors.success);

  factory _DiffLine.context(String text) =>
      _DiffLine._(text, (colors) => colors.text);
}

class _Source {
  const _Source(this.text, this.label, this.language);
  final String text;
  final String label;
  final String language;
}
