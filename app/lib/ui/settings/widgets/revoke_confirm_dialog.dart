import 'package:app/pairing/storage.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Confirmation dialog shown before a peer is revoked. Returns true if the
/// user confirmed, false (or null) otherwise.
Future<bool> showRevokeConfirmDialog(
  BuildContext context, {
  required PeerRecord peer,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: ctx.colors.surface,
      title: Text(
        'Revoke "${peer.sessionName}"?',
        style: TextStyle(color: ctx.colors.text),
      ),
      content: Text(
        "You'll need to pair again from the PC or Mac to reconnect.",
        style: TextStyle(color: ctx.colors.muted2),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text('Cancel', style: TextStyle(color: ctx.colors.muted2)),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(
            'Revoke',
            style: TextStyle(color: ctx.colors.error),
          ),
        ),
      ],
    ),
  );
  return ok == true;
}
