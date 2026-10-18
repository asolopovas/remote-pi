import 'package:app/ui/agents/agents_page.dart';
import 'package:app/ui/chat/chat_page.dart' show SessionControlsRequest;
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart' show RoomInfo;
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/session_label.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/settings/settings_sheet.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/home/widgets/widgets.dart';
import 'package:app/ui/update/widgets/update_banner.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// Plan-18 follow-up — iOS-style large title that collapses into a
/// compact bar when scrolled. Built with `SliverAppBar +
/// FlexibleSpaceBar`. Subtitle shows the first paired Mac + relay
/// status. Body is sectioned by pairing always (single peer also
/// gets the pairing header, per the mock).
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final vm = context.watch<HomeViewModel>();
    final state = vm.state;

    // Plan/tablet — tell the adaptive shell whether Home has anything to
    // list. On a zero-state (no Pi paired / empty list) the shell drops
    // the two-pane split and shows this page full-width + centered. Done
    // post-frame so we never notify mid-build.
    final isZeroState = switch (state) {
      HomeLoading() => false,
      HomeNoPeer() => true,
      HomeList() => state.items(normalizeEpk: toStandardB64).isEmpty,
    };
    final shell = context.read<ShellLayout>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      shell.setZeroState(isZeroState);
    });

    return Scaffold(
      backgroundColor: colors.bg,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            _buildLargeTitleBar(context, vm, state),
            // Plan 44 — Android-only update notice. Sits at the top of the
            // scroll content (below the title, above the list); shrinks to
            // zero height when there's nothing to announce, so it's invisible
            // on iOS and when no newer version exists.
            const SliverToBoxAdapter(child: UpdateBanner()),
            switch (state) {
              HomeLoading() => SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: CircularProgressIndicator(color: colors.accent),
                ),
              ),
              HomeNoPeer() => const SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyState(),
              ),
              HomeList() => _buildListSlivers(context, vm, state),
            },
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Large title (iOS-style)
  // ---------------------------------------------------------------------------

  Widget _buildLargeTitleBar(
    BuildContext context,
    HomeViewModel vm,
    HomeState state,
  ) {
    final colors = context.colors;
    final subtitle = _subtitleFor(context, vm, state);
    const maxExpanded = 124.0;
    return SliverAppBar(
      backgroundColor: colors.bg,
      surfaceTintColor: colors.bg,
      elevation: 0,
      scrolledUnderElevation: 0,
      pinned: true,
      stretch: false,
      expandedHeight: maxExpanded,
      collapsedHeight: 56,
      toolbarHeight: 56,
      automaticallyImplyLeading: false,
      actions: [
        IconButton(
          tooltip: 'Refresh relay',
          icon: Icon(LucideIcons.refreshCw, color: colors.muted2),
          onPressed: vm.isRelayConnected ? vm.refreshRelay : null,
        ),
        IconButton(
          tooltip: 'Start agent',
          icon: Icon(LucideIcons.plus, color: colors.accent),
          onPressed: () => _chooseLauncher(context, vm, state),
        ),
        IconButton(
          tooltip: 'Settings',
          icon: Icon(LucideIcons.settings, color: colors.muted2),
          // Tablet → bottom sheet (keeps the chat in context); phone →
          // full-screen push. See openSettings.
          onPressed: () => openSettings(context),
        ),
        const SizedBox(width: 4),
      ],
      // Title rendering happens entirely inside flexibleSpace so we
      // can cross-fade between the large form (expanded) and the
      // compact form (collapsed). Using `SliverAppBar.title` here
      // would overlay the compact title on top of the large one
      // while expanded — that was the "two app bars" bug.
      flexibleSpace: LayoutBuilder(
        builder: (ctx, constraints) {
          final maxH = constraints.maxHeight;
          const minH = 56.0;
          // t=1 → fully expanded; t=0 → fully collapsed.
          final t = ((maxH - minH) / (maxExpanded - minH)).clamp(0.0, 1.0);
          return Stack(
            fit: StackFit.expand,
            children: [
              Container(color: colors.bg),
              // Large title block — fades OUT as we collapse.
              Positioned(
                left: 20,
                right: 20,
                bottom: 8,
                child: IgnorePointer(
                  ignoring: t < 0.05,
                  child: Opacity(
                    opacity: t,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Remote Pi',
                          style: brandTextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w700,
                            color: colors.text,
                            letterSpacing: -0.5,
                            height: 1.05,
                          ),
                        ),
                        const SizedBox(height: 6),
                        subtitle,
                      ],
                    ),
                  ),
                ),
              ),
              // Compact title — fades IN as we collapse.
              Positioned(
                left: 20,
                right: 160, // reserve Refresh, Start agent and Settings actions
                top: 0,
                height: 56,
                child: IgnorePointer(
                  ignoring: t > 0.95,
                  child: Opacity(
                    opacity: 1 - t,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Remote Pi',
                        style: brandTextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: colors.text,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Bottom divider — only shows once collapsed.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Opacity(
                  opacity: 1 - t,
                  child: Divider(color: colors.border, height: 1, thickness: 1),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Subtitle line under "Remote Pi": ● Relay · [Connected|Awaiting pairing|Offline].
  /// Reflects the app→relay WS state (not per-Pi presence) so the
  /// user always knows whether the app itself is reachable.
  ///
  /// `HomeNoPeer` is the special case where no peer is paired yet —
  /// the WS is never opened (its URL embeds the destination peer's
  /// pubkey), so `isRelayConnected` is false but that doesn't mean
  /// the relay is down. Render a neutral "Awaiting pairing" instead
  /// of the alarming amber "Offline".
  Widget _subtitleFor(BuildContext context, HomeViewModel vm, HomeState state) {
    final colors = context.colors;
    final connected = vm.isRelayConnected;
    final awaitingPairing = state is HomeNoPeer;
    final Color dotColor;
    final String statusLabel;
    final Color statusColor;
    if (connected) {
      dotColor = colors.success;
      statusLabel = 'Connected';
      statusColor = colors.muted;
    } else if (awaitingPairing) {
      dotColor = colors.muted;
      statusLabel = 'Awaiting pairing';
      statusColor = colors.muted;
    } else {
      dotColor = colors.warning;
      statusLabel = 'Offline';
      statusColor = colors.warning;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
        ),
        const SizedBox(width: 8),
        Text(
          'Relay',
          style: TextStyle(
            fontFamily: kMonoFamily,
            color: colors.text,
            fontSize: 13,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '·',
          style: TextStyle(
            fontFamily: kMonoFamily,
            color: colors.muted,
            fontSize: 13,
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            statusLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: kMonoFamily,
              color: statusColor,
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // List body
  // ---------------------------------------------------------------------------

  Widget _buildListSlivers(
    BuildContext context,
    HomeViewModel vm,
    HomeList state,
  ) {
    final counts = vm.counts;
    // Globally empty (paired Pi, no rooms at all): keep the original lonely
    // state and DON'T show the tabs — there's nothing to filter.
    if (counts.all == 0) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: _LonelyEmptyState(),
      );
    }

    // Plan-38 Fase 3 — presence filter at the top of the list. Pure view:
    // tapping a tab only swaps `state.filter` → `vm.visibleItems` re-derives.
    final tabs = SliverToBoxAdapter(
      child: Column(
        children: [
          HomeFilterTabs(
            filter: state.filter,
            counts: counts,
            onSelected: vm.setFilter,
          ),
          if (state.filter == HomeFilter.all)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: const Key('clear-inactive-sessions'),
                  onPressed: vm.canClearInactive
                      ? () => _clearInactive(context, vm)
                      : null,
                  icon: const Icon(LucideIcons.trash2, size: 16),
                  label: const Text('Clear inactive'),
                ),
              ),
            ),
        ],
      ),
    );

    final visible = vm.visibleItems;
    if (visible.isEmpty) {
      // Items exist, but none match this tab → per-tab empty state beneath
      // the tabs (which stay visible so the user can switch back).
      return SliverMainAxisGroup(
        slivers: [
          tabs,
          SliverFillRemaining(
            hasScrollBody: false,
            child: HomeFilterEmptyState(filter: state.filter),
          ),
        ],
      );
    }

    // Build the per-peer groups over the VISIBLE items: each group is
    // [header, tile, tile, …]. Plan-18 follow-up — always include a header
    // even when there's a single Mac, per the mock. A peer with no visible
    // item in this filter contributes no header (the `lastEpk` cursor only
    // advances on rows we actually render).
    final children = <Widget>[];
    String? lastEpk;
    for (final it in visible) {
      if (it.peer.remoteEpk != lastEpk) {
        children.add(PeerSectionHeader(peer: it.peer));
        lastEpk = it.peer.remoteEpk;
      }
      children.add(_buildItemRowAt(context, vm, state, it));
    }
    return SliverMainAxisGroup(
      slivers: [
        tabs,
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(0, 0, 0, 24),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (ctx, i) => children[i],
              childCount: children.length,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildItemRowAt(
    BuildContext context,
    HomeViewModel vm,
    HomeList state,
    HomeItem it,
  ) {
    final colors = context.colors;
    final isLive = vm.isRoomLive(it.peer.remoteEpk, it.room.roomId);
    final isReconnecting = !vm.isRelayConnected;
    final isWorking = vm.isRoomWorking(it.peer.remoteEpk, it.room.roomId);
    // Plan/tablet — highlight the open session, but only in the two-pane
    // layout (on phone the list is covered by the pushed chat, so a
    // persistent highlight would be meaningless).
    final isSelected =
        isWideLayout(context) &&
        context.watch<SessionSelection>().matches(
          it.peer.remoteEpk,
          it.room.roomId,
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SessionTile(
          peer: it.peer,
          isLive: isLive,
          isReconnecting: isReconnecting,
          isWorking: isWorking,
          isSelected: isSelected,
          room: it.room,
          onOpen: () => _open(context, vm, it.peer, it.room),
          onLongPress: () => _showSessionMenu(context, vm, it, isLive: isLive),
        ),
        Divider(color: colors.border, height: 1),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Long-press menu (preserved from prior plan-17 wiring)
  // ---------------------------------------------------------------------------

  Future<void> _chooseLauncher(
    BuildContext context,
    HomeViewModel vm,
    HomeState state,
  ) async {
    final machines = vm.launchMachines;
    if (machines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No online paired machines. Check status.'),
        ),
      );
      return;
    }
    // An existing chat selection is never an implicit choice among machines.
    final machine = machines.length == 1
        ? machines.single
        : await Navigator.of(context).push<List<HomeItem>>(
            MaterialPageRoute(
              builder: (picker) => Scaffold(
                appBar: AppBar(title: const Text('Choose launch host')),
                body: ListView(
                  children: [
                    for (final group in machines)
                      ListTile(
                        title: Text(_deviceFor(group.first.peer)),
                        subtitle: Text(
                          toStandardB64(group.first.peer.remoteEpk),
                        ),
                        onTap: () => Navigator.of(picker).pop(group),
                      ),
                  ],
                ),
              ),
            ),
          );
    if (!context.mounted || machine == null) return;
    final selection = context.read<SessionSelection>();
    final preferred = machine
        .where(
          (item) => selection.matches(item.peer.remoteEpk, item.room.roomId),
        )
        .firstOrNull;
    final target = machine.first;
    context.push(
      '/agents',
      extra: AgentsTarget(
        target.peer.remoteEpk,
        target.room.roomId,
        _deviceFor(target.peer),
        'Checking status…',
        freshStart: true,
        preferredRoom: preferred?.room.roomId,
      ),
    );
  }

  Future<void> _clearInactive(BuildContext context, HomeViewModel vm) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Clear inactive sessions?'),
        content: const Text('Removes offline entries from this device only.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (!context.mounted || confirmed != true) return;
    try {
      await vm.clearInactiveRooms();
    } on Exception {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not clear inactive sessions.')),
      );
    }
  }

  void _showSessionMenu(
    BuildContext context,
    HomeViewModel vm,
    HomeItem it, {
    required bool isLive,
  }) {
    final selection = context.read<SessionSelection>();
    final revision = selection.revision;
    final roomCurrent = vm.roomActionGuard(it);
    bool current() =>
        context.mounted && selection.revision == revision && roomCurrent();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.colors.bg,
      builder: (sheetCtx) {
        final colors = sheetCtx.colors;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(LucideIcons.pencil, color: colors.accent),
                title: Text(
                  'Mobile alias',
                  style: TextStyle(color: colors.text),
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _promptRename(context, vm, it);
                },
              ),
              ListTile(
                leading: Icon(
                  isLive ? LucideIcons.info : LucideIcons.trash2,
                  color: isLive ? colors.accent : colors.error,
                ),
                title: Text(isLive ? 'Agent controls…' : 'Remove from list…'),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  if (!current()) {
                    _feedback(context, 'Session changed. Open the menu again.');
                    return;
                  }
                  if (isLive) {
                    _openControls(
                      context,
                      vm,
                      it,
                      () => context.mounted && selection.revision == revision,
                    );
                  } else {
                    _confirmDelete(context, vm, it, current);
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _promptRename(
    BuildContext context,
    HomeViewModel vm,
    HomeItem it,
  ) async {
    final controller = TextEditingController(text: it.room.localName ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (dCtx) {
        final colors = dCtx.colors;
        return AlertDialog(
          backgroundColor: colors.bg,
          title: Text('Mobile alias', style: TextStyle(color: colors.text)),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: TextStyle(color: colors.text, fontFamily: kMonoFamily),
            decoration: InputDecoration(
              hintText: 'Empty uses project fallback',
              helperText: 'Saved fallback when no desktop name is available',
              helperMaxLines: 3,
              helperStyle: TextStyle(color: colors.muted),
              hintStyle: TextStyle(color: colors.muted),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: colors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: colors.accent),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dCtx).pop(null),
              child: Text('Cancel', style: TextStyle(color: colors.muted)),
            ),
            TextButton(
              onPressed: () => Navigator.of(dCtx).pop(controller.text.trim()),
              child: Text('Save', style: TextStyle(color: colors.accent)),
            ),
          ],
        );
      },
    );
    if (result == null) return;
    await vm.renameRoom(it.peer.remoteEpk, it.room.roomId, result);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    HomeViewModel vm,
    HomeItem it,
    bool Function() current,
  ) async {
    if (!vm.isRelayConnected) {
      _feedback(context, 'Status unknown. Reconnect before removing.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) {
        final colors = dCtx.colors;
        return AlertDialog(
          backgroundColor: colors.bg,
          title: Text(
            'Remove from list?',
            style: TextStyle(color: colors.text),
          ),
          content: Text(
            'Removes this device’s entry only. History and pairing are kept. '
            'A running agent must be stopped first; online sessions reappear.',
            style: TextStyle(color: colors.muted, fontSize: 12),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dCtx).pop(false),
              child: Text('Cancel', style: TextStyle(color: colors.muted)),
            ),
            TextButton(
              onPressed: () => Navigator.of(dCtx).pop(true),
              child: Text('Remove', style: TextStyle(color: colors.error)),
            ),
          ],
        );
      },
    );
    if (!context.mounted || ok != true) return;
    if (!current()) {
      _feedback(context, 'Session changed. Open the menu again.');
      return;
    }
    try {
      final removed = await vm.deleteRoom(
        it.peer.remoteEpk,
        it.room.roomId,
        isCurrent: current,
      );
      if (!context.mounted) return;
      _feedback(
        context,
        removed
            ? 'Removed from list.'
            : 'Not removed. Status or session changed; check agent controls.',
      );
    } on Exception {
      if (!context.mounted) return;
      _feedback(context, 'Could not remove session. Try again.');
    }
  }

  static void _feedback(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openControls(
    BuildContext context,
    HomeViewModel vm,
    HomeItem item,
    bool Function() current,
  ) async {
    try {
      final lease = await vm.openControls(item, isCurrent: current);
      if (!context.mounted) return;
      if (!lease()) {
        _feedback(context, 'Session changed. Open the menu again.');
        return;
      }
      // Dedicated chat route on both form factors; never borrow the detail
      // pane's controls or an access token from another selection.
      context.push(
        '/chat',
        extra: {
          'title': _titleFor(item.peer, item.room),
          'device': _deviceFor(item.peer),
          'online': true,
          'controls': SessionControlsRequest(
            item.peer.remoteEpk,
            item.room.roomId,
            item.room.startedAt,
            lease,
          ),
        },
      );
    } on Exception {
      if (!context.mounted) return;
      _feedback(context, 'Could not open agent controls. Try again.');
    }
  }

  static Future<void> _open(
    BuildContext context,
    HomeViewModel vm,
    PeerRecord peer,
    RoomInfo room,
  ) async {
    // Sets prefs (selectedPeerEpk + room) + switchRoom so a fresh
    // ChatViewModel binds to this session.
    await vm.openSession(peer.remoteEpk, roomId: room.roomId);
    if (!context.mounted) return;
    final title = _titleFor(peer, room);
    // Plan/32g — the device (Mac) name we already know here. The Chat AppBar's
    // line 2 renders this immediately instead of flickering empty/room-title
    // until the PeerRecord loads async.
    final device = _deviceFor(peer);
    // Plan/32g — the live state of this tile (the green dot). Passed so the
    // Chat AppBar's status dot starts correct instead of flashing
    // "reconnecting" before the runtime is read.
    final online = vm.isRoomLive(peer.remoteEpk, room.roomId);
    // Mark the UI selection — drives the tablet detail pane AND the
    // highlighted tile. Set AFTER openSession so the detail's fresh
    // ChatViewModel reads the already-updated prefs.
    context.read<SessionSelection>().select(
      peer.remoteEpk,
      room.roomId,
      title,
      device,
      online,
    );
    // Phone: full-screen chat (root push → native back/swipe). Tablet:
    // the detail pane reacts to the selection above — no nav needed.
    if (!isWideLayout(context)) {
      context.push(
        '/chat',
        extra: {'title': title, 'device': device, 'online': online},
      );
    }
  }

  /// Plan/32g — the paired-device label for the Chat AppBar's line 2
  /// (nickname → sessionName → epk prefix). Mirrors [ChatPage]'s own peer
  /// resolution so there's no change when the PeerRecord finishes loading.
  static String _deviceFor(PeerRecord peer) =>
      (peer.nickname?.isNotEmpty ?? false)
      ? peer.nickname!
      : peer.sessionName.isNotEmpty
      ? peer.sessionName
      : peer.remoteEpk.substring(0, 8);

  /// Plan/24-fix-title: the peer/room label we already know here, so the
  /// Chat AppBar doesn't show '—' / 'Remote Pi' until the ChatViewModel
  /// loads the PeerRecord and exact-room metadata. Uses the shared resolver.
  static String _titleFor(PeerRecord peer, RoomInfo room) =>
      sessionDisplayName(room, peer);
}

/// Plan-17 follow-up — soft empty state for paired-but-no-rooms.
class _LonelyEmptyState extends StatelessWidget {
  const _LonelyEmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
        child: Opacity(
          opacity: 0.35,
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.moon, color: colors.muted, size: 56),
                const SizedBox(height: 18),
                Text(
                  'Nothing here…',
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    color: colors.muted2,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'When a paired Pi opens a session, it shows up here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    color: colors.muted,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.scanQrCode, color: colors.muted, size: 48),
              const SizedBox(height: 16),
              Text(
                'No pairings yet',
                style: TextStyle(color: colors.muted2, fontSize: 14),
              ),
              const SizedBox(height: 6),
              Text(
                'Scan a QR from your Mac to start.',
                style: TextStyle(color: colors.muted, fontSize: 12),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => context.push('/pair'),
                style: FilledButton.styleFrom(
                  backgroundColor: colors.accent,
                  foregroundColor: colors.onAccent,
                ),
                icon: const Icon(LucideIcons.scanQrCode, size: 18),
                label: const Text('Scan QR'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
