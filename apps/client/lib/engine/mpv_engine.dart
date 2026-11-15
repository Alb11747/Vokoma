import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'player_engine.dart';

/// [PlayerEngine] on libmpv through media_kit. The only code in the app that
/// may touch mpv or media_kit.
class MpvEngine implements PlayerEngine {
  MpvEngine() {
    _player = Player(
      configuration: const PlayerConfiguration(
        // media_kit turns libass off by default, which drops ASS styling and
        // embedded fonts. The anime library depends on both.
        libass: true,
      ),
    );
    _video = VideoController(
      _player,
      configuration: VideoControllerConfiguration(hwdec: defaultHwdec(Platform.operatingSystem)),
    );
    _subscriptions.addAll([
      _player.stream.playing.listen((_) => _emitState()),
      _player.stream.buffering.listen((_) => _emitState()),
      _player.stream.completed.listen((_) => _emitState()),
      _player.stream.tracks.listen((t) => _tracks.add(_tracksOf(t))),
    ]);
    unawaited(
      _native.observeProperty('mute', (value) async {
        _muted = value == 'yes';
        _mutedController.add(_muted);
      }),
    );
    unawaited(
      _native.observeProperty('seeking', (value) async {
        _seeking = value == 'yes';
        _seekingController.add(_seeking);
      }),
    );
  }

  /// Loads libmpv. Call once before creating an engine.
  static void initialize() => MediaKit.ensureInitialized();

  /// How long a frame step may show no sign of work before it counts as one
  /// that moves nothing (first or last frame). A step still seeking by then
  /// is waited for to the end; see [frameStepDone].
  static const stepTimeout = Duration(seconds: 3);

  late final Player _player;
  late final VideoController _video;
  NativePlayer get _native => _player.platform as NativePlayer;

  final _subscriptions = <StreamSubscription<Object?>>[];
  final _stateController = StreamController<EngineState>.broadcast();
  final _mutedController = StreamController<bool>.broadcast();
  final _tracks = StreamController<List<MediaTrack>>.broadcast();
  final _seekingController = StreamController<bool>.broadcast();
  bool _opened = false;
  bool _muted = false;
  bool _seeking = false;
  EngineState _state = EngineState.idle;

  @override
  Future<void> open(Uri uri, {Map<String, String> httpHeaders = const {}, String? fileName}) async {
    await _native.setProperty('hr-seek-demuxer-offset', hrSeekDemuxerOffsetFor(fileName));
    // media_kit passes httpHeaders to mpv's `http-header-fields` option.
    await _player.open(Media(uri.toString(), httpHeaders: httpHeaders), play: true);
    _opened = true;
    _emitState();
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> playOrPause() => _player.playOrPause();

  @override
  Future<void> seekTo(Duration position, {SeekMode mode = SeekMode.exact}) =>
      _native.command(seekCommand(position, relative: false, mode: mode));

  @override
  Future<void> seekBy(Duration offset, {SeekMode mode = SeekMode.exact}) =>
      _native.command(seekCommand(offset, relative: true, mode: mode));

  @override
  Future<void> stepForward() => _step('frame-step', backward: false);

  /// Seek-based back step: mpv seeks to the previous keyframe and decodes up
  /// to the frame before. Exact in every benchmark run; reverse playback
  /// mode is deliberately not used (docs/ARCHITECTURE.md, section 3).
  @override
  Future<void> stepBackward() => _step('frame-back-step', backward: true);

  Future<void> _step(String command, {required bool backward}) async {
    final done = frameStepDone(
      backward: backward,
      positions: _player.stream.position,
      from: _player.state.position,
      seeking: _seekingController.stream,
      isSeeking: () => _seeking,
      timeout: stepTimeout,
    );
    await _native.command([command]);
    await done;
  }

  @override
  Future<void> setSpeed(double speed) => _player.setRate(speed);

  @override
  Future<void> setMuted(bool muted) => _native.setProperty('mute', muted ? 'yes' : 'no');

  @override
  Duration get position => _player.state.position;
  @override
  Duration get duration => _player.state.duration;
  @override
  EngineState get state => _state;
  @override
  double get speed => _player.state.rate;
  @override
  bool get muted => _muted;
  @override
  List<MediaTrack> get tracks => _tracksOf(_player.state.tracks);

  @override
  Stream<Duration> get positionStream => _player.stream.position;
  @override
  Stream<Duration> get durationStream => _player.stream.duration;
  @override
  Stream<EngineState> get stateStream => _stateController.stream;
  @override
  Stream<double> get speedStream => _player.stream.rate;
  @override
  Stream<bool> get mutedStream => _mutedController.stream;
  @override
  Stream<List<MediaTrack>> get tracksStream => _tracks.stream;
  @override
  Stream<String> get errorStream => _player.stream.error;

  @override
  Widget buildView() => Video(controller: _video, controls: NoVideoControls, fill: Colors.black);

  @override
  Future<void> dispose() async {
    for (final s in _subscriptions) {
      await s.cancel();
    }
    await _player.dispose();
    await _stateController.close();
    await _mutedController.close();
    await _tracks.close();
    await _seekingController.close();
  }

  void _emitState() {
    final s = _player.state;
    final next = engineStateOf(opened: _opened, playing: s.playing, buffering: s.buffering, completed: s.completed);
    if (next == _state) return;
    _state = next;
    _stateController.add(next);
  }

  static List<MediaTrack> _tracksOf(Tracks t) => [
    for (final v in t.video.where(_isReal))
      MediaTrack(id: v.id, kind: TrackKind.video, title: v.title, language: v.language, codec: v.codec),
    for (final a in t.audio.where(_isReal))
      MediaTrack(id: a.id, kind: TrackKind.audio, title: a.title, language: a.language, codec: a.codec),
    for (final s in t.subtitle.where(_isReal))
      MediaTrack(id: s.id, kind: TrackKind.subtitle, title: s.title, language: s.language, codec: s.codec),
  ];

  // media_kit lists mpv's 'auto' and 'no' choices as tracks.
  static bool _isReal(dynamic track) => track.id != 'auto' && track.id != 'no';
}

/// mpv's hardware decoding choice per platform.
///
/// `auto-safe` uses only decoders mpv considers reliable and falls back to
/// software decoding when the hardware decoder fails or lacks the codec (for
/// example AV1 on a phone without an AV1 decoder, or H.264 High 10, which no
/// GPU decodes). On Windows media_kit would otherwise use `auto`. On Android
/// media_kit already picks `auto-safe`, or software decoding on emulators.
@visibleForTesting
String? defaultHwdec(String operatingSystem) => operatingSystem == 'windows' ? 'auto-safe' : null;

/// mpv's `hr-seek-demuxer-offset` for a file.
///
/// FFmpeg's MPEG-TS demuxer seeks to the first keyframe *after* the
/// requested time, so without an offset exact seeks land up to one keyframe
/// interval late and back steps across a keyframe get stuck on it. Twitch
/// recordings have a keyframe every 2 s; asking the demuxer for a point 3 s
/// earlier makes it land before the target, and mpv then decodes forward to
/// the exact frame. Measured with mpv 0.42 on a generated 60 fps `.ts` with
/// 2 s keyframes: 0 s lands up to 2011 ms late; 1 s up to 811 ms late; 2 s
/// makes seeks exact but some back steps still stick; 3 s makes all seeks
/// and back steps exact, for about 65 ms more per seek. Other containers
/// have an index and keep 0, which avoids decoding the extra seconds.
@visibleForTesting
String hrSeekDemuxerOffsetFor(String? fileName) {
  final name = fileName?.toLowerCase() ?? '';
  return name.endsWith('.ts') ? '3' : '0';
}

@visibleForTesting
List<String> seekCommand(Duration time, {required bool relative, required SeekMode mode}) {
  final seconds = (time.inMicroseconds / Duration.microsecondsPerSecond).toStringAsFixed(6);
  final flags = '${relative ? 'relative' : 'absolute'}+${mode == SeekMode.exact ? 'exact' : 'keyframes'}';
  return ['seek', seconds, flags];
}

@visibleForTesting
EngineState engineStateOf({
  required bool opened,
  required bool playing,
  required bool buffering,
  required bool completed,
}) {
  if (!opened) return EngineState.idle;
  if (completed) return EngineState.ended;
  if (buffering) return EngineState.buffering;
  return playing ? EngineState.playing : EngineState.paused;
}

/// Completes when a frame step has finished. Subscribe before issuing it.
///
/// A back step is a seek, and mpv ignores a back step issued while a seek is
/// running, so it is done only when mpv reports [seeking] off again. Position
/// changes do not count: playback or an earlier seek can move the position
/// before the step's own seek ends. A forward step is done when the position
/// moves outside a seek.
///
/// After [timeout] with no completion the step is taken to move nothing
/// (first or last frame) and completes, unless mpv is still seeking
/// ([isSeeking]); then it completes when that seek ends, so the next step is
/// not sent into it.
@visibleForTesting
Future<void> frameStepDone({
  required bool backward,
  required Stream<Duration> positions,
  required Duration from,
  required Stream<bool> seeking,
  required bool Function() isSeeking,
  required Duration timeout,
}) {
  final done = Completer<void>();
  var timedOut = false;
  void finish() {
    if (!done.isCompleted) done.complete();
  }

  final subscriptions = [
    seeking.listen((s) {
      if (!s && (backward || timedOut)) finish();
    }),
    if (!backward)
      positions.listen((p) {
        if (p != from && !isSeeking()) finish();
      }),
  ];
  final timer = Timer(timeout, () {
    timedOut = true;
    if (!isSeeking()) finish();
  });
  return done.future.whenComplete(() {
    timer.cancel();
    for (final s in subscriptions) {
      s.cancel();
    }
  });
}
