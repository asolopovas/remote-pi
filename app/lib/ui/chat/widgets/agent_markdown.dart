import 'package:app/ui/chat/widgets/code_viewport.dart';
import 'source_code.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

class AgentMarkdown extends StatelessWidget {
  const AgentMarkdown(this.data, {super.key, this.selectable = false});

  final String data;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    final markdown = GptMarkdown(
      data,
      style: typo.mono,
      onLinkTap: (url, _) => _openLink(context, url),
      highlightBuilder: (context, text, style) => Text(
        text,
        style: typo.mono.copyWith(
          color: colors.highlight,
          backgroundColor: colors.codeBg,
        ),
      ),
      codeBuilder: (context, name, code, closed) => CodeViewport(
        label: name,
        text: code,
        child: selectable
            ? SourceCode(code, language: name)
            : SelectionArea(child: SourceCode(code, language: name)),
      ),
    );
    return selectable ? SelectionArea(child: markdown) : markdown;
  }

  static Future<void> _openLink(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        messenger?.showSnackBar(SnackBar(content: Text("Couldn't open $url")));
      }
    } catch (_) {
      messenger?.showSnackBar(SnackBar(content: Text("Couldn't open $url")));
    }
  }
}
