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
/// [stepForward] and [stepBackward], which complete once the new frame is
/// shown, so callers can pace repeated steps.
abstract interface class PlayerEngine {
  /// Opens [uri], sending [httpHeaders] with every request. [fileName] lets
  /// the engine apply container-specific settings (for example for `.ts`).
  Future<void> open(Uri uri, {Map<String, String> httpHeaders = const {}, String? fileName});

  Future<void> play();
  Future<void> pause();
  Future<void> playOrPause();

  Future<void> seekTo(Duration position, {SeekMode mode = SeekMode.exact});
  Future<void> seekBy(Duration offset, {SeekMode mode = SeekMode.exact});

  /// One frame forward; pauses playback.
  Future<void> stepForward();

  /// One frame back, exactly; pauses playback.
  Future<void> stepBackward();

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

  /// The video surface. Receives no input of its own.
  Widget buildView();

  Future<void> dispose();
}
