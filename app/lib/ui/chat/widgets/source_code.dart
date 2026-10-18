import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:highlight/highlight_core.dart' as syntax;
import 'package:highlight/languages/bash.dart';
import 'package:highlight/languages/powershell.dart';
import 'package:highlight/languages/javascript.dart';
import 'package:highlight/languages/typescript.dart';
import 'package:highlight/languages/dart.dart';
import 'package:highlight/languages/python.dart';
import 'package:highlight/languages/json.dart';
import 'package:highlight/languages/css.dart';
import 'package:highlight/languages/xml.dart';
import 'package:highlight/languages/yaml.dart';
import 'package:highlight/languages/go.dart';
import 'package:highlight/languages/rust.dart';
import 'package:highlight/languages/sql.dart';
import 'package:highlight/languages/java.dart';
import 'package:highlight/languages/kotlin.dart';
import 'package:highlight/languages/swift.dart';

/// Only mounted disclosed source is parsed; each viewport caches one bounded tree.
class SourceCode extends StatefulWidget {
  const SourceCode(this.source, {super.key, this.language = ''});
  final String source;
  final String language;
  static const maxHighlightLength = 24000;

  static String? normalizeLanguage(String name) => switch (name.toLowerCase()) {
    'sh' || 'shell' || 'bash' || 'zsh' => 'bash',
    'ps' || 'ps1' || 'pwsh' || 'powershell' => 'powershell',
    'js' || 'jsx' || 'javascript' => 'javascript',
    'ts' || 'tsx' || 'typescript' => 'typescript',
    'py' || 'python' => 'python',
    'html' || 'xml' => 'xml',
    'yml' || 'yaml' => 'yaml',
    'rs' || 'rust' => 'rust',
    'kt' || 'kts' || 'kotlin' => 'kotlin',
    'dart' ||
    'json' ||
    'css' ||
    'go' ||
    'sql' ||
    'java' ||
    'swift' => name.toLowerCase(),
    _ => null,
  };

  static final _parser = syntax.Highlight()
    ..registerLanguage('bash', bash)
    ..registerLanguage('powershell', powershell)
    ..registerLanguage('javascript', javascript)
    ..registerLanguage('typescript', typescript)
    ..registerLanguage('dart', dart)
    ..registerLanguage('python', python)
    ..registerLanguage('json', json)
    ..registerLanguage('css', css)
    ..registerLanguage('xml', xml)
    ..registerLanguage('yaml', yaml)
    ..registerLanguage('go', go)
    ..registerLanguage('rust', rust)
    ..registerLanguage('sql', sql)
    ..registerLanguage('java', java)
    ..registerLanguage('kotlin', kotlin)
    ..registerLanguage('swift', swift);

  @override
  State<SourceCode> createState() => _SourceCodeState();
}

class _SourceCodeState extends State<SourceCode> {
  List<syntax.Node>? _nodes;
  String? _source;
  String? _language;

  void _parse() {
    if (_source == widget.source && _language == widget.language) return;
    _source = widget.source;
    _language = widget.language;
    _nodes = null;
    final language = SourceCode.normalizeLanguage(widget.language);
    if (language == null ||
        widget.source.length > SourceCode.maxHighlightLength) {
      return;
    }
    try {
      final nodes = SourceCode._parser
          .parse(widget.source, language: language)
          .nodes;
      // Never trust a parser to rewrite source, even for malformed syntax.
      if (nodes != null && _plain(nodes) == widget.source) _nodes = nodes;
    } catch (_) {
      // Third-party parser failure must not prevent reviewing/copying source.
    }
  }

  static String _plain(List<syntax.Node> nodes) => nodes
      .map((node) => node.value ?? _plain(node.children ?? const []))
      .join();

  TextSpan _span(syntax.Node node, AppColors colors) => TextSpan(
    text: node.value,
    style: TextStyle(
      color: switch (node.className) {
        'keyword' || 'built_in' || 'selector-tag' => colors.accent,
        'string' || 'attr' || 'regexp' => colors.success,
        'number' || 'literal' => colors.warning,
        'title' || 'function' || 'variable' => colors.highlight,
        'comment' || 'meta' => colors.muted,
        _ => null,
      },
    ),
    children: node.children?.map((child) => _span(child, colors)).toList(),
  );

  @override
  Widget build(BuildContext context) {
    _parse();
    return Text.rich(
      TextSpan(
        style: context.typo.mono.copyWith(
          color: context.colors.text,
          height: 1.45,
        ),
        text: _nodes == null ? widget.source : null,
        children: _nodes?.map((node) => _span(node, context.colors)).toList(),
      ),
    );
  }
}
