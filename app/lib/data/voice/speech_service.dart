import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:app/domain/contracts/contracts.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Local speech recognition; text stays in the composer until manual Send.
/// Locale membership is not evidence that a local model is installed.
abstract class SpeechService extends Service {
  /// Resolve permission + on-device availability + the locale to use.
  /// [preferredLocaleId] defaults to the platform locale when null.
  Future<SpeechAvailability> init({String? preferredLocaleId});

  /// Begin one on-device native segment, capped at [maxDuration].
  /// [onEnded] marks a segment end, not the end of user dictation intent.
  Future<void> start({
    required String localeId,
    required Duration maxDuration,
    void Function(String text)? onTranscript,
    void Function()? onEnded,
    void Function()? onError,
  });

  /// Stop capture and resolve with the accumulated transcript (trimmed;
  /// empty string when nothing was recognized).
  Future<String> stop();

  /// Abort capture and discard any accumulated transcript.
  Future<void> cancel();

  /// Release native capture. Owned by the app lifecycle (the service is a
  /// singleton); ViewModels must NOT call this.
  @override
  void dispose();
}

/// Outcome of [SpeechService.init].
sealed class SpeechAvailability {
  const SpeechAvailability();
}

/// Voice input is usable; [localeId] is the resolved on-device locale.
final class SpeechReady extends SpeechAvailability {
  const SpeechReady(this.localeId);
  final String localeId;

  @override
  bool operator ==(Object other) =>
      other is SpeechReady && other.localeId == localeId;

  @override
  int get hashCode => localeId.hashCode;
}

/// Mic / speech permission was denied (decision #10).
final class SpeechPermissionDenied extends SpeechAvailability {
  const SpeechPermissionDenied();

  @override
  bool operator ==(Object other) => other is SpeechPermissionDenied;

  @override
  int get hashCode => (SpeechPermissionDenied).hashCode;
}

/// No on-device recognition available for any acceptable locale. The composer
/// keeps its mic visible and explains this result after an explicit tap.
final class SpeechUnsupported extends SpeechAvailability {
  const SpeechUnsupported();

  @override
  bool operator ==(Object other) => other is SpeechUnsupported;

  @override
  int get hashCode => (SpeechUnsupported).hashCode;
}

// ---------------------------------------------------------------------------
// Production implementation
// ---------------------------------------------------------------------------

/// Default [SpeechService] backed by the `speech_to_text` plugin.
///
/// The plugin is reached through the [SttPlugin] seam so the locale-resolution
/// / cap / transcript-accumulation logic is unit-testable without a device.
class SpeechToTextService implements SpeechService {
  SpeechToTextService([
    SttPlugin? plugin,
    this.finalWait = const Duration(seconds: 2),
  ]) : _plugin = plugin ?? SttPluginImpl();

  final SttPlugin _plugin;

  /// Latest recognized words (partial or final). Reset on each [start].
  String _transcript = '';
  final Duration finalWait;
  int _generation = 0;
  bool _disposed = false;
  bool _ended = false;
  bool _finalReceived = false;
  Completer<void>? _completion;
  Future<String>? _stopping;
  void Function()? _onEnded;
  void Function()? _onError;
  bool _initialized = false;
  Future<void> _nativeTail = Future<void>.value();

  @override
  Future<SpeechAvailability> init({String? preferredLocaleId}) async {
    final ok =
        _initialized ||
        await _plugin.initialize(
          onStatus: (status) {
            if (_completion == null || _disposed) return;
            // Android stop can emit doneNoResult (normalized to done)
            // BEFORE its first/final result. Only a real final ends the wait.
            if (status == 'notListening' || status == 'done') _end();
          },
          onError: (error) {
            if (_completion == null || _disposed) return;
            // Android marks every native error permanent, including silence.
            // Only these documented no-speech outcomes are normal capture ends;
            // never suppress client/audio/network/unknown failures after words
            // or merely because stop was requested.
            final noSpeech =
                error.code == 'error_no_match' ||
                error.code == 'error_speech_timeout';
            if (noSpeech && _transcript.isEmpty) {
              // Silence-only segments have no words to finalize. Resume capture
              // without the 2s final wait, but preserve late finals after speech.
              _complete();
            } else if (!noSpeech) {
              _onError?.call();
            }
            // Segments with words retain the bounded wait for queued finals;
            // the owner suppresses restart only on genuine failures.
            _end();
          },
        );
    if (!ok) {
      // initialize() returns false for either a denied permission or an
      // unavailable recognizer — disambiguate via hasPermission().
      final granted = await _plugin.hasPermission();
      return granted
          ? const SpeechUnsupported()
          : const SpeechPermissionDenied();
    }
    _initialized = true;

    final supported = await _plugin.locales();
    final preferred = _normalize(preferredLocaleId ?? _platformLocaleId());
    final resolved = _resolveLocale(preferred, supported);
    return resolved == null ? const SpeechUnsupported() : SpeechReady(resolved);
  }

  @override
  Future<void> start({
    required String localeId,
    required Duration maxDuration,
    void Function(String text)? onTranscript,
    void Function()? onEnded,
    void Function()? onError,
  }) async {
    final generation = ++_generation;
    _complete();
    _completion = null;
    _stopping = null;
    await _serialize(() async {
      if (generation != _generation || _disposed) return;
      _transcript = '';
      _ended = false;
      _finalReceived = false;
      _completion = Completer<void>();
      _onEnded = onEnded;
      _onError = onError;
      await _plugin.listen(
        localeId: localeId,
        listenFor: maxDuration,
        onResult: (words, isFinal) {
          if (generation != _generation || _disposed || _finalReceived) return;
          if (isFinal) _finalReceived = true;
          if (words.trim().isNotEmpty) {
            _transcript = words.trim();
            onTranscript?.call(_transcript);
          }
          if (isFinal) {
            _complete();
            _end();
          }
        },
      );
    });
  }

  /// Keep native listen/stop/cancel ordered across route-scoped owners. The
  /// returned operation still propagates its error; only the queue tail recovers.
  Future<void> _serialize(Future<void> Function() action) {
    final operation = _nativeTail.then((_) => action());
    _nativeTail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  }

  void _complete() {
    final completion = _completion;
    if (completion != null && !completion.isCompleted) completion.complete();
  }

  void _end() {
    if (_ended) return;
    _ended = true;
    _onEnded?.call();
  }

  @override
  Future<String> stop() => _stopping ??= _finish();

  Future<String> _finish() async {
    final generation = _generation;
    final completion = _completion;
    if (completion == null) {
      // Stop can arrive before a queued listen has acquired the native seam.
      // Revoke that intent synchronously, then release in queue order.
      ++_generation;
      await _serialize(_plugin.cancel);
      return '';
    }
    // Native stop acknowledges the request, NOT final recognition. Wait for a
    // real final/done/error callback, with a bounded last-valid-partial fallback.
    try {
      await Future.wait<void>([
        _serialize(_plugin.stop),
        completion.future,
      ]).timeout(finalWait, onTimeout: () => <void>[]);
    } on PlatformException {
      _onError?.call();
    }
    if (generation != _generation || _disposed) return '';
    final text = _transcript;
    ++_generation; // reject late results, even before the next start
    _completion = null;
    _onEnded = null;
    _onError = null;
    // Release even a stopped recognizer whose final never arrived, and fence
    // channel messages before another route/session acquires the singleton.
    await _serialize(_plugin.cancel);
    return text;
  }

  @override
  Future<void> cancel() async {
    ++_generation;
    _complete();
    _completion = null;
    _onEnded = null;
    _onError = null;
    _transcript = '';
    _stopping = null;
    await _serialize(_plugin.cancel);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(cancel());
  }

  // -------------------------------------------------------------------------
  // Locale resolution (decision #8 / #9)
  // -------------------------------------------------------------------------

  /// `en-US` / `en_us` → `en_US`. The plugin reports underscores; normalize
  /// case + separator so comparisons are robust.
  static String _normalize(String id) {
    final parts = id.replaceAll('-', '_').split('_');
    if (parts.isEmpty) return id;
    final lang = parts.first.toLowerCase();
    if (parts.length == 1) return lang;
    return '${lang}_${parts[1].toUpperCase()}';
  }

  static String _platformLocaleId() {
    final l = PlatformDispatcher.instance.locale;
    final country = l.countryCode;
    return (country == null || country.isEmpty)
        ? l.languageCode
        : '${l.languageCode}_$country';
  }

  /// preferred exact → preferred language → `en_US` → any English → null.
  /// Returns the original (un-normalized) supported id so it round-trips back
  /// into `listen()`.
  static String? _resolveLocale(String preferred, List<String> supported) {
    String? firstWhere(bool Function(String normalized) test) {
      for (final s in supported) {
        if (test(_normalize(s))) return s;
      }
      return null;
    }

    final lang = preferred.split('_').first;
    return firstWhere((s) => s == preferred) ??
        firstWhere((s) => s.split('_').first == lang) ??
        firstWhere((s) => s == 'en_US') ??
        firstWhere((s) => s.split('_').first == 'en');
  }
}

// ---------------------------------------------------------------------------
// Plugin seam
// ---------------------------------------------------------------------------

/// Plugin error identity, kept internal rather than exposing vendor types.
final class SttError {
  const SttError(this.code, {required this.permanent});

  final String code;
  final bool permanent;
}

typedef SttErrorCallback = void Function(SttError error);

typedef SttResultCallback = void Function(String words, bool isFinal);

/// Thin seam over the `speech_to_text` plugin so [SpeechToTextService]'s logic
/// can be exercised with a fake in unit tests (no platform channel / device).
abstract class SttPlugin {
  /// Initialize the recognizer (triggers the native permission prompt on the
  /// first call). Returns false if unavailable or permission denied.
  Future<bool> initialize({
    void Function(String status)? onStatus,
    SttErrorCallback? onError,
  });

  Future<bool> hasPermission();

  /// Recognition locale ids supported on this device (e.g. `pt_BR`, `en_US`).
  Future<List<String>> locales();

  /// Start an on-device listen session. [onResult] fires for partial + final
  /// results; no waveform or audio feedback is requested.
  Future<void> listen({
    required String localeId,
    required Duration listenFor,
    required SttResultCallback onResult,
  });

  Future<void> stop();

  Future<void> cancel();
}

/// Production [SttPlugin] wrapping the real `speech_to_text` plugin.
class SttPluginImpl implements SttPlugin {
  SttPluginImpl([stt.SpeechToText? plugin])
    : _stt = plugin ?? stt.SpeechToText();

  final stt.SpeechToText _stt;
  bool _nativeEnded = false;

  @override
  Future<bool> initialize({
    void Function(String status)? onStatus,
    SttErrorCallback? onError,
  }) => _stt.initialize(
    onStatus: (status) {
      if (status == 'notListening' || status == 'done') _nativeEnded = true;
      onStatus?.call(status);
    },
    onError: (SpeechRecognitionError error) =>
        onError?.call(SttError(error.errorMsg, permanent: error.permanent)),
    // Handset dictation must not open/close headset voice mode per segment or
    // request Bluetooth permission. Android uses one pipe-controlled PCM capture;
    // optional provider support is checked natively, with no restart fallback.
    options: [stt.SpeechToText.androidNoBluetooth],
    // Disable plugin partial-as-final synthesis; service owns fallback timing.
    finalTimeout: Duration.zero,
  );

  @override
  Future<bool> hasPermission() => _stt.hasPermission;

  @override
  Future<List<String>> locales() async {
    final list = await _stt.locales();
    return [for (final l in list) l.localeId];
  }

  @override
  Future<void> listen({
    required String localeId,
    required Duration listenFor,
    required SttResultCallback onResult,
  }) async {
    _nativeEnded = false;
    await _stt.listen(
      onResult: (SpeechRecognitionResult r) =>
          onResult(r.recognizedWords, r.finalResult),
      listenOptions: stt.SpeechListenOptions(
        // Decision #7 — local recognition only; audio never leaves the device.
        onDevice: true,
        enableHapticFeedback: false,
        listenMode: stt.ListenMode.dictation,
        // Cumulative recognition hypotheses are shown live by replacement.
        partialResults: true,
        // Non-Android engines retain their limits. Android pipe startup disables
        // these timers; only explicit Stop/cancel closes its audio source.
        pauseFor: listenFor,
        listenFor: listenFor,
        localeId: localeId,
        cancelOnError: false,
      ),
    );
    if (!_stt.isListening && !_nativeEnded) {
      throw stt.ListenNotStartedException();
    }
  }

  @override
  Future<void> stop() => _stt.stop();

  @override
  Future<void> cancel() => _stt.cancel();
}
