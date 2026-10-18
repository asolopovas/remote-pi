import 'dart:async';

import 'package:app/data/voice/speech_service.dart';
import 'package:app/ui/chat/voice/states/voice_input_state.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// One explicit dictation session spans serial, on-device native segments.
/// Live hypotheses replace only the current segment; sending remains manual.
class VoiceInputViewModel extends ViewModel<VoiceInputState> {
  VoiceInputViewModel(
    this._service, {
    this.maxDuration = const Duration(seconds: 60),
    this.restartDelay = const Duration(milliseconds: 300),
  }) : super(const VoiceIdle());

  final SpeechService _service;

  /// Native segment limit, not a limit on the user's dictation session.
  final Duration maxDuration;

  /// A positive gap prevents synchronous terminal callbacks from busy-looping.
  final Duration restartDelay;
  SpeechAvailability? _availability;
  Timer? _restart;
  int _generation = 0;
  int _segment = 0;
  bool _disposed = false;
  bool _nativeStarted = false;
  bool _captureFailed = false;
  bool _cancelling = false;
  bool _stopRequested = false;
  Future<void>? _start;
  Future<void>? _segmentFinish;
  String _committed = '';
  String _segmentText = '';

  final StreamController<String> _transcripts =
      StreamController<String>.broadcast(sync: true);
  Stream<String> get transcripts => _transcripts.stream;
  bool get active =>
      state is VoiceStarting ||
      state is VoiceRecording ||
      state is VoiceReconnecting ||
      state is VoiceTranscribing;

  Future<SpeechAvailability> ensureInit() async {
    final cached = _availability;
    if (cached is SpeechReady) return cached;
    final generation = _generation;
    final result = await _service.init();
    if (!_current(generation)) return result;
    _availability = result;
    switch (result) {
      case SpeechReady():
        if (state is VoiceUnavailable) emit(const VoiceIdle());
      case SpeechPermissionDenied():
        emit(const VoiceUnavailable(VoiceUnavailableReason.permissionDenied));
      case SpeechUnsupported():
        emit(const VoiceUnavailable(VoiceUnavailableReason.unsupported));
    }
    return result;
  }

  Future<void> startRecording() {
    if (_disposed || _cancelling || active) return Future<void>.value();
    final generation = ++_generation;
    _captureFailed = false;
    _stopRequested = false;
    _committed = '';
    _segmentText = '';
    emit(const VoiceStarting());
    return _start = _begin(generation);
  }

  bool _current(int generation) => !_disposed && generation == _generation;
  bool _currentSegment(int generation, int segment) =>
      _current(generation) && segment == _segment;

  Future<void> _begin(int generation) async {
    try {
      final availability = await ensureInit();
      if (!_current(generation) || availability is! SpeechReady) return;
      await _listenSegment(generation, availability.localeId);
    } on PlatformException {
      if (_current(generation)) {
        _cancelRestart();
        emit(const VoiceFailed());
      }
    }
  }

  String get _text =>
      [_committed, _segmentText].where((part) => part.isNotEmpty).join(' ');

  void _publish() {
    if (_text.isNotEmpty) _transcripts.add(_text);
  }

  Future<void> _listenSegment(int generation, String localeId) async {
    if (!_current(generation) || _stopRequested) return;
    final segment = ++_segment;
    _segmentText = '';
    _segmentFinish = null;
    _nativeStarted = true;
    try {
      await _service.start(
        localeId: localeId,
        maxDuration: maxDuration,
        onTranscript: (text) {
          if (!_currentSegment(generation, segment)) return;
          _segmentText = text.trim();
          _publish();
        },
        onEnded: () {
          if (_currentSegment(generation, segment)) {
            unawaited(_endSegment(generation, segment));
          }
        },
        onError: () {
          if (_currentSegment(generation, segment)) {
            _captureFailed = true;
            unawaited(_endSegment(generation, segment));
          }
        },
      );
      if (!_currentSegment(generation, segment) ||
          _segmentFinish != null ||
          _stopRequested) {
        return;
      }
      emit(const VoiceRecording());
    } on stt.ListenFailedException {
      await _failSegment(generation, segment);
    } on stt.ListenNotStartedException {
      await _failSegment(generation, segment);
    } on PlatformException {
      await _failSegment(generation, segment);
    }
  }

  Future<void> _failSegment(int generation, int segment) async {
    if (!_currentSegment(generation, segment)) return;
    _captureFailed = true;
    await _endSegment(generation, segment);
  }

  Future<void> _endSegment(int generation, int segment) {
    // Install the future before native stop can synchronously call onEnded.
    final existing = _segmentFinish;
    if (existing != null) return existing;
    final completion = Completer<void>();
    _segmentFinish = completion.future;
    emit(
      _stopRequested || _captureFailed
          ? const VoiceTranscribing()
          : const VoiceReconnecting(),
    );
    unawaited(
      _finishSegment(
        generation,
        segment,
      ).then(completion.complete, onError: completion.completeError),
    );
    return completion.future;
  }

  Future<void> _finishSegment(int generation, int segment) async {
    try {
      final text = _nativeStarted ? await _service.stop() : '';
      if (!_currentSegment(generation, segment)) return;
      if (text.isNotEmpty) _segmentText = text.trim();
    } on PlatformException {
      if (!_currentSegment(generation, segment)) return;
      _captureFailed = true;
      await _service.cancel();
    }
    if (!_currentSegment(generation, segment)) return;
    _nativeStarted = false;
    _publish();
    _committed = _text;
    _segmentText = '';
    ++_segment; // fence results/errors from the completed native segment
    if (_stopRequested || _captureFailed) {
      _cancelRestart();
      emit(_captureFailed ? const VoiceFailed() : const VoiceIdle());
      return;
    }
    emit(const VoiceReconnecting());
    _restart = Timer(
      restartDelay > Duration.zero
          ? restartDelay
          : const Duration(milliseconds: 300),
      () {
        _restart = null;
        if (_current(generation) && !_stopRequested) {
          unawaited(
            _listenSegment(generation, (_availability as SpeechReady).localeId),
          );
        }
      },
    );
  }

  Future<String> stopAndTranscribe() async {
    if (_disposed || _cancelling || !active || _stopRequested) return '';
    _stopRequested = true; // synchronous: no new segment after this tap
    _restart?.cancel();
    _restart = null;
    if (state is VoiceStarting) {
      await cancel();
      return '';
    }
    final generation = _generation;
    if (_nativeStarted) {
      emit(const VoiceTranscribing());
      await _endSegment(generation, _segment);
    } else {
      _cancelRestart();
      emit(_captureFailed ? const VoiceFailed() : const VoiceIdle());
    }
    return _current(generation) ? _committed : '';
  }

  /// Keeps already-visible words. Cancel invalidates all pending callbacks.
  Future<void> cancel() async {
    if (_disposed || _cancelling || !active) return;
    _cancelling = true;
    _stopRequested = true;
    final generation = ++_generation;
    _cancelRestart();
    // Invalidate synchronously, but don't notify while a composer is unmounting.
    await Future<void>.value();
    if (_current(generation)) emit(const VoiceTranscribing());
    if (_nativeStarted) {
      _nativeStarted = false;
      await _service.cancel();
    }
    await _start;
    _cancelling = false;
    if (_current(generation)) emit(const VoiceIdle());
  }

  void _cancelRestart() {
    _restart?.cancel();
    _restart = null;
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _cancelRestart();
    if (_nativeStarted) {
      _nativeStarted = false;
      unawaited(_service.cancel());
    }
    _transcripts.close();
    super.dispose();
  }
}
