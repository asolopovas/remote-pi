/// Tap dictation: starting → recording ↔ reconnecting → finalizing → idle/error.
sealed class VoiceInputState {
  const VoiceInputState();
}

/// Mic available and ready; nothing in flight.
final class VoiceIdle extends VoiceInputState {
  const VoiceIdle();

  @override
  bool operator ==(Object other) => other is VoiceIdle;

  @override
  int get hashCode => (VoiceIdle).hashCode;
}

/// Native capture is active; composer remains visible.
final class VoiceRecording extends VoiceInputState {
  const VoiceRecording();

  @override
  bool operator ==(Object other) => other is VoiceRecording;

  @override
  int get hashCode => (VoiceRecording).hashCode;
}

/// Capture ended; waiting for native final/done or bounded partial fallback.
final class VoiceTranscribing extends VoiceInputState {
  const VoiceTranscribing();

  @override
  bool operator ==(Object other) => other is VoiceTranscribing;

  @override
  int get hashCode => (VoiceTranscribing).hashCode;
}

/// Why voice input can't be used right now.
enum VoiceUnavailableReason {
  /// Mic / speech permission denied (decision #10) — mic stays visible, tap
  /// guides to system Settings.
  permissionDenied,

  /// No on-device recognition for any acceptable locale. The mic stays visible
  /// so an explicit tap can retry and explain availability.
  unsupported,
}

final class VoiceUnavailable extends VoiceInputState {
  const VoiceUnavailable(this.reason);

  final VoiceUnavailableReason reason;

  @override
  bool operator ==(Object other) =>
      other is VoiceUnavailable && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;
}

/// Initialization/permission is pending, not yet listening.
final class VoiceStarting extends VoiceInputState {
  const VoiceStarting();
  @override
  bool operator ==(Object other) => other is VoiceStarting;
  @override
  int get hashCode => (VoiceStarting).hashCode;
}

/// Recognition ended with an error. Already-visible words are retained.
final class VoiceFailed extends VoiceInputState {
  const VoiceFailed();
  @override
  bool operator ==(Object other) => other is VoiceFailed;
  @override
  int get hashCode => (VoiceFailed).hashCode;
}

/// The native segment ended; finalizing it or starting the next local segment.
/// The user session remains active and Stop remains available.
final class VoiceReconnecting extends VoiceInputState {
  const VoiceReconnecting();
  @override
  bool operator ==(Object other) => other is VoiceReconnecting;
  @override
  int get hashCode => (VoiceReconnecting).hashCode;
}
