import 'package:flutter/widgets.dart';

/// How a seek lands.
enum SeekMode {
  /// On the requested frame (slower: decodes from the previous keyframe).
  exact,

  /// On a nearby keyframe (fast; for scrubbing).
  keyframe,
}

enum EngineState { idle, buffering, paused, playing, ended }

enum TrackKind { video, audio, subtitle }

class MediaTrack {
  const MediaTrack({required this.id, required this.kind, this.title, this.language, this.codec});

  /// Engine-specific id. Not the server's ffprobe stream index.
  final String id;
  final TrackKind kind;
  final String? title;
  final String? language;
  final String? codec;
}

/// The only way player code talks to a playback engine (docs/ARCHITECTURE.md,
/// section 4). Implementations: `MpvEngine` (Windows, Android). A
/// `<video>`-based engine for web comes later.
///
/// Futures complete when the engine has accepted the command, except
/// [stepForward], [stepBackward] and [seekAndWait], which complete once the
/// new frame is shown, so callers can pace repeated steps.
abstract interface class PlayerEngine {
  /// Opens [uri], sending [httpHeaders] with every request. [fileName] lets
  /// the engine apply container-specific settings (for example for `.ts`).
  /// With [play] false the file opens paused on its first frame.
  Future<void> open(Uri uri, {Map<String, String> httpHeaders = const {}, String? fileName, bool play = true});

  Future<void> play();
  Future<void> pause();
  Future<void> playOrPause();

  Future<void> seekTo(Duration position, {SeekMode mode = SeekMode.exact});
  Future<void> seekBy(Duration offset, {SeekMode mode = SeekMode.exact});

  /// One frame forward; pauses playback. True once the new frame is shown,
  /// false when the engine saw no sign of the step before its timeout (for
  /// example on the last frame).
  Future<bool> stepForward();

  /// One frame back, exactly; pauses playback. Completes like [stepForward].
  Future<bool> stepBackward();

  Future<void> setSpeed(double speed);
  Future<void> setMuted(bool muted);

  Duration get position;
  Duration get duration;
  EngineState get state;
  double get speed;
  bool get muted;
  List<MediaTrack> get tracks;

  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<EngineState> get stateStream;
  Stream<double> get speedStream;
  Stream<bool> get mutedStream;
  Stream<List<MediaTrack>> get tracksStream;

  /// Human-readable playback errors (failed open, network, decoder).
  Stream<String> get errorStream;

  // The members below serve the in-app engine benchmark
  // (lib/features/benchmark). Normal playback does not use them.

  /// Seeks like [seekTo] or [seekBy] and completes like [stepBackward]: true
  /// once the new frame is shown, false after the engine's timeout.
  Future<bool> seekAndWait(Duration time, {required bool relative, SeekMode mode = SeekMode.exact});

  /// The position the engine holds right now, read from the engine itself
  /// rather than from the last [positionStream] event, which can lag.
  Future<Duration> currentPosition();

  /// Facts about the open file and the decoder in use.
  Future<EngineDiagnostics> diagnostics();

  /// Benchmark-only override of how far before the target the demuxer is
  /// asked to seek (mpv's `hr-seek-demuxer-offset`), for the open file.
  /// `null` restores the value [open] chose.
  Future<void> overrideDemuxerSeekOffset(Duration? offset);

  /// The video surface. Receives no input of its own.
  Widget buildView();

  Future<void> dispose();
}

/// Engine-neutral facts for the benchmark. Any field may be null when the
/// engine does not know it.
class EngineDiagnostics {
  const EngineDiagnostics({
    required this.engine,
    this.engineVersion,
    this.ffmpegVersion,
    this.hardwareDecoding,
    this.decoder,
    this.container,
    this.codec,
    this.pixelFormat,
    this.width,
    this.height,
    this.frameRate,
    this.demuxerSeekOffset,
  });

  /// For example `mpv`.
  final String engine;
  final String? engineVersion;
  final String? ffmpegVersion;

  /// The hardware decoding API in use, or `null` for software decoding.
  final String? hardwareDecoding;
  final String? decoder;
  final String? container;
  final String? codec;
  final String? pixelFormat;
  final int? width;
  final int? height;

  /// Frames per second as the container declares it.
  final double? frameRate;

  /// The demuxer seek offset in effect (see
  /// [PlayerEngine.overrideDemuxerSeekOffset]).
  final Duration? demuxerSeekOffset;

  Map<String, Object?> toJson() => {
    'engine': engine,
    'engineVersion': engineVersion,
    'ffmpegVersion': ffmpegVersion,
    'hardwareDecoding': hardwareDecoding,
    'decoder': decoder,
    'container': container,
    'codec': codec,
    'pixelFormat': pixelFormat,
    'width': width,
    'height': height,
    'frameRate': frameRate,
    'demuxerSeekOffsetSeconds': demuxerSeekOffset == null ? null : demuxerSeekOffset!.inMicroseconds / 1e6,
  };
}
