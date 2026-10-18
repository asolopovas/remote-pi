import 'dart:convert';

import 'source_code.dart';

class EmbeddedSource {
  const EmbeddedSource(this.offset, this.label, this.text, this.language);
  final int offset;
  final String label;
  final String text;
  final String language;
}

/// A deliberately small static-literal dialect, NOT a JavaScript evaluator.
/// The whole script must match; unsupported syntax never yields partial previews.
List<EmbeddedSource> embeddedCodemodeSource(String source) {
  if (source.length > SourceCode.maxHighlightLength) return const [];
  try {
    return _StaticCalls(source).parse();
  } on FormatException {
    return const [];
  }
}

class _StaticCalls {
  _StaticCalls(this.source);
  final String source;
  int pos = 0;
  int values = 0;
  final previews = <EmbeddedSource>[];

  Never fail() => throw const FormatException('Unsupported static source');
  static const _lineTerminators = '\n\r\u2028\u2029';

  void space() {
    while (pos < source.length) {
      if (' \t'.contains(source[pos]) ||
          _lineTerminators.contains(source[pos])) {
        pos++;
      } else if (source.startsWith('//', pos)) {
        pos += 2;
        while (pos < source.length && !_lineTerminators.contains(source[pos])) {
          pos++;
        }
      } else if (source.startsWith('/*', pos)) {
        final end = source.indexOf('*/', pos + 2);
        if (end < 0) fail();
        pos = end + 2;
      } else {
        break;
      }
    }
  }

  bool take(String token) {
    space();
    if (!source.startsWith(token, pos)) return false;
    pos += token.length;
    return true;
  }

  void need(String token) {
    if (!take(token)) fail();
  }

  String identifier() {
    space();
    final start = pos;
    while (pos < source.length &&
        RegExp(r'[A-Za-z0-9_$]').hasMatch(source[pos])) {
      pos++;
    }
    final word = source.substring(start, pos);
    if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(word)) fail();
    return word;
  }

  List<EmbeddedSource> parse() {
    space();
    while (pos < source.length) {
      final offset = pos;
      var head = identifier();
      final wrapped = head == 'text';
      if (wrapped) {
        need('(');
        head = identifier();
      }
      if (head == 'await') head = identifier();
      if (head != 'tools') fail();
      need('.');
      final tool = identifier();
      need('(');
      final args = value(0);
      if (args is! Map<String, Object?>) fail();
      need(')');
      if (wrapped) need(')');
      need(';');
      add(tool, args, offset);
      space();
    }
    return List.unmodifiable(previews);
  }

  Object? value(int depth) {
    if (depth > 16 || ++values > 512) fail();
    space();
    if (pos == source.length) fail();
    if (source[pos] == '"' || source[pos] == "'") return string();
    if (take('{')) {
      final map = <String, Object?>{};
      if (take('}')) return map;
      do {
        space();
        if (pos == source.length) fail();
        final key = source[pos] == '"' || source[pos] == "'"
            ? string()
            : identifier();
        if (map.containsKey(key)) fail();
        need(':');
        map[key] = value(depth + 1);
        if (take('}')) return map;
        need(',');
      } while (!take('}'));
      return map;
    }
    if (take('[')) {
      final list = <Object?>[];
      if (take(']')) return list;
      do {
        list.add(value(depth + 1));
        if (take(']')) return list;
        need(',');
      } while (!take(']'));
      return list;
    }
    final match = RegExp(
      r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?',
    ).matchAsPrefix(source, pos);
    if (match != null) {
      pos = match.end;
      final number = num.tryParse(match[0]!);
      if (number == null || !number.isFinite) fail();
      return number;
    }
    return switch (identifier()) {
      'true' => true,
      'false' => false,
      'null' => null,
      _ => fail(),
    };
  }

  String string() {
    space();
    final quote = source[pos++];
    final out = StringBuffer();
    while (pos < source.length) {
      final ch = source[pos++];
      if (ch == quote) return out.toString();
      if (ch.codeUnitAt(0) < 32 || ch == '\u2028' || ch == '\u2029') fail();
      if (ch != r'\') {
        out.write(ch);
        continue;
      }
      if (pos == source.length) fail();
      final escape = source[pos++];
      final decoded = switch (escape) {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        'b' => '\b',
        'f' => '\f',
        'v' => '\v',
        "'" => "'",
        '"' => '"',
        r'\' => r'\',
        _ => null,
      };
      if (decoded != null) {
        out.write(decoded);
      } else if (escape == 'x' || escape == 'u') {
        final count = escape == 'x' ? 2 : 4;
        if (pos + count > source.length) fail();
        final hex = source.substring(pos, pos + count);
        if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) fail();
        out.writeCharCode(int.parse(hex, radix: 16));
        pos += count;
      } else {
        // Identity/octal escapes and line continuations intentionally unsupported.
        fail();
      }
    }
    fail();
  }

  void add(String tool, Map<String, Object?> args, int offset) {
    void preview(String label, Object? text, String language) {
      if (text is! String || previews.length >= 32) fail();
      previews.add(
        EmbeddedSource(
          offset + previews.length,
          'Static embedded $label',
          text,
          language,
        ),
      );
    }

    if (tool == 'bash' || tool == 'powershell') {
      if (args.keys.any(
        (key) => !{'command', 'timeout', 'description'}.contains(key),
      )) {
        fail();
      }
      preview('$tool command', args['command'], tool);
    } else if (tool == 'edit' || tool == 'write') {
      if (args['path'] is! String) fail();
      final path = args['path'] as String;
      final extension = path.split(RegExp(r'[/\\]')).last.split('.');
      final language = extension.length > 1
          ? SourceCode.normalizeLanguage(extension.last) ?? 'text'
          : 'text';
      if (tool == 'write') {
        if (args.keys.any((key) => !{'path', 'content'}.contains(key))) fail();
        preview('write content · $path', args['content'], language);
      } else {
        if (args.keys.any((key) => !{'path', 'edits'}.contains(key))) fail();
        final edits = args['edits'];
        if (edits is! List || edits.isEmpty) fail();
        for (var i = 0; i < edits.length; i++) {
          final edit = edits[i];
          if (edit is! Map ||
              edit.length != 2 ||
              !edit.containsKey('oldText') ||
              !edit.containsKey('newText')) {
            fail();
          }
          preview('edit ${i + 1} before · $path', edit['oldText'], language);
          preview('edit ${i + 1} after · $path', edit['newText'], language);
        }
      }
    } else {
      fail();
    }
  }
}

/// Only known shell results and codemode envelopes may unwrap this schema.
/// A null result means the original presentation must remain unchanged.
String? readableToolOutput(String tool, Object? result) {
  if (tool == 'codemode' && result is String) {
    return readableCodemodeOutput(result);
  }
  if (tool != 'bash' && tool != 'powershell') return null;
  return _wrappedOutput(result);
}

String? _wrappedOutput(Object? result) {
  Object? decoded = result;
  if (result is String) {
    if (result.length > 96000) return null;
    try {
      decoded = jsonDecode(result);
    } on FormatException {
      return null;
    } on StackOverflowError {
      return null;
    }
  }
  if (decoded is! Map ||
      decoded.keys.any(
        (key) => !{
          'output',
          'truncated',
          'exit_code',
          'wall_time_seconds',
          'full_output_path',
        }.contains(key),
      ) ||
      (decoded.containsKey('full_output_path') &&
          (decoded['full_output_path'] is! String ||
              (decoded['full_output_path'] as String).isEmpty ||
              (decoded['full_output_path'] as String).length > 4096)) ||
      decoded['output'] is! String ||
      (decoded['output'] as String).length > 96000 ||
      decoded['truncated'] is! bool ||
      decoded['exit_code'] is! int ||
      decoded['wall_time_seconds'] is! num ||
      !(decoded['wall_time_seconds'] as num).isFinite ||
      (decoded['wall_time_seconds'] as num) < 0) {
    return null;
  }
  if (result is String && !_uniqueScalarPropertyKeys(result, decoded.length)) {
    return null;
  }
  final notices = <String>[
    if (decoded['exit_code'] != 0) 'Exit code ${decoded['exit_code']}',
    if (decoded['truncated'] == true) 'Output truncated',
  ];
  final output = decoded['output'] as String;
  final summary = notices.isEmpty ? '' : notices.join(' · ');
  final path = decoded['full_output_path'];
  final body = [
    if (summary.isNotEmpty) summary,
    if (path != null) 'Full output: $path',
    if (output.isNotEmpty) output,
  ].join('\n');
  return body.isEmpty ? 'Completed.' : body;
}

/// Used only AFTER JSON decoding and the known scalar-field schema validation.
/// Detects duplicate top-level keys without interpreting JSON values. Quoted
/// output tokens are skipped whole so embedded braces/commas/keys stay content.
bool _uniqueScalarPropertyKeys(String source, int expectedKeys) {
  var pos = 0;
  void space() {
    while (pos < source.length && ' \t\r\n'.contains(source[pos])) {
      pos++;
    }
  }

  int quotedEnd(int start) {
    if (start >= source.length || source[start] != '"') return -1;
    var end = start + 1;
    while (end < source.length) {
      if (source[end] == '"') return end + 1;
      end += source[end] == r'\' ? 2 : 1;
    }
    return -1;
  }

  space();
  if (pos == source.length || source[pos++] != '{') return false;
  final keys = <String>{};
  while (pos < source.length) {
    space();
    final keyEnd = quotedEnd(pos);
    if (keyEnd < 0) return false;
    final key = jsonDecode(source.substring(pos, keyEnd));
    if (key is! String || !keys.add(key)) return false;
    pos = keyEnd;
    space();
    if (pos == source.length || source[pos++] != ':') return false;
    space();
    if (pos == source.length) return false;
    if (source[pos] == '"') {
      final valueEnd = quotedEnd(pos);
      if (valueEnd < 0) return false;
      pos = valueEnd;
    } else {
      final start = pos;
      while (pos < source.length && source[pos] != ',' && source[pos] != '}') {
        if ('{["]'.contains(source[pos])) return false;
        pos++;
      }
      if (source.substring(start, pos).trim().isEmpty) return false;
    }
    space();
    if (pos == source.length) return false;
    final separator = source[pos++];
    if (separator == '}') {
      space();
      return pos == source.length && keys.length == expectedKeys;
    }
    if (separator != ',') return false;
  }
  return false;
}

/// Only the known codemode envelope with one validated wrapper or complete,
/// ordered text sections qualifies.
/// Flattened sections are never assigned to embedded source calls.
String readableCodemodeOutput(String original) {
  if (original.length > 96000) return original;
  final envelope = RegExp(
    r'^Script completed\nWall time [0-9]+(?:\.[0-9]+)? seconds\nOutput:\n\n?',
  );
  final prefix = envelope.firstMatch(original);
  if (prefix == null) return original;
  final marker = RegExp(
    r'^==> text ([1-9][0-9]*)/([1-9][0-9]*) <==\n',
    multiLine: true,
  );
  final sections = marker.allMatches(original, prefix.end).toList();
  if (sections.isEmpty) {
    final body = original.substring(prefix.end);
    // Body starts immediately: never absorb a third LF or arbitrary padding.
    if (!body.startsWith('{')) return original;
    final readable = _wrappedOutput(body);
    return readable ?? original;
  }
  if (sections.length > 32 || sections.first.start != prefix.end) {
    return original;
  }
  final total = int.tryParse(sections.first[2]!);
  if (total != sections.length) return original;
  final out = StringBuffer();
  for (var i = 0; i < sections.length; i++) {
    final section = sections[i];
    if (section[1] != '${i + 1}' || section[2] != '$total') return original;
    final end = i + 1 < sections.length
        ? sections[i + 1].start
        : original.length;
    final body = original.substring(section.end, end);
    if (sections.length > 1) out.writeln('Output ${i + 1}');
    final readable = _wrappedOutput(body);
    if (readable != null) {
      out.write(readable);
      if (!readable.endsWith('\n')) out.write('\n');
    } else {
      out.write(body);
    }
  }
  return out.toString();
}
