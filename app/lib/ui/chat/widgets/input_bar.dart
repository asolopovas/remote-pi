import 'dart:async';

import 'package:app/data/images/image_picker_service.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/attachment/states/attachment_state.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/voice/states/voice_input_state.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// InputBar — bottom message composer.
// - Disabled (grayed) when offline.
// - During streaming, empty composer shows Stop; typed text sends steering.
// - Plan/28 — quick actions (⚙) icon sits to the left of the attach
//   button and is visible only while the field is empty (so it never
//   competes with the send affordance).
// - Tap microphone starts live dictation; next tap stops, never sends.

/// Permission guidance requested from the host page.
enum VoiceHint { permissionDenied }

class InputBar extends StatefulWidget {
  final bool disabled; // offline or no peer
  final bool streaming; // show cancel instead of send
  final void Function(String text) onSend;
  final VoidCallback? onCancel;
  final VoidCallback? onOpenQuickActions;

  /// Pi-side queued follow-ups. Empty means no queued messages.
  final List<QueuedMsg> queuedMessages;
  final void Function(String text)? onSetQueued;
  final void Function(String id)? onClearQueued;

  /// Tap-toggle dictation ViewModel. Null hosts show unavailable feedback.
  final VoiceInputViewModel? voice;

  /// Surfaces a [VoiceHint] to the host page for a snackbar /
  /// settings deep-link.
  final void Function(VoiceHint hint)? onVoiceHint;

  /// Plan/30 — image-attachment ViewModel (preview state + model vision).
  /// Null in tests / when attachments aren't wired.
  final AttachmentViewModel? attachment;

  /// Plan/30 — open the Camera/Gallery sheet. Null disables the attach
  /// button (offline/streaming); vision/has-image gating is internal.
  final VoidCallback? onOpenAttach;

  const InputBar({
    super.key,
    required this.onSend,
    this.onCancel,
    this.onOpenQuickActions,
    this.queuedMessages = const [],
    this.onSetQueued,
    this.onClearQueued,
    this.voice,
    this.onVoiceHint,
    this.attachment,
    this.onOpenAttach,
    this.disabled = false,
    this.streaming = false,
  });

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> with WidgetsBindingObserver {
  final _controller = TextEditingController();
  // Owns the field's focus so we can intercept hardware Enter on its OWN
  // node (the primary/leaf focus). An ancestor Focus runs too late: the
  // FocusManager dispatches leaf→root, so the field's multiline newline
  // handling would consume Enter before an ancestor ever sees it.
  late final FocusNode _focusNode = FocusNode(onKeyEvent: _onComposerKey);
  bool _empty = true;
  // Voice owns only the text it last wrote, preserving the starting draft.
  // Any manual text/composition edit relinquishes ownership and stops capture.
  String? _voiceText;
  String _voicePrefix = '';
  bool _voiceUnavailable = false;
  bool _writingVoice = false;
  StreamSubscription<String>? _transcriptSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onTextChange);
    _subscribeTranscripts();
  }

  @override
  void didUpdateWidget(InputBar old) {
    super.didUpdateWidget(old);
    if (!identical(old.voice, widget.voice)) {
      unawaited(old.voice?.cancel());
      _voiceText = null;
      _transcriptSub?.cancel();
      _subscribeTranscripts();
    }
    if (!old.disabled && widget.disabled) unawaited(widget.voice?.cancel());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // inactive can be the permission prompt; don't cancel its explicit intent.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(widget.voice?.cancel());
    }
  }

  void _subscribeTranscripts() {
    _transcriptSub = widget.voice?.transcripts.listen(_onTranscript);
  }

  void _onTranscript(String text) {
    if (!mounted ||
        text.isEmpty ||
        _voiceText == null ||
        _controller.text != _voiceText) {
      return;
    }
    final selection = _controller.selection;
    final atEnd =
        !selection.isValid ||
        (selection.isCollapsed &&
            selection.extentOffset == _controller.text.length);
    _writingVoice = true;
    final separator =
        _voicePrefix.isEmpty || RegExp(r'\s$').hasMatch(_voicePrefix)
        ? ''
        : ' ';
    final draft = '$_voicePrefix$separator$text';
    _voiceText = draft;
    _controller.value = TextEditingValue(
      text: draft,
      selection: atEnd
          ? TextSelection.collapsed(offset: draft.length)
          : TextSelection(
              baseOffset: selection.baseOffset.clamp(0, draft.length),
              extentOffset: selection.extentOffset.clamp(0, draft.length),
            ),
    );
    _writingVoice = false;
  }

  void _onTextChange() {
    if (!_writingVoice &&
        _voiceText != null &&
        (_controller.text != _voiceText ||
            !_controller.value.composing.isCollapsed)) {
      _voiceText = null;
      unawaited(widget.voice?.cancel());
    }
    final next = _controller.text.isEmpty;
    if (next == _empty) return;
    setState(() {
      _empty = next;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _transcriptSub?.cancel();
    unawaited(widget.voice?.cancel());
    _controller.removeListener(_onTextChange);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    if (widget.voice?.active ?? false) return;
    final text = _controller.text.trim();
    // Plan/30 — an attached image makes an empty-caption send valid.
    final hasImage = widget.attachment?.hasImage ?? false;
    if (text.isEmpty && !hasImage) return;
    _controller.clear();
    widget.onSend(text);
  }

  void _editQueued(QueuedMsg item) {
    if (!item.editable) return;
    widget.onClearQueued?.call(item.id);
    _controller.text = item.text;
    _controller.selection = TextSelection.collapsed(offset: item.text.length);
    _focusNode.requestFocus();
  }

  /// Hardware-keyboard behaviour (iPad keyboard case, etc.): plain Enter
  /// SENDS, Shift+Enter inserts a newline. On a touch soft-keyboard the
  /// newline arrives via `performAction` (not a key event), so this never
  /// fires there — the field keeps growing and the user sends with the
  /// composer button, exactly as before.
  KeyEventResult _onComposerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return KeyEventResult.ignored;
    // TEMP diag (input multiline Enter): if this line never prints when you
    // press Enter on the emulator, Android is routing it through the IME and
    // NOT as a hardware key event — remove once the behaviour is confirmed.
    debugPrint(
      '[input.enter] shift=${HardwareKeyboard.instance.isShiftPressed} '
      'disabled=${widget.disabled} streaming=${widget.streaming}',
    );
    // Don't intercept while disabled, or mid-IME-composition (a CJK
    // candidate is confirmed with Enter, not sent) — let the field/IME deal.
    if (widget.disabled || !_controller.value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      // Shift+Enter → newline. Inserted explicitly (and consumed) so the
      // behaviour is identical on every platform instead of depending on
      // the framework's default multiline key handling.
      _insertNewlineAtCursor();
      return KeyEventResult.handled;
    }
    _submit();
    return KeyEventResult.handled;
  }

  /// Replaces the current selection (or inserts at the caret) with a newline
  /// and leaves the caret right after it.
  void _insertNewlineAtCursor() {
    final value = _controller.value;
    final sel = value.selection;
    if (!sel.isValid) {
      final text = '${value.text}\n';
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      return;
    }
    final text = '${sel.textBefore(value.text)}\n${sel.textAfter(value.text)}';
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: sel.start + 1),
    );
  }

  // --- dictation toggle ------------------------------------------------------

  Future<void> _onVoiceTap() async {
    final voice = widget.voice;
    if (voice == null) {
      setState(() => _voiceUnavailable = true);
      return;
    }
    if (voice.active) {
      await voice.stopAndTranscribe();
      return;
    }
    _voicePrefix = _controller.text;
    _voiceText = _controller.text;
    await voice.startRecording();
    if (!mounted || !identical(voice, widget.voice)) return;
    final state = voice.state;
    if (state is VoiceUnavailable &&
        state.reason == VoiceUnavailableReason.permissionDenied) {
      widget.onVoiceHint?.call(VoiceHint.permissionDenied);
    }
  }

  @override
  Widget build(BuildContext context) {
    final listenables = <Listenable>[
      if (widget.voice != null) widget.voice!,
      if (widget.attachment != null) widget.attachment!,
    ];
    if (listenables.isEmpty) return _composer(context);
    // Rebuild voice feedback and attachment preview without ancestor listeners.
    return ListenableBuilder(
      listenable: Listenable.merge(listenables),
      builder: (context, _) => _composer(context),
    );
  }

  Widget _composer(BuildContext context) {
    final colors = context.colors;
    final voiceState = widget.voice?.state;
    final attachState = widget.attachment?.state;
    final canInteract = !widget.disabled;
    final hasQuickActions = widget.onOpenQuickActions != null;
    final recording = voiceState is VoiceRecording;
    final transcribing = voiceState is VoiceTranscribing;
    final starting = voiceState is VoiceStarting;
    final reconnecting = voiceState is VoiceReconnecting;
    final voiceActive = recording || transcribing || starting || reconnecting;
    final voiceUnavailable =
        voiceState is VoiceUnavailable || _voiceUnavailable;

    // Plan/30 — attachment.
    final hasImage = attachState is AttachmentAttached;
    final visionBlocked = attachState?.attachBlockedByVision ?? false;
    final hasContent = !_empty || hasImage;
    final attachEnabled =
        widget.onOpenAttach != null &&
        canInteract &&
        !widget.streaming &&
        !voiceActive &&
        !visionBlocked &&
        !hasImage;

    final showQuickActions =
        _empty &&
        !hasImage &&
        canInteract &&
        !widget.streaming &&
        !voiceActive &&
        hasQuickActions;

    // During a working turn with typed content, the main action sends steering;
    // keep a compact Stop affordance beside it so cancellation remains reachable.
    final showInlineStop =
        widget.streaming &&
        hasContent &&
        canInteract &&
        !voiceActive &&
        widget.onCancel != null;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 22),
      decoration: BoxDecoration(
        color: colors.bg,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasImage)
            _AttachmentPreview(
              image: attachState.image,
              onRemove: widget.attachment!.removeImage,
            ),
          for (final item in widget.queuedMessages)
            _QueuedMessagePreview(
              text: item.text,
              editable: item.editable,
              onTap: item.editable ? () => _editQueued(item) : null,
              onClear: item.editable
                  ? () => widget.onClearQueued?.call(item.id)
                  : null,
            ),
          Row(
            children: [
              _QuickActionsButton(
                show: showQuickActions,
                onPressed: widget.onOpenQuickActions,
              ),
              _AttachButton(enabled: attachEnabled, onTap: widget.onOpenAttach),
              const SizedBox(width: 10),
              // Text field (doubles as the image caption when one is set).
              Expanded(
                child: TextField(
                  // Intercept hardware Enter on the field's OWN focus
                  // node (the primary/leaf): plain Enter sends,
                  // Shift+Enter newlines — see _onComposerKey. Must be
                  // the leaf, not an ancestor Focus, or the multiline
                  // newline handling consumes Enter first.
                  focusNode: _focusNode,
                  controller: _controller,
                  enabled: canInteract,
                  // Grow with the content: starts at one line, expands up
                  // to 6 then scrolls internally. On a touch soft-keyboard
                  // Enter inserts a newline; sending is via the composer
                  // button (hardware Enter sends — see _onComposerKey).
                  minLines: 1,
                  maxLines: 6,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontSize: 13,
                    color: colors.text,
                  ),
                  cursorColor: colors.accent,
                  decoration: InputDecoration(
                    hintText: widget.disabled
                        ? 'Offline…'
                        : widget.streaming
                        ? 'Steer current response…'
                        : hasImage
                        ? 'Add a caption…'
                        : 'Send a message…',
                    hintStyle: TextStyle(
                      color: colors.muted,
                      fontFamily: kMonoFamily,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    filled: true,
                    fillColor: colors.inputFill,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(19),
                      borderSide: BorderSide(color: colors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(19),
                      borderSide: BorderSide(color: colors.border),
                    ),
                    disabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(19),
                      borderSide: BorderSide(
                        color: colors.border.withValues(alpha: 0.5),
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(19),
                      borderSide: BorderSide(color: colors.accent, width: 1.2),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _DictationButton(
                active: voiceActive,
                disabled: widget.disabled,
                finalizing: transcribing,
                onTap: _onVoiceTap,
              ),
              if (!voiceActive && (hasContent || widget.streaming)) ...[
                const SizedBox(width: 8),
                _ComposerActionButton(
                  cancel: widget.streaming && !hasContent,
                  disabled: widget.disabled,
                  onSendText: _submit,
                  onCancel: widget.onCancel,
                ),
              ],
              if (showInlineStop) ...[
                const SizedBox(width: 8),
                _InlineStopButton(onTap: widget.onCancel!),
              ],
            ],
          ),
          if (voiceState is VoiceFailed || voiceUnavailable)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                voiceState is VoiceUnavailable &&
                        voiceState.reason ==
                            VoiceUnavailableReason.permissionDenied
                    ? 'Microphone permission denied.'
                    : voiceUnavailable
                    ? 'Dictation unavailable.'
                    : 'Dictation failed.',
                key: const Key('dictation-feedback'),
                style: TextStyle(color: colors.muted2, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shows the message committed for auto-send after the current turn ends.
/// Tapping pulls it back into the composer for edit and cancels the pending
/// auto-send; X drops it.
class _QueuedMessagePreview extends StatelessWidget {
  const _QueuedMessagePreview({
    required this.text,
    required this.editable,
    this.onTap,
    this.onClear,
  });

  final String text;
  final bool editable;
  final VoidCallback? onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 4, bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('input-bar-queued-preview'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
            decoration: BoxDecoration(
              color: colors.accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: colors.accent.withValues(alpha: 0.35)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    LucideIcons.messageCircle,
                    size: 15,
                    color: colors.accent,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Queued',
                        style: TextStyle(
                          color: colors.accent,
                          fontFamily: kMonoFamily,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        text,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.text,
                          fontFamily: kMonoFamily,
                          fontSize: 12,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onClear != null) ...[
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: IconButton(
                      key: const Key('input-bar-clear-queued'),
                      tooltip: 'Clear queued message',
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      splashRadius: 16,
                      onPressed: onClear,
                      icon: Icon(LucideIcons.x, color: colors.muted2),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact Stop affordance shown beside Send while steering text is typed.
class _InlineStopButton extends StatelessWidget {
  const _InlineStopButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return GestureDetector(
      key: const Key('input-bar-inline-stop'),
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: colors.error.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(19),
          border: Border.all(color: colors.error.withValues(alpha: 0.55)),
        ),
        child: Icon(LucideIcons.square600, color: colors.error, size: 18),
      ),
    );
  }
}

/// Plan/30 — the attach (paperclip) button. Always visible; greyed + inert
/// when [enabled] is false (offline/streaming, a text-only model #9, or an
/// image is already attached).
class _AttachButton extends StatelessWidget {
  const _AttachButton({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        key: const Key('input-bar-attach'),
        padding: EdgeInsets.zero,
        iconSize: 18,
        splashRadius: 18,
        tooltip: 'Attach image',
        icon: Icon(
          LucideIcons.paperclip,
          color: enabled
              ? context.colors.muted2
              : context.colors.muted.withValues(alpha: 0.35),
        ),
        onPressed: enabled ? onTap : null,
      ),
    );
  }
}

/// Plan/30 — the composer image preview: a rounded thumbnail with an "X" to
/// discard before sending (decision #4).
class _AttachmentPreview extends StatelessWidget {
  const _AttachmentPreview({required this.image, required this.onRemove});

  final PickedImage image;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('attach-preview'),
      padding: const EdgeInsets.only(left: 4, bottom: 10),
      child: SizedBox(
        width: 84,
        height: 84,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(
                image.bytes,
                width: 72,
                height: 72,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            ),
            Positioned(
              top: -4,
              right: 8,
              child: GestureDetector(
                key: const Key('attach-remove'),
                onTap: onRemove,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    shape: BoxShape.circle,
                    border: Border.all(color: context.colors.border),
                  ),
                  padding: const EdgeInsets.all(3),
                  child: Icon(
                    LucideIcons.x,
                    size: 13,
                    color: context.colors.text,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickActionsButton extends StatefulWidget {
  const _QuickActionsButton({required this.show, required this.onPressed});

  final bool show;
  final VoidCallback? onPressed;

  @override
  State<_QuickActionsButton> createState() => _QuickActionsButtonState();
}

class _QuickActionsButtonState extends State<_QuickActionsButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _sizeFactor;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      value: widget.show ? 1.0 : 0.0,
    );
    // Timeline (forward = appear): first grow [0.0–0.5], then fade in [0.5–1.0].
    // On reverse (disappear) the order flips → fade out first, then shrink.
    _sizeFactor = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.5, curve: Curves.easeInOut),
    );
    _fade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.5, 1.0, curve: Curves.easeInOut),
    );
  }

  @override
  void didUpdateWidget(covariant _QuickActionsButton old) {
    super.didUpdateWidget(old);
    if (widget.show == old.show) return;
    if (widget.show) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: _sizeFactor,
      axis: Axis.horizontal,
      // -1.0 = start (centerLeft) — `alignment:` only exists on Flutter
      // ≥3.44 and breaks the 3.41 CI toolchain; drop the ignore once CI
      // moves to ≥3.44.
      // ignore: deprecated_member_use
      axisAlignment: -1.0,
      child: FadeTransition(
        opacity: _fade,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                key: const Key('input-bar-quick-actions'),
                padding: EdgeInsets.zero,
                iconSize: 18,
                splashRadius: 18,
                tooltip: 'Quick actions',
                icon: Icon(
                  LucideIcons.slidersHorizontal,
                  color: context.colors.muted,
                ),
                onPressed: widget.onPressed,
              ),
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}

/// The only dictation control, independent of the manual Send/agent Stop.
class _DictationButton extends StatelessWidget {
  const _DictationButton({
    required this.active,
    required this.disabled,
    required this.finalizing,
    required this.onTap,
  });

  final bool active;
  final bool disabled;
  final bool finalizing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final enabled = active || !disabled;
    return Semantics(
      label: active ? 'Stop dictation' : 'Start dictation',
      button: true,
      enabled: enabled && !finalizing,
      child: GestureDetector(
        key: const Key('input-bar-dictation'),
        onTap: enabled && !finalizing ? onTap : null,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: active
                ? colors.error
                : enabled
                ? colors.accent
                : colors.muted.withValues(alpha: 0.3),
            shape: BoxShape.circle,
          ),
          child: Icon(
            LucideIcons.mic600,
            color: enabled ? colors.onAccent : colors.muted,
            size: 20,
          ),
        ),
      ),
    );
  }
}

class _ComposerActionButton extends StatelessWidget {
  const _ComposerActionButton({
    required this.cancel,
    required this.disabled,
    required this.onSendText,
    required this.onCancel,
  });

  final bool cancel;
  final bool disabled;
  final VoidCallback onSendText;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return GestureDetector(
      key: const Key('input-bar-action'),
      onTap: cancel
          ? onCancel
          : disabled
          ? null
          : onSendText,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: disabled ? colors.muted.withValues(alpha: 0.3) : colors.accent,
          shape: BoxShape.circle,
          boxShadow: disabled
              ? null
              : [
                  BoxShadow(
                    color: colors.accent.withValues(alpha: 0.33),
                    blurRadius: 16,
                  ),
                ],
        ),
        child: Icon(
          cancel ? LucideIcons.square600 : LucideIcons.send600,
          color: disabled ? colors.muted : colors.onAccent,
          size: 20,
        ),
      ),
    );
  }
}
