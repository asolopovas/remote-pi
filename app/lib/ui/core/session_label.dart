import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';

/// Presentation only: display authority is ephemeral and accepted by data.
/// Neither desktop nor mobile labels are routing or history identities.
String sessionDisplayName(
  RoomInfo? room,
  PeerRecord? peer, {
  String fallback = 'Session',
}) {
  final desktop = room?.display?.name;
  if (desktop != null && desktop.trim().isNotEmpty) return desktop;
  final local = room?.localName;
  if (local != null && local.trim().isNotEmpty) return local;
  final project = sessionProjectName(room?.cwd);
  if (project != null) return project;
  return sessionFallbackName(room, peer, fallback: fallback);
}

String? sessionProjectName(String? path) {
  if (path == null || path.trim().isEmpty) return null;
  final normalized = path
      .replaceAll('\\', '/')
      .replaceFirst(RegExp(r'/+$'), '');
  if (normalized.isEmpty) return path;
  return normalized.split('/').last;
}

String sessionFallbackName(
  RoomInfo? room,
  PeerRecord? peer, {
  String fallback = 'Session',
}) {
  if (room?.name?.isNotEmpty == true) return room!.name!;
  if (peer?.nickname?.isNotEmpty == true) return peer!.nickname!;
  if (peer?.sessionName.isNotEmpty == true) return peer!.sessionName;
  if (room?.roomId.isNotEmpty == true) return room!.roomId;
  return fallback;
}
