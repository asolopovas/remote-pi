import 'dart:async';

import 'compact_output_header.dart';
import 'accordion_viewport.dart';
import 'accordion_expansion.dart';

import 'package:app/data/preferences/preferences.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:provider/provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class CodeViewport extends StatefulWidget {
  const CodeViewport({
    super.key,
    required this.child,
    required this.text,
    this.label = 'code',
    this.headerBuilder,
    this.collapsible = true,
    this.showContent = true,
    this.headerExpanded = false,
    this.copyTooltip = 'Copy code',
    this.bodyWrapWidth,
    this.onCollapse,
  }) : assert(
         bodyWrapWidth == null ||
             (bodyWrapWidth > 0 && bodyWrapWidth < double.infinity),
       );

  final VoidCallback? onCollapse;
  final Widget child;
  final String text;
  final String label;
  final String copyTooltip;
  // Composite bodies need stable ancestry while their nested frames keep state.
  // Null preserves the original viewport behavior for all existing callers.
  final double? bodyWrapWidth;
  final Widget Function(BuildContext context, List<Widget> controls)?
  headerBuilder;
  final bool collapsible;
  final bool showContent;
  final bool headerExpanded;

  @override
  State<CodeViewport> createState() => _CodeViewportState();
}

class _CodeViewportState extends State<CodeViewport>
    with AutomaticKeepAliveClientMixin {
  final _scroll = ScrollController();
  bool _expanded = false;
  (int, bool?)? _accordionCommand;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final command = AccordionExpansion.commandOf(context);
    if (command != _accordionCommand) {
      _accordionCommand = command;
      if (widget.collapsible && command?.$2 != null) {
        _expanded = command!.$2!;
      }
    }
  }

  // Disclosure/copy do not pin the default; only Wrap/Scroll sets this.
  bool? _wrapOverride;
  bool _copied = false;
  // Retain explicit choices, not every default collapsed row in the lazy list.
  bool _touched = false;
  Timer? _reset;

  @override
  bool get wantKeepAlive => _touched;

  void _toggleWrap(bool wrap) {
    if (!wrap && widget.bodyWrapWidth != null && _scroll.hasClients) {
      _scroll.jumpTo(0);
    }
    setState(() {
      _wrapOverride = !wrap;
      _touched = true;
    });
    updateKeepAlive();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // Nullable lookup supports standalone viewports without masking provider errors.
    final wrap =
        _wrapOverride ??
        (context.watch<Preferences?>()?.wrapTextByDefault ?? true);
    final colors = context.colors;
    final standalone = widget.headerBuilder == null;
    final frame = BoxDecoration(
      color: colors.codeBg,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: colors.border),
    );
    final controls = <Widget>[
      if (_expanded || !widget.collapsible)
        IconButton(
          key: const Key('code-wrap'),
          tooltip: wrap ? 'Scroll horizontally' : 'Wrap code',
          onPressed: () => _toggleWrap(wrap),
          iconSize: 18,
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          padding: const EdgeInsets.all(4),
          icon: Icon(
            wrap ? LucideIcons.moveHorizontal : LucideIcons.wrapText,
            color: colors.muted2,
          ),
        ),
      IconButton(
        key: const Key('code-copy'),
        tooltip: widget.copyTooltip,
        iconSize: 18,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        padding: const EdgeInsets.all(4),
        onPressed: _copy,
        icon: Icon(
          _copied ? LucideIcons.check : LucideIcons.copy,
          color: _copied ? colors.success : colors.muted2,
        ),
      ),
    ];
    final header =
        widget.headerBuilder?.call(context, controls) ??
        CompactOutputHeader(
          title:
              '${widget.label.isEmpty ? 'code' : widget.label} · ${widget.text.split('\n').length} ${widget.text.split('\n').length == 1 ? 'line' : 'lines'}',
          expanded: _expanded,
          disclosureKey: const Key('code-disclosure'),
          onToggle: () {
            setState(() {
              _expanded = !_expanded;
              _touched = true;
            });
            updateKeepAlive();
          },
          controls: controls,
        );
    final padding = standalone
        ? const EdgeInsets.fromLTRB(8, 2, 8, kAccordionGutter)
        : const EdgeInsets.only(top: 4, bottom: kAccordionGutter);
    final content = widget.bodyWrapWidth != null
        ? Scrollbar(
            controller: _scroll,
            thumbVisibility: !wrap,
            scrollbarOrientation: ScrollbarOrientation.bottom,
            child: SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              physics: wrap ? const NeverScrollableScrollPhysics() : null,
              padding: padding,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: wrap ? widget.bodyWrapWidth! : double.infinity,
                ),
                child: widget.child,
              ),
            ),
          )
        : wrap
        ? Padding(padding: padding, child: widget.child)
        : Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            scrollbarOrientation: ScrollbarOrientation.bottom,
            child: SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              padding: padding,
              child: widget.child,
            ),
          );
    return Container(
      width: double.infinity,
      margin: standalone ? const EdgeInsets.symmetric(vertical: 4) : null,
      decoration: standalone ? frame : null,
      child: AccordionAnchor(
        bulkCommand: _accordionCommand,
        expanded: standalone ? _expanded : widget.headerExpanded,
        onCollapse: standalone
            ? () {
                setState(() {
                  _expanded = false;
                  _touched = true;
                });
                updateKeepAlive();
              }
            : widget.onCollapse,
        header: header,
        body: widget.showContent && (_expanded || !widget.collapsible)
            ? content
            : const SizedBox.shrink(),
      ),
    );
  }
}
