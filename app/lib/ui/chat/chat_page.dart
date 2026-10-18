import 'dart:async';

import 'package:app/ui/core/session_status_indicator.dart';
import 'package:app/ui/agents/agents_page.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/domain/contracts/session_control_repository.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/chat/quick_actions/widgets/quick_actions_sheet.dart';
import 'package:app/ui/chat/attachment/states/attachment_state.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/states/chat_state.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/chat/widgets/attach_sheet.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:app/ui/chat/widgets/message_bubble.dart';
import 'package:app/ui/chat/widgets/streaming_bubble.dart';
import 'package:app/ui/chat/widgets/subagent_panel.dart';
import 'package:app/ui/chat/widgets/accordion_viewport.dart';
import 'package:app/ui/chat/widgets/accordion_expansion.dart';
import 'package:app/ui/chat/widgets/activity_scroll_controller.dart';
import 'package:app/ui/chat/widgets/activity_presentation.dart';
import 'package:app/ui/chat/widgets/activity_issue_notice.dart';
import 'package:app/ui/chat/widgets/tool_request_card.dart';
import 'package:app/ui/chat/widgets/extension_ui_sheet.dart';
import 'package:app/ui/core/session_label.dart';
import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/scheduler.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// Validated target connection lease, not a Stop capability.
class SessionControlsRequest {
  const SessionControlsRequest(
    this.peer,
    this.room,
    this.startedAt,
    this.isCurrent,
  );
  final String peer, room;
  final int startedAt;
  final bool Function() isCurrent;
}

class ChatPage extends StatefulWidget {
  /// Plan/24-fix-title: optional title hint passed via `go_router`
  /// `extra` from the Home tile. Used as the peer-label fallback in
  /// the AppBar so the user sees the right name *immediately* on
  /// navigation, instead of "—" / "Remote Pi" until the PeerRecord
  /// is loaded by the ViewModel and the first `room_meta_updated`
  /// arrives.
  final String? initialTitle;

  /// Plan/32g — the paired-device (Mac) label Home already knows, passed via
  /// `extra` / [SessionSelection]. Drives the AppBar's line 2 immediately so
  /// it never flickers empty/room-title while the PeerRecord loads async.
  /// When the PeerRecord arrives it resolves to the same string, so there's no
  /// visible change.
  final String? initialDevice;

  /// Plan/32g — the live state of the tile Home tapped (its green dot). Seeds
  /// the AppBar status dot so it doesn't flash "reconnecting" before the VM
  /// reads the real runtime. Superseded by the live signal once it resolves
  /// ([ChatViewModel.connectionResolved]).
  final bool initialOnline;

  /// Plan/tablet — `false` when the chat is embedded as the tablet's
  /// detail pane (no navigation stack to pop back to). Hides the back
  /// arrow; defaults to `true` for the phone full-screen route.
  final bool showBack;
  final SessionControlsRequest? controlsRequest;

  const ChatPage({
    super.key,
    this.initialTitle,
    this.initialDevice,
    this.initialOnline = false,
    this.showBack = true,
    this.controlsRequest,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  bool _subagents = false;
  bool _accordionsExpanded = false;
  int _accordionRevision = 0;
  Object? _session;
  final Set<_SessionInfoLease> _infoDialogs = {};
  bool _infoOwnerActive = true;
  bool _controlsOpened = false;

  @override
  void deactivate() {
    _infoOwnerActive = false;
    for (final lease in _infoDialogs) {
      lease.invalidate(deferNotification: true);
    }
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _infoOwnerActive = true;
  }

  @override
  void dispose() {
    // Revoke validity now; only the notification waits for the tree to unlock.
    // The route retains ownership until its overlay has actually unmounted.
    for (final lease in _infoDialogs) {
      lease.invalidate(deferNotification: true);
    }
    super.dispose();
  }

  String? get initialTitle => widget.initialTitle;
  String? get initialDevice => widget.initialDevice;
  bool get initialOnline => widget.initialOnline;
  bool get showBack => widget.showBack;

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ChatViewModel>();
    final controls = widget.controlsRequest;
    if (controls != null) vm.bindControlsLease(controls.isCurrent);
    for (final lease in _infoDialogs) {
      if (!identical(lease.vm, vm)) {
        lease.invalidate(deferNotification: true);
      }
    }
    final request = widget.controlsRequest;
    if (!_controlsOpened &&
        request != null &&
        (vm.activeRoom != null ||
            !request.isCurrent() ||
            vm.state is ChatNoPeer)) {
      _controlsOpened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !request.isCurrent() ||
            vm.activePeer?.remoteEpk != request.peer ||
            vm.activeRoom?.roomId != request.room ||
            vm.activeRoom?.startedAt != request.startedAt) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Could not open agent controls. Try again.'),
              ),
            );
          }
          return;
        }
        _showSessionInfo(context, vm, vm.activePeer!);
      });
    }
    final state = vm.state;
    final session = (vm.activePeer?.remoteEpk, vm.activePeer?.roomId);
    if (_session != session) {
      _session = session;
      _subagents = false;
      _accordionsExpanded = false;
      _accordionRevision = 0;
    }

    // ChatReady messages are already scoped by the ViewModel to this peer/room.
    // Membership is the same invocation parser used by the child panel, not
    // room presence or tool-visibility preferences.
    final hasSubagents =
        state is ChatReady &&
        state.messages.any(
          (message) =>
              message is ToolEvent &&
              SubagentInvocation.fromTool(message) != null,
        );
    if (!hasSubagents) _subagents = false;

    final scaffold = Scaffold(
      backgroundColor: context.colors.bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(context, state),
            // Pairing revocation is the only banner kept — it's a hard
            // failure (can't proceed without re-pairing), red, with an
            // explicit action. Plain offline / Pi-gone / presence-off
            // banners were removed: the AppBar status line already
            // surfaces those, and stacking duplicates noise the surface.
            if (state is ChatReady && state.pairingRevoked)
              _RevokedBanner(onRePair: () => context.go('/pair')),
            Expanded(
              child: AccordionExpansion(
                revision: _accordionRevision,
                expanded: _accordionRevision == 0 ? null : _accordionsExpanded,
                child: _buildBody(context, state, vm),
              ),
            ),
            if (hasSubagents)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('thread-toggle'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      foregroundColor: context.colors.accent,
                      backgroundColor: context.colors.surface,
                      textStyle: context.typo.monoSmall,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      shape: const StadiumBorder(),
                    ),
                    onPressed: () {
                      FocusManager.instance.primaryFocus?.unfocus();
                      setState(() => _subagents = !_subagents);
                    },
                    icon: Icon(
                      _subagents
                          ? Icons.arrow_back
                          : Icons.account_tree_outlined,
                      size: 20,
                    ),
                    label: Text(_subagents ? 'Main' : 'Sub-agents'),
                  ),
                ),
              ),
            Offstage(
              offstage: _subagents,
              child: _buildInput(context, state, vm),
            ),
          ],
        ),
      ),
    );

    // Plan/57 — an interactive extension_ui_request (ask_user via pi-ask)
    // renders as a full-screen modal layered ABOVE the Scaffold. Purely
    // reactive: the overlay leaves the tree when the pending request clears
    // (completed dismiss) — no route lifecycle to manage. `error` carries a
    // submit-result rejection so the modal can offer a retry instead of a dead
    // end.
    final ready = state is ChatReady ? state : null;
    final uiRequest = ready?.pendingUiRequest;
    if (uiRequest == null) return scaffold;
    return Stack(
      children: [
        scaffold,
        Positioned.fill(
          // Keyed by request id: a new flow must get a fresh State — question
          // ids repeat across flows (e.g. "goal"), so reusing the State would
          // leak old selections/custom text into the new modal.
          child: ExtensionUiSheet(
            key: ValueKey(uiRequest.id),
            request: uiRequest,
            error: ready?.pendingUiError,
            onRespond: vm.respondExtensionUi,
          ),
        ),
      ],
    );
  }

  Widget _buildTopBar(BuildContext context, ChatState state) {
    // Plan-17 follow-up — two-line AppBar:
    //   Line 1: synchronized desktop name (or fallback).
    //   Line 2: peer (Mac nickname or sessionName) + presence dot.
    // The dot reads from the ChatReady.peerPresence flag (which the
    // ViewModel sources from `isRoomLive`).
    final colors = context.colors;
    final vm = context.watch<ChatViewModel>();
    final peer = vm.activePeer;
    final room = vm.activeRoom;
    // Plan/32g — until the VM has read a real runtime, trust the `initialOnline`
    // hint Home passed (the tile's live dot) so the status dot doesn't flash
    // "reconnecting" on the default runtime. The live signal takes over once
    // resolved.
    final resolved = vm.connectionResolved;
    final isOnline = resolved ? vm.isRoomLive : initialOnline;
    // Plan-18 follow-up — when the chat is "offline" (WS to relay
    // down or retrying), prefer a "reconectando" amber pill so the
    // user knows it's the relay, not the Pi cwd, that's gone.
    final isReconnecting = resolved && state is ChatReady && (state).isOffline;
    // Plan-18 follow-up — when the agent is currently producing a
    // response, show "working…" instead of online/offline.
    final isWorking = vm.isWorking;
    final reading = state is ChatReady && isWorking
        ? activeActivityLabel(state.messages)
        : null;

    // Plan/24-fix-title: pass the navigation hint into the helpers so
    // either line of the AppBar (room or peer) shows it instead of
    // the generic placeholders when the ViewModel hasn't finished
    // bootstrapping yet.
    final roomName = _roomDisplayName(room, peer, state, initialTitle);
    // Plan/32g — line 2 (device) falls back to `initialDevice` (the Mac name
    // Home passed), NOT `initialTitle` (the room name) — so it shows the right
    // device from frame 1 and doesn't flip when the PeerRecord loads.
    final peerLabel = _peerDisplayName(peer, initialDevice);

    return Container(
      key: const Key('chat-toolbar'),
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: colors.bg,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          if (showBack)
            IconButton(
              icon: Icon(LucideIcons.chevronLeft, size: 18, color: colors.text),
              tooltip: 'Back',
              onPressed: () =>
                  context.canPop() ? context.pop() : context.go('/home'),
            )
          else
            const SizedBox(width: 16),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  roomName,
                  key: const Key('chat-session-title'),
                  maxLines: 1,
                  style: context.typo.mono.copyWith(
                    fontSize: 13,
                    color: colors.text,
                    letterSpacing: -0.2,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      _truncate(peerLabel, 24),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.typo.monoSmall.copyWith(
                        color: colors.muted,
                      ),
                    ),
                    Builder(
                      builder: (_) {
                        final status = SessionStatus.resolve(
                          isWorking: isWorking,
                          isReconnecting: isReconnecting,
                          isOnline: isOnline,
                        );
                        final label = switch (status) {
                          SessionStatus.working => reading ?? 'working…',
                          SessionStatus.reconnecting => 'reconnecting…',
                          _ => status.label.toLowerCase(),
                        };
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SessionStatusIndicator(status: status),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.typo.monoSmall.copyWith(
                                  color: status.color(colors),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('toggle-all-accordions'),
            tooltip: _accordionsExpanded
                ? 'Collapse all accordions'
                : 'Expand all accordions',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: Icon(
              _accordionsExpanded ? Icons.unfold_less : Icons.unfold_more,
              size: 20,
              color: colors.muted2,
            ),
            onPressed: () {
              setState(() {
                _accordionsExpanded = !_accordionsExpanded;
                ++_accordionRevision;
              });
            },
          ),
          IconButton(
            key: const Key('start-agent'),
            tooltip: 'Start agent',
            icon: Icon(LucideIcons.plus, size: 18, color: colors.accent),
            onPressed: peer != null && room != null && vm.isRoomLive
                ? () => context.push(
                    '/agents',
                    extra: AgentsTarget(
                      peer.remoteEpk,
                      room.roomId,
                      peerLabel,
                      roomName,
                      freshStart: true,
                      preferredRoom: room.roomId,
                    ),
                  )
                : null,
          ),
          // Plan/32g follow-up: ALWAYS render the info button. Gating it on the
          // async PeerRecord made it pop in on load → an AppBar layout shift
          // (the flicker the user saw). Title + device already render from the
          // nav hints, so the bar is stable from frame 1. The dialog needs the
          // loaded PeerRecord; we read it at tap time (loaded within ms of
          // mount for the connection) and no-op in the unlikely pre-load tap.
          IconButton(
            icon: Icon(LucideIcons.info, size: 18, color: colors.muted2),
            tooltip: 'Session info',
            onPressed: () {
              final p = vm.activePeer;
              if (p != null) {
                _showSessionInfo(context, vm, p);
              }
            },
          ),
        ],
      ),
    );
  }

  Future<void> _stopAgentFromInfo(
    _SessionInfoLease lease, {
    required bool Function() isCurrent,
    required VoidCallback onAccepted,
  }) async {
    if (!mounted ||
        !isCurrent() ||
        lease.stopBusy ||
        lease.readSnapshot() == null) {
      return;
    }
    lease.setStopBusy(true);
    try {
      final capability = await lease.refreshControls();
      if (!mounted || capability?.canStop != true || !isCurrent()) return;
      final snapshot = lease.readSnapshot();
      if (snapshot == null) return;
      final name = sessionDisplayName(snapshot.room, snapshot.peer);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Stop agent?'),
          content: Text(
            '$name\n\nStops this Pi process and any agents it launched. History is kept.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: dialog.colors.error,
                foregroundColor: dialog.colors.onAccent,
              ),
              onPressed: () => Navigator.of(dialog).pop(true),
              child: const Text('Stop'),
            ),
          ],
        ),
      );
      if (!mounted ||
          confirmed != true ||
          !isCurrent() ||
          lease.readSnapshot() == null) {
        return;
      }
      await lease.vm.stopSession(capability!);
      if (mounted && isCurrent() && lease.readSnapshot() != null) onAccepted();
    } on SessionControlFailure catch (error) {
      lease.reportStopError(
        error.outcomeUnknown
            ? 'Stop result unknown. Refresh sessions.'
            : error.message,
      );
    } finally {
      lease.setStopBusy(false);
    }
  }

  /// Session details dialog — surfaced from the AppBar info action.
  /// Shows the human name, the Pi-side path (cwd), the owning device,
  /// plus model/room/paired-date when known.
  Future<void> _showSessionInfo(
    BuildContext context,
    ChatViewModel vm,
    PeerRecord peer,
  ) async {
    final lease = _SessionInfoLease(
      vm,
      peer.remoteEpk,
      peer.roomId ?? 'main',
      // A dialog may build before this page rebuilds after provider replacement.
      // Never consult an inactive/deactivated page's inherited context.
      isCurrentOwner: () =>
          mounted &&
          _infoOwnerActive &&
          (widget.controlsRequest?.isCurrent() ?? true) &&
          identical(this.context.read<ChatViewModel>(), vm),
    );
    _infoDialogs.add(lease);
    var closeChat = false;
    var recoverAccess = false;
    try {
      final navigator = Navigator.of(context, rootNavigator: true);
      final route = DialogRoute<void>(
        context: context,
        themes: InheritedTheme.capture(from: context, to: navigator.context),
        barrierColor:
            DialogTheme.of(context).barrierColor ??
            Theme.of(context).dialogTheme.barrierColor ??
            Colors.black54,
        traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
        builder: (dCtx) => ListenableBuilder(
          listenable: lease,
          builder: (dCtx, _) {
            final colors = dCtx.colors;
            final snapshot = lease.readSnapshot();
            final model = snapshot?.room.model;
            final pairedAt = snapshot?.peer.pairedAt ?? '—';
            return AlertDialog(
              scrollable: false,
              backgroundColor: colors.bg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(color: colors.border),
              ),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Session info',
                      style: dCtx.typo.mono.copyWith(
                        fontSize: 15,
                        color: colors.text,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('close-session-info'),
                    tooltip: 'Close info',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      if (ModalRoute.of(dCtx)?.isCurrent == true) {
                        Navigator.of(dCtx).pop();
                      }
                    },
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: snapshot == null
                    ? Text(
                        'Session unavailable',
                        style: TextStyle(color: colors.text),
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _InfoRow(
                            label: 'Name',
                            value: sessionDisplayName(
                              snapshot.room,
                              snapshot.peer,
                              fallback: 'Remote Pi',
                            ),
                          ),
                          _InfoRow(
                            label: 'Path',
                            value: snapshot.room.cwd ?? '—',
                          ),
                          _InfoRow(
                            label: 'Owner',
                            value: _peerDisplayName(snapshot.peer, null),
                          ),
                          if (model != null && model.isNotEmpty)
                            _InfoRow(label: 'Model', value: model),
                          _InfoRow(label: 'Room', value: snapshot.room.roomId),
                          _InfoRow(
                            label: 'Paired',
                            value: pairedAt.split('T').first,
                          ),
                          if (widget.controlsRequest != null)
                            const Text(
                              'Stop the running agent before removing its local entry.',
                            ),
                          Text(
                            lease.controlsLoading
                                ? 'Checking access…'
                                : lease.stopCapability?.access?.label ??
                                      'Access unknown · Check access',
                          ),
                          if (lease.stopCapability?.launchingHost
                              case final host?)
                            _InfoRow(
                              label: 'Launching host',
                              value: '${host.roomId} · ${host.launcherId}',
                            ),
                          if (lease.stopError != null ||
                              lease.stopCapability?.access?.state ==
                                      'unlocked' &&
                                  lease.stopCapability?.canStop == false &&
                                  lease.stopCapability?.reason != null)
                            Text(
                              lease.stopError ?? lease.stopCapability!.reason!,
                              style: dCtx.typo.monoSmall.copyWith(
                                color: colors.error,
                              ),
                            ),
                        ],
                      ),
              ),
              actions: [
                if (snapshot != null && !lease.controlsLoading)
                  TextButton(
                    onPressed: lease.stopBusy
                        ? null
                        : () {
                            recoverAccess = true;
                            Navigator.of(dCtx).pop();
                          },
                    child: Text(
                      lease.stopCapability?.launchingHost != null &&
                              const [
                                'locked',
                                'expired',
                              ].contains(lease.stopCapability?.access?.state)
                          ? 'Unlock launching host'
                          : 'Check access',
                    ),
                  ),
                if (snapshot != null &&
                    !lease.controlsLoading &&
                    (lease.stopError != null ||
                        lease.stopCapability?.canStop == false &&
                            lease.stopCapability?.reason != null))
                  TextButton(
                    onPressed: lease.stopBusy
                        ? null
                        : () {
                            unawaited(lease.refreshControls());
                          },
                    child: const Text('Check status'),
                  ),
                if (snapshot != null && lease.controlsLoading)
                  const Padding(
                    padding: EdgeInsets.all(AppSpacing.sm),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                if (snapshot != null &&
                    !lease.controlsLoading &&
                    lease.stopCapability?.canStop == true)
                  TextButton.icon(
                    key: const Key('stop-session-agent'),
                    style: TextButton.styleFrom(foregroundColor: colors.error),
                    onPressed: lease.stopBusy
                        ? null
                        : () => _stopAgentFromInfo(
                            lease,
                            isCurrent: () =>
                                dCtx.mounted &&
                                ModalRoute.of(dCtx)?.isCurrent == true,
                            onAccepted: () {
                              closeChat = true;
                              Navigator.of(dCtx).pop();
                            },
                          ),
                    icon: const Icon(Icons.stop_circle_outlined, size: 18),
                    label: const Text('Stop agent'),
                  ),
              ],
            );
          },
        ),
      );
      navigator.push<void>(route);
      unawaited(lease.refreshControls());
      // The pop-result Future completes before the reverse animation. Keep the
      // lease (including page invalidation) through actual overlay teardown.
      await route.completed;
      if (recoverAccess && mounted && lease.readSnapshot() != null) {
        final captured = lease.readSnapshot()!;
        final message = await this.context.push<String>(
          '/agents',
          extra: AgentsTarget(
            captured.peer.remoteEpk,
            captured.room.roomId,
            _peerDisplayName(captured.peer, null),
            sessionDisplayName(captured.room, captured.peer),
            resolveOrigin: true,
            recoverChild: true,
          ),
        );
        if (!mounted) return;
        if (message != null) {
          ScaffoldMessenger.of(
            this.context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
        if (vm.activePeer?.remoteEpk == captured.peer.remoteEpk &&
            vm.activeRoom?.roomId == captured.room.roomId &&
            vm.activeRoom?.startedAt == captured.room.startedAt &&
            (widget.controlsRequest?.isCurrent() ?? true) &&
            vm.isRoomLive) {
          // New dialog/new lease/new inspect. The pre-navigation token is never reused.
          await _showSessionInfo(this.context, vm, captured.peer);
        }
      }
      if (closeChat && mounted && lease.readSnapshot() != null) {
        final router = GoRouter.maybeOf(this.context);
        if (router != null) {
          this.context.read<SessionSelection>().clear();
          router.go('/home');
        }
      }
    } finally {
      _infoDialogs.remove(lease);
      lease.dispose();
    }
  }

  static String _roomDisplayName(
    RoomInfo? room,
    PeerRecord? peer,
    ChatState state,
    String? initialTitle,
  ) {
    if (room != null) {
      return sessionDisplayName(room, peer, fallback: 'Remote Pi');
    }
    if (state is ChatReady && state.messages.isNotEmpty) {
      return _inferSessionName(state.messages);
    }
    // Plan/24-fix-title: Home knows the peer label before /chat
    // mounts; use it instead of the generic 'Remote Pi' placeholder
    // while we wait for the first room_meta_updated to populate
    // `room.name`.
    if (initialTitle != null && initialTitle.isNotEmpty) return initialTitle;
    return 'Remote Pi';
  }

  static String _peerDisplayName(PeerRecord? peer, String? fallback) {
    if (peer == null) {
      // Plan/32g: while the ViewModel hasn't loaded the PeerRecord yet, fall
      // back to the device label Home passed (initialDevice) — same value the
      // PeerRecord resolves to, so no flicker on load.
      if (fallback != null && fallback.isNotEmpty) return fallback;
      return '—';
    }
    if (peer.nickname != null && peer.nickname!.isNotEmpty) {
      return peer.nickname!;
    }
    if (peer.sessionName.isNotEmpty) return peer.sessionName;
    return peer.remoteEpk.substring(0, 8);
  }

  static String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max - 1)}…';

  Widget _buildBody(BuildContext context, ChatState state, ChatViewModel vm) {
    final prefs = context.watch<Preferences>();
    final hideToolCalls = prefs.hideToolCalls;
    return switch (state) {
      // Edge case: opened /chat without a peer (e.g. peer revoked while
      // user was here). The chat is not the place to pair — render
      // a minimal empty state without an action. User navigates back
      // and uses Home / Settings → pairing.
      ChatNoPeer() => const _EmptyState(
        icon: LucideIcons.messageCircle,
        message: 'No active device',
      ),
      ChatConnecting() => const _EmptyState(
        icon: LucideIcons.refreshCw,
        message: 'Connecting…',
      ),
      ChatFatalError(:final message) => _EmptyState(
        icon: LucideIcons.circleAlert,
        message: message,
        actionLabel: 'Re-pair',
        onAction: () => context.go('/pair'),
      ),
      ChatReady(:final messages, :final streaming) => () {
        final subagents = <SubagentInvocation>[];
        final mainMessages = <ChatMessage>[];
        for (final message in messages) {
          final invocation = message is ToolEvent
              ? SubagentInvocation.fromTool(message)
              : null;
          if (invocation == null) {
            if (isFeedActivity(message) &&
                (!hideToolCalls || message is! ToolEvent)) {
              mainMessages.add(message);
            }
          } else {
            subagents.add(invocation);
          }
        }
        final mainThread = _MessageList(
          key: ValueKey((vm.activePeer?.remoteEpk, vm.activePeer?.roomId)),
          messages: mainMessages,
          streaming: streaming,
          onDecide: (id, decision) => vm.approveTool(id, decision),
        );
        return IndexedStack(
          key: ValueKey((vm.activePeer?.remoteEpk, vm.activePeer?.roomId)),
          index: _subagents ? 1 : 0,
          children: [
            mainMessages.isEmpty && streaming == null
                ? const _EmptyState(
                    icon: LucideIcons.terminal,
                    message: 'No messages available',
                  )
                : mainThread,
            SubagentPanel(
              invocations: subagents,
              collapsed: prefs.collapseSubagents,
              onCollapsedChanged: prefs.setCollapseSubagents,
            ),
          ],
        );
      }(),
    };
  }

  Widget _buildInput(BuildContext context, ChatState state, ChatViewModel vm) {
    final isReady = state is ChatReady;
    final isOffline = isReady && state.isOffline;
    final isRevoked = isReady && state.pairingRevoked;
    final isPeerOffline = isReady && state.peerOfflineReason != null;
    // Live relay-reported offline (no `bye`): Pi is just not reachable.
    final isPresenceOffline = isReady && state.peerPresence is PresenceOffline;
    // Plan/31 — the composer is locked + the send button becomes "stop" for
    // the WHOLE working turn (send/echo → agent_done), not just the narrow
    // token-streaming window. Driven by the broad working signal so it matches
    // the AppBar/Home "working" indicator.
    final isWorking = isReady && vm.isWorking;
    final cancelId = vm.cancelTargetId;
    // Quick actions need an open channel to dispatch — only offer the
    // entry point when the chat input itself is enabled. Hiding the
    // ⚙ button on offline avoids a tap that would just throw inside
    // the sheet.
    final actionsEnabled =
        isReady &&
        !isOffline &&
        !isRevoked &&
        !isPeerOffline &&
        !isPresenceOffline;

    return InputBar(
      key: ValueKey((vm.activePeer?.remoteEpk, vm.activePeer?.roomId)),
      disabled:
          _subagents ||
          !isReady ||
          isOffline ||
          isRevoked ||
          isPeerOffline ||
          isPresenceOffline,
      streaming: isWorking,
      onCancel: cancelId != null ? () => vm.cancel(cancelId) : null,
      onOpenQuickActions: actionsEnabled
          ? () => showQuickActionsSheet(context)
          : null,
      queuedMessages: isReady ? state.queuedMessages : const [],
      onSetQueued: vm.queueMessage,
      onClearQueued: vm.clearQueuedMessage,
      // Plan/29 — tap-toggle voice input. The VM is route-scoped (bound in
      // app_router alongside ChatViewModel); InputBar listens to it directly,
      // so a read() is enough here.
      voice: context.read<VoiceInputViewModel>(),
      onVoiceHint: (hint) => _handleVoiceHint(context, hint),
      // Plan/30 — image attachments. takeImageForSend() reads + clears the
      // attached image so the inline image rides along with the (optionally
      // empty) caption. Attach-button gating by vision / already-attached is
      // internal to InputBar; the host only gates by channel availability.
      attachment: context.read<AttachmentViewModel>(),
      onOpenAttach: actionsEnabled
          ? () => _openAttach(context, context.read<AttachmentViewModel>())
          : null,
      onSend: (text) {
        final image = context.read<AttachmentViewModel>().takeImageForSend();
        vm.sendMessage(text, image: image);
      },
    );
  }

  /// Open the Camera/Gallery sheet and drive the picker. Captures the
  /// messenger up front so a permission-denied hint can deep-link to Settings
  /// after the async pick.
  static Future<void> _openAttach(
    BuildContext context,
    AttachmentViewModel vm,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final source = await showAttachSheet(context);
    if (source == null) return;
    AttachHint? hint;
    final sub = vm.hints.listen((h) => hint = h);
    switch (source) {
      case AttachSource.camera:
        await vm.pickFromCamera();
      case AttachSource.gallery:
        await vm.pickFromGallery();
    }
    await Future<void>.delayed(Duration.zero); // flush the hint microtask
    await sub.cancel();
    if (hint != null) _handleAttachHint(messenger, hint!);
  }

  static void _handleAttachHint(
    ScaffoldMessengerState messenger,
    AttachHint hint,
  ) {
    messenger.hideCurrentSnackBar();
    switch (hint) {
      case AttachHint.cameraPermissionDenied:
        messenger.showSnackBar(
          SnackBar(
            content: const Text(
              'Camera access is off — enable it in Settings to attach a photo.',
            ),
            duration: const Duration(seconds: 5),
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: 'Settings',
              onPressed: AppSettings.openAppSettings,
            ),
          ),
        );
      case AttachHint.pickFailed:
        messenger.showSnackBar(
          const SnackBar(
            content: Text("Couldn't attach that image."),
            duration: Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  /// Surfaces microphone permission guidance as a snackbar. Captures the messenger up front
  /// so the settings deep-link is safe across the async permission round-trip.
  static void _handleVoiceHint(BuildContext context, VoiceHint hint) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    switch (hint) {
      case VoiceHint.permissionDenied:
        messenger.showSnackBar(
          SnackBar(
            content: const Text('Microphone permission denied.'),
            duration: const Duration(seconds: 5),
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: 'Settings',
              onPressed: AppSettings.openAppSettings,
            ),
          ),
        );
    }
  }

  static String _inferSessionName(List<ChatMessage> msgs) {
    for (final m in msgs) {
      if (m is UserMsg) return m.text.substring(0, m.text.length.clamp(0, 32));
    }
    return 'Remote Pi';
  }
}

// ---------------------------------------------------------------------------

class _MessageList extends StatefulWidget {
  final List<ChatMessage> messages;
  final StreamingMessage? streaming;
  final void Function(String, ApproveDecision) onDecide;

  const _MessageList({
    super.key,
    required this.messages,
    required this.streaming,
    required this.onDecide,
  });

  @override
  State<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<_MessageList> {
  final _scroll = ActivityScrollController();
  final _rowAnchors = <Key, GlobalKey>{};
  bool _awayFromBottom = false;
  bool _newActivity = false;

  @override
  void didUpdateWidget(_MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed =
        widget.messages.length != oldWidget.messages.length ||
        widget.streaming != oldWidget.streaming ||
        !listEquals(widget.messages, oldWidget.messages);
    if (!changed) return;
    _scroll.preserve(_rowAnchors.values);
    if (_scroll.hasClients && _scroll.offset > 1) {
      _newActivity = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scroll.releaseAnchor();
    });
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    final away = _scroll.hasClients && _scroll.offset > 1;
    if (away != _awayFromBottom || (!away && _newActivity)) {
      setState(() {
        _awayFromBottom = away;
        if (!away) _newActivity = false;
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messages = activityRows(widget.messages);
    final streaming = widget.streaming;
    final offset = streaming == null ? 1 : 2;
    // IDs are scoped to a message role: user and assistant share a request
    // ID, and history can contain multiple assistant segments for that ID.
    // Keep every row distinct so sliver remapping never aliases two children.
    final occurrences = <(Type, String), int>{};
    final keys = <Key>[];
    for (final message in messages) {
      final identity = (message.runtimeType, message.id);
      final occurrence = occurrences[identity] ?? 0;
      occurrences[identity] = occurrence + 1;
      keys.add(ValueKey((identity.$1, identity.$2, occurrence)));
    }
    final streamingKey = streaming == null
        ? null
        : ValueKey((StreamingMessage, streaming.inReplyTo, 0));
    final indices = <Key, int>{
      for (var i = 0; i < keys.length; i++)
        keys[i]: messages.length - 1 - i + offset,
    };
    if (streamingKey != null) indices[streamingKey] = 1;
    _rowAnchors.removeWhere((key, _) => !indices.containsKey(key));
    for (final key in indices.keys) {
      _rowAnchors.putIfAbsent(key, GlobalKey.new);
    }
    return AccordionViewport(
      controller: _scroll,
      reverse: true,
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _onScroll();
          });
          return false;
        },
        child: Stack(
          children: [
            ListView.separated(
              controller: _scroll,
              reverse: true,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              itemCount: messages.length + offset,
              separatorBuilder: (context, idx) => const SizedBox(height: 8),
              // This callback takes item indices; ListView handles separators.
              findItemIndexCallback: (key) => indices[key],
              itemBuilder: (_, i) {
                if (i == 0) return const AccordionEdgeSpace();
                if (streaming != null && i == 1) {
                  return KeyedSubtree(
                    key: streamingKey,
                    child: ActivityRow(
                      key: _rowAnchors[streamingKey],
                      child: StreamingBubble(streaming),
                    ),
                  );
                }
                final messageIndex = messages.length - 1 - (i - offset);
                final msg = messages[messageIndex];
                return KeyedSubtree(
                  key: keys[messageIndex],
                  child: ActivityRow(
                    key: _rowAnchors[keys[messageIndex]],
                    child: switch (msg) {
                      UserMsg() => UserBubble(msg),
                      AssistantMsg() => AssistantBubble(msg),
                      ToolEvent() =>
                        isRoutineActivity(msg)
                            ? ActivityIssueNotice(tool: msg)
                            : ToolRequestCard(
                                tool: msg,
                                onDecide: widget.onDecide,
                              ),
                      CompactionMsg() => CompactionBubble(msg),
                    },
                  ),
                );
              },
            ),
            if ((_awayFromBottom || _newActivity) &&
                _scroll.hasClients &&
                _scroll.offset > 1)
              Positioned(
                bottom: 8,
                right: 16,
                child: Tooltip(
                  message: 'Scroll to latest message',
                  excludeFromSemantics: true,
                  child: FilledButton.tonalIcon(
                    key: const Key('scroll-to-latest'),
                    style: FilledButton.styleFrom(
                      foregroundColor: context.colors.accent,
                      backgroundColor: context.colors.surface,
                    ),
                    onPressed: () {
                      _scroll.releaseAnchor();
                      if (MediaQuery.disableAnimationsOf(context)) {
                        _scroll.jumpTo(0);
                      } else {
                        _scroll.animateTo(
                          0,
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                        );
                      }
                    },
                    label: Text(_newActivity ? 'New activity' : 'Latest'),
                    icon: const Icon(
                      Icons.keyboard_arrow_down,
                      size: 24,
                      semanticLabel: 'Scroll to latest message',
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

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _EmptyState({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: colors.muted, size: 48),
          const SizedBox(height: 16),
          Text(message, style: TextStyle(color: colors.muted, fontSize: 14)),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 24),
            FilledButton(
              onPressed: onAction,
              style: FilledButton.styleFrom(
                backgroundColor: colors.accent,
                foregroundColor: colors.onAccent,
              ),
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

class _RevokedBanner extends StatelessWidget {
  final VoidCallback onRePair;
  const _RevokedBanner({required this.onRePair});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.red.shade900.withValues(alpha: 0.85),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(LucideIcons.unlink, color: Colors.white, size: 15),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Pairing revoked by Mac — re-pair to continue',
              style: TextStyle(
                fontSize: 12,
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          GestureDetector(
            onTap: onRePair,
            child: const Text(
              'Re-pair',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One info action's exact VM/peer/room lease, never a selection-following view.
class _SessionInfoLease extends ChangeNotifier with WidgetsBindingObserver {
  _SessionInfoLease(
    this.vm,
    this.peerEpk,
    this.roomId, {
    required this.isCurrentOwner,
  }) {
    if (readSnapshot() != null) vm.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
  }

  final ChatViewModel vm;
  final String peerEpk;
  final String roomId;
  final bool Function() isCurrentOwner;
  bool _valid = true;
  bool _disposed = false;
  bool _notificationPending = false;
  int _controlsRevision = 0;
  int? _roomStartedAt;
  bool controlsLoading = false, stopBusy = false;
  Timer? _accessTimer;
  SessionStopCapability? stopCapability;
  String? stopError;

  Future<SessionStopCapability?> refreshControls() async {
    if (_disposed || readSnapshot() == null) return null;
    final revision = ++_controlsRevision;
    controlsLoading = true;
    stopCapability = null;
    stopError = null;
    _notify();
    try {
      final capability = await vm.inspectSessionStop(peerEpk, roomId);
      if (_disposed ||
          revision != _controlsRevision ||
          readSnapshot() == null) {
        return null;
      }
      if (capability.peer != peerEpk || capability.room != roomId) return null;
      stopCapability = capability;
      _accessTimer?.cancel();
      final expires = capability.access?.expiresAt;
      final remaining =
          capability.access?.state != 'unlocked' || expires == null
          ? 30000
          : expires - DateTime.now().millisecondsSinceEpoch;
      _accessTimer = Timer(
        Duration(milliseconds: remaining.clamp(0, 30000)),
        () {
          stopCapability = null;
          stopError = 'Access snapshot stale. Check access.';
          _notify();
        },
      );
      return capability;
    } on SessionControlFailure catch (error) {
      if (!_disposed &&
          revision == _controlsRevision &&
          readSnapshot() != null) {
        stopCapability = null;
        stopError = error.message;
      }
      return null;
    } finally {
      if (!_disposed && revision == _controlsRevision) {
        controlsLoading = false;
        _notify();
      }
    }
  }

  void setStopBusy(bool value) {
    if (_disposed) return;
    stopBusy = value;
    _notify();
  }

  void reportStopError(String message) {
    if (_disposed) return;
    stopError = message;
    stopCapability = null;
    _notify();
  }

  ({PeerRecord peer, RoomInfo room})? readSnapshot() {
    if (_disposed || !_valid) return null;
    if (!isCurrentOwner()) {
      invalidate(deferNotification: true);
      return null;
    }
    // Getters can change before the VM publishes a notification. Validate the
    // one snapshot used by this build before accessing any metadata fields.
    final peer = vm.activePeer;
    final room = vm.activeRoom;
    if (peer == null ||
        peer.remoteEpk != peerEpk ||
        (peer.roomId ?? 'main') != roomId ||
        room == null ||
        room.roomId != roomId ||
        _roomStartedAt != null && room.startedAt != _roomStartedAt) {
      invalidate(deferNotification: true);
      return null;
    }
    _roomStartedAt ??= room.startedAt;
    return (peer: peer, room: room);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && !_disposed) {
      ++_controlsRevision;
      controlsLoading = false;
      stopCapability = null;
      stopError = 'Access snapshot stale. Check access.';
      _notify();
    }
  }

  void _changed() {
    if (!vm.isRoomLive) {
      ++_controlsRevision;
      controlsLoading = false;
      stopCapability = null;
      stopError = 'Session offline. Check status.';
    }
    if (readSnapshot() != null) _notify();
  }

  void invalidate({bool deferNotification = false}) {
    if (_disposed || !_valid) return;
    _valid = false;
    vm.removeListener(_changed);
    _notify(deferNotification: deferNotification);
  }

  void _notify({bool deferNotification = false}) {
    if (_disposed) return;
    if (deferNotification ||
        SchedulerBinding.instance.schedulerPhase ==
            SchedulerPhase.persistentCallbacks) {
      if (_notificationPending) return;
      _notificationPending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _notificationPending = false;
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _accessTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _valid = false;
    vm.removeListener(_changed);
    super.dispose();
  }
}

/// One labelled key/value row in the session-info dialog. The value is
/// selectable so the user can copy the path / device name.
class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontFamily: kMonoFamily,
              fontSize: 10,
              color: colors.muted,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: TextStyle(
              fontFamily: kMonoFamily,
              fontSize: 13,
              color: colors.text,
            ),
          ),
        ],
      ),
    );
  }
}
