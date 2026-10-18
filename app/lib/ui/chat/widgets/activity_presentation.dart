import 'package:app/domain/session_state.dart';

String activityToolName(String name) =>
    name.split(RegExp(r'[.:/]|__')).last.toLowerCase();

bool isReadActivity(ChatMessage message) =>
    message is ToolEvent &&
    {
      'read',
      'read_symbol',
      'read_enclosing',
    }.contains(activityToolName(message.tool));

String activityFilePath(ToolEvent tool) {
  final args = tool.args;
  if (args is! Map) return '';
  return '${args['path'] ?? args['file_path'] ?? args['file'] ?? ''}';
}

const _coordinationTools = {
  'subagent_supervisor',
  'contact_supervisor',
  'subagents_enable',
  'list_peers',
  'agent_send',
  'agent_request',
};

const _inspectionTools = {
  'project_report',
  'module_report',
  'symbol_search',
  'effective_config',
  'lens_diagnostics',
  'pi_lens_activate_tools',
  'tool_search',
  'lsp_navigation',
  'ast_grep_search',
};

bool isCoordinationActivity(ToolEvent tool) {
  final name = activityToolName(tool.tool);
  return _coordinationTools.contains(name) ||
      name == 'subagent' &&
          tool.args is Map &&
          (tool.args as Map)['action'] != null;
}

/// Presentation only: keep original events/history intact and never infer the
/// purpose of arbitrary shell/codemode scripts or unknown tools from their text.
bool isRoutineActivity(ToolEvent tool) =>
    isCoordinationActivity(tool) ||
    _inspectionTools.contains(activityToolName(tool.tool));

bool hasActivityIssue(ToolEvent tool) =>
    tool.status == ToolEventStatus.failed ||
    tool.status == ToolEventStatus.denied ||
    tool.status == ToolEventStatus.expired;

bool isFeedActivity(ChatMessage message) =>
    !isReadActivity(message) &&
    (message is! ToolEvent ||
        !isRoutineActivity(message) ||
        hasActivityIssue(message));

/// Routine machinery is status, not a timeline accordion. Failures stay visible.
List<ChatMessage> activityRows(List<ChatMessage> messages) =>
    messages.where(isFeedActivity).toList();

String? activeActivityLabel(List<ChatMessage> messages) {
  for (final message in messages.reversed) {
    if (message is! ToolEvent) continue;
    if (message.status != ToolEventStatus.pending &&
        message.status != ToolEventStatus.allowed) {
      return null;
    }
    if (isReadActivity(message)) return activeReadLabel([message]);
    if (isCoordinationActivity(message)) return 'Coordinating agents…';
    if (isRoutineActivity(message)) return 'Checking project…';
    return null;
  }
  return null;
}

String activityIssueLabel(ToolEvent tool) {
  final subject = isCoordinationActivity(tool)
      ? 'Agent coordination'
      : 'Project check';
  final outcome = switch (tool.status) {
    ToolEventStatus.denied => 'denied',
    ToolEventStatus.expired => 'expired',
    _ => 'failed',
  };
  return '$subject $outcome';
}

String? activityIssueDetail(ToolEvent tool) {
  final result = tool.error?.trim().isNotEmpty == true
      ? tool.error
      : tool.result;
  final value = result is Map ? result['message'] ?? result['error'] : result;
  if (value is! String) return null;
  final lines = value
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty);
  if (lines.isEmpty) return null;
  return String.fromCharCodes(lines.first.runes.take(160));
}

/// Only current execution belongs in status, not an earlier completed read.
String? activeReadLabel(List<ChatMessage> messages) {
  for (final message in messages.reversed) {
    if (message is! ToolEvent) continue;
    if (!isReadActivity(message) ||
        (message.status != ToolEventStatus.pending &&
            message.status != ToolEventStatus.allowed)) {
      return null;
    }
    final path = activityFilePath(message);
    return path.isEmpty ? 'Reading…' : 'Reading $path…';
  }
  return null;
}
