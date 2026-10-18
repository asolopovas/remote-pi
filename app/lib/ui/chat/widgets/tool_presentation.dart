import 'dart:convert';

/// Human-readable fields for typed tool arguments/results. Strings, including
/// source and whitespace, are never parsed or rewritten. Raw JSON stays in Details.
String toolFields(Object? value) {
  if (value is String) return value;
  if (value == null) return 'None';
  if (value is! Map && value is! List) return '$value';
  final out = StringBuffer();
  var count = 0;
  void field(Object? item, String indent, int depth, [String? label]) {
    if (++count > 512 || depth > 8) {
      throw const FormatException('Too many fields');
    }
    final prefix = label == null
        ? indent
        : label == '•'
        ? '$indent• '
        : '$indent$label: ';
    if (item is Map && item.isNotEmpty) {
      if (label != null) out.writeln(prefix.trimRight());
      for (final entry in item.entries) {
        field(
          entry.value,
          label == null ? indent : '$indent  ',
          depth + 1,
          '${entry.key}'.replaceAll('_', ' '),
        );
      }
    } else if (item is List && item.isNotEmpty) {
      if (label != null) out.writeln(prefix.trimRight());
      for (final entry in item) {
        field(entry, '$indent  ', depth + 1, '•');
      }
    } else {
      final text = item == null ? 'None' : '$item';
      out.writeln('$prefix$text');
    }
  }

  try {
    field(value, '', 0);
    return out.toString().replaceFirst(RegExp(r'\n$'), '');
  } on FormatException {
    return const JsonEncoder.withIndent('  ').convert(value);
  }
}
