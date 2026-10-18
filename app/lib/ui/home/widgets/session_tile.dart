import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/session_label.dart';
import 'package:app/ui/core/session_status_indicator.dart';
import 'package:flutter/material.dart';

export 'package:app/ui/core/session_label.dart'
    show sessionProjectName, sessionFallbackName;

/// A row in the Home list.
///
/// Observed session status uses a labelled dot, or a rotating working glyph.
/// Working takes priority over relay reconnecting, online and offline.
class SessionTile extends StatelessWidget {
  final PeerRecord peer;

  /// `true` when the room is announced live on the relay AND the
  /// relay itself is reachable. Drives the green dot.
  final bool isLive;

  /// `true` when the WS to the relay is currently retrying / down.
  /// Overrides `isLive` and renders an amber "reconnecting" dot —
  /// the app has no fresh signal on any room right now.
  final bool isReconnecting;

  /// Plan-18 follow-up — `true` when the agent in this room is
  /// currently producing a response. Highest-priority status (green spinner).
  final bool isWorking;
  final RoomInfo? room;
  final VoidCallback onOpen;

  /// Plan/tablet — `true` when this is the session shown in the tablet's
  /// detail pane. Paints the accent left-bar + faint fill from the mock.
  /// Always `false` on phone (no persistent selection there).
  final bool isSelected;

  /// Plan-17 follow-up — long-press context menu. Caller wires the
  /// dialog (rename + delete-offline). Optional; when null the tile
  /// only responds to tap.
  final VoidCallback? onLongPress;

  const SessionTile({
    super.key,
    required this.peer,
    required this.isLive,
    required this.onOpen,
    this.room,
    this.isReconnecting = false,
    this.isWorking = false,
    this.isSelected = false,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: colors.bg,
      child: InkWell(
        onTap: onOpen,
        onLongPress: onLongPress,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isSelected
                ? colors.accent.withValues(alpha: 0.06)
                : colors.bg,
            border: Border(
              left: BorderSide(
                color: isSelected ? colors.accent : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Padding(
            // Trim the left inset by the 3px accent bar so content stays
            // aligned whether selected or not.
            padding: EdgeInsets.fromLTRB(isSelected ? 15 : 18, 14, 18, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _Avatar(name: _avatarName()),
                const SizedBox(width: 14),
                Expanded(
                  child: _TitleBlock(
                    peer: peer,
                    room: room,
                    isLive: isLive,
                    isReconnecting: isReconnecting,
                    isWorking: isWorking,
                  ),
                ),
                const SizedBox(width: 12),
                SessionStatusIndicator(
                  status: SessionStatus.resolve(
                    isOnline: isLive,
                    isReconnecting: isReconnecting,
                    isWorking: isWorking,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _avatarName() => sessionDisplayName(room, peer);
}

class _TitleBlock extends StatelessWidget {
  final PeerRecord peer;
  final RoomInfo? room;
  final bool isLive;
  final bool isReconnecting;
  final bool isWorking;
  const _TitleBlock({
    required this.peer,
    required this.room,
    required this.isLive,
    required this.isReconnecting,
    required this.isWorking,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final r = room;
    final path = r?.cwd;
    final title = sessionDisplayName(r, peer);
    final status = SessionStatus.resolve(
      isWorking: isWorking,
      isReconnecting: isReconnecting,
      isOnline: isLive,
    );
    final statusLabel = status == SessionStatus.online
        ? 'Online · idle'
        : status.label;
    final sessionContext = r?.name?.isNotEmpty == true
        ? '${r!.name} · ${r.roomId.length > 8 ? r.roomId.substring(0, 8) : r.roomId}'
        : r?.roomId ?? peer.sessionName;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.typo.sansBody.copyWith(
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          path ?? 'Working directory unavailable',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.typo.monoSmall.copyWith(color: colors.muted),
        ),
        const SizedBox(height: 4),
        Text(
          sessionContext,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.typo.monoSmall.copyWith(color: colors.muted),
        ),
        const SizedBox(height: 4),
        LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                child: Text(
                  statusLabel,
                  style: context.typo.monoSmall.copyWith(
                    color: status.color(colors),
                  ),
                ),
              ),
              if (room?.model?.isNotEmpty == true)
                Flexible(
                  child: Text(
                    ' · ${_truncateModel(room!.model!)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typo.monoSmall,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

String _truncateModel(String name) =>
    name.length <= 24 ? name : '${name.substring(0, 21)}…';

class _Avatar extends StatelessWidget {
  final String name;
  const _Avatar({required this.name});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final initial = _initial(name);
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colors.surface,
        border: Border.all(color: colors.border),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: context.typo.mono.copyWith(
          color: colors.accent,
          fontSize: 16,
          height: 1,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

String _initial(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '?';
  return trimmed.characters.first.toUpperCase();
}
