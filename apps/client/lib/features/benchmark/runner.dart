import 'dart:async';

import '../../engine/player_engine.dart';
import 'stats.dart';

class BenchmarkCancelled implements Exception {
  const BenchmarkCancelled();
  @override
  String toString() => 'Benchmark cancelled';
}

class BenchmarkOptions {
  const BenchmarkOptions({
    this.steps = 20,
    this.seeks = 10,
    this.timeout = const Duration(seconds: 30),
    this.giveUpAfter = 3,
    this.loadTimeout = const Duration(seconds: 60),
  });

  /// Frame steps per series, and seeks per series (bench.lua's defaults).
  final int steps, seeks;

  /// The longest one operation may take before it counts as a timeout. The
  /// engine's own step timeout (a few seconds) usually comes first.
  final Duration timeout;

  /// A series stops after this many consecutive timeouts; the rest of it
  /// counts as timeouts, as in bench.lua.
  final int giveUpAfter;

  /// How long the file may take to report its duration after opening.
  final Duration loadTimeout;
}

/// One series of identical operations.
class Series {
  Series(this.name);

  final String name;
  final samplesMs = <double>[];
  final landings = <StepLanding>[];
  int timeouts = 0;

  Map<String, Object?> toJson() => {
    ...TimingStats.of(samplesMs).toJson(),
    'timeouts': timeouts,
    if (landings.isNotEmpty) 'landings': landingCounts(landings),
    'samplesMs': [for (final ms in samplesMs) (ms * 10).round() / 10],
  };
}

class BenchmarkMeasurements {
  BenchmarkMeasurements({required this.diagnostics, required this.series, required this.frame});

  /// Read after the first seek, when the engine has decoded a frame.
  final EngineDiagnostics diagnostics;
  final List<Series> series;

  /// The frame duration steps were classified against, or null when the
  /// engine did not know the frame rate (then steps are not classified).
  final Duration? frame;

  Iterable<Series> _named(bool Function(String) test) => series.where((s) => test(s.name));

  /// Summary of back steps at the app's normal settings, or with the
  /// benchmark-only `.ts` demuxer offset of 0 when [offsetZero] is true.
  Map<String, Object?>? _backSteps({required bool offsetZero}) {
    final all = _named((n) => n.startsWith('back_step_') && n.endsWith('_offset0') == offsetZero).toList();
    if (all.isEmpty) return null;
    final stats = TimingStats.of(all.expand((s) => s.samplesMs));
    final landings = all.expand((s) => s.landings).toList();
    return {
      'medianMs': stats.toJson()['medianMs'],
      'p95Ms': stats.toJson()['p95Ms'],
      'attempted': all.fold<int>(0, (n, s) => n + s.samplesMs.length + s.timeouts),
      'classified': landings.length,
      'exact': landings.where((l) => l == StepLanding.exact).length,
      'stuck': landings.where((l) => l == StepLanding.stuck).length,
      'skipped': landings.where((l) => l == StepLanding.skipped).length,
      'wrongDirection': landings.where((l) => l == StepLanding.wrongDirection).length,
      'timeouts': all.fold<int>(0, (n, s) => n + s.timeouts),
    };
  }

  Map<String, Object?> summary() => {
    'backStep': _backSteps(offsetZero: false),
    'backStepOffset0': _backSteps(offsetZero: true),
    'exactSeekMedianMs': TimingStats.of(_named((n) => n == 'seek_far_exact').expand((s) => s.samplesMs))
        .toJson()['medianMs'],
    'timeouts': series.fold<int>(0, (n, s) => n + s.timeouts),
  };

  Map<String, Object?> toJson() => {
    'engine': diagnostics.toJson(),
    'frameMs': frame == null ? null : frame!.inMicroseconds / 1000,
    'summary': summary(),
    'tests': {for (final s in series) s.name: s.toJson()},
  };
}

/// Repeats tools/engine-bench/bench.lua on a [PlayerEngine] (without its
/// reverse-mode block, which the app does not use). The file must already be
/// open and paused. Every operation is timed from the command to the engine's
/// own "frame shown" signal ([PlayerEngine.stepBackward] and
/// [PlayerEngine.seekAndWait]), never to a position change.
class EngineBenchmark {
  EngineBenchmark(this.engine, {this.options = const BenchmarkOptions(), Duration Function()? elapsed, this.onProgress})
    : _elapsed = elapsed ?? _stopwatch();

  final PlayerEngine engine;
  final BenchmarkOptions options;
  final void Function(String progress)? onProgress;
  final Duration Function() _elapsed;
  final _cancel = Completer<void>();

  bool get cancelled => _cancel.isCompleted;

  /// Stops at the next operation boundary, or at once if one is waiting;
  /// [run] then throws [BenchmarkCancelled].
  void cancel() {
    if (!_cancel.isCompleted) _cancel.complete();
  }

  /// Runs every series. [mpegTs] adds back steps with the demuxer seek
  /// offset overridden to 0, to compare with the app's normal `.ts` offset.
  Future<BenchmarkMeasurements> run({required bool mpegTs}) async {
    final duration = await _loaded();
    final series = <Series>[];
    Duration at(double fraction) => duration * fraction;
    EngineDiagnostics? diagnostics;
    Duration? frame;

    for (final (index, fraction) in [(1, 0.31), (2, 0.62)]) {
      await _setup(() => engine.seekAndWait(at(fraction), relative: false));
      if (diagnostics == null) {
        diagnostics = await engine.diagnostics();
        final fps = diagnostics.frameRate;
        frame = fps == null || fps <= 0 ? null : Duration(microseconds: (1e6 / fps).round());
      }
      series.add(
        await _measure('fwd_step_$index', options.steps, (_) => engine.stepForward(), forward: true, frame: frame),
      );
      final backStart = await engine.currentPosition();
      series.add(
        await _measure('back_step_$index', options.steps, (_) => engine.stepBackward(), forward: false, frame: frame),
      );
      if (mpegTs) {
        // Same frames again, with the offset FFmpeg's TS seeking would need
        // if it were not late (docs/ARCHITECTURE.md, section 3). The start
        // seek uses the normal offset so both series start on the same frame.
        await _setup(() => engine.seekAndWait(backStart, relative: false));
        await engine.overrideDemuxerSeekOffset(Duration.zero);
        try {
          series.add(
            await _measure(
              'back_step_${index}_offset0',
              options.steps,
              (_) => engine.stepBackward(),
              forward: false,
              frame: frame,
            ),
          );
        } finally {
          await engine.overrideDemuxerSeekOffset(null);
        }
      }
    }

    // Long seeks to scattered positions (cold cache), keyframe then exact.
    Duration scattered(int i) => duration * (((i * 0.6180339887) % 1) * 0.9 + 0.05);
    series.add(
      await _measure(
        'seek_far_keyframe',
        options.seeks,
        (i) => engine.seekAndWait(scattered(i), relative: false, mode: SeekMode.keyframe),
      ),
    );
    series.add(
      await _measure('seek_far_exact', options.seeks, (i) => engine.seekAndWait(scattered(i + 100), relative: false)),
    );

    // Arrow-key style short seeks around one spot.
    const five = Duration(seconds: 5);
    await _setup(() => engine.seekAndWait(at(0.5), relative: false));
    series.add(await _measure('seek_fwd5_exact', options.seeks, (_) => engine.seekAndWait(five, relative: true)));
    series.add(await _measure('seek_back5_exact', options.seeks, (_) => engine.seekAndWait(-five, relative: true)));
    series.add(
      await _measure(
        'seek_back5_keyframe',
        options.seeks,
        (_) => engine.seekAndWait(-five, relative: true, mode: SeekMode.keyframe),
      ),
    );
    return BenchmarkMeasurements(diagnostics: diagnostics!, series: series, frame: frame);
  }

  Future<Duration> _loaded() async {
    if (engine.duration > Duration.zero) return engine.duration;
    onProgress?.call('Opening');
    final loaded = engine.durationStream.firstWhere((d) => d > Duration.zero);
    final result = await _bounded(loaded.then((_) => true), options.loadTimeout);
    if (!result) throw TimeoutException('The file did not load', options.loadTimeout);
    return engine.duration;
  }

  /// A positioning seek between series; not measured.
  Future<void> _setup(Future<bool> Function() seek) async {
    _checkCancelled();
    await _bounded(seek(), options.timeout);
  }

  Future<Series> _measure(
    String name,
    int count,
    Future<bool> Function(int i) operation, {
    bool? forward,
    Duration? frame,
  }) async {
    final series = Series(name);
    var streak = 0;
    for (var i = 1; i <= count; i++) {
      _checkCancelled();
      onProgress?.call('${_label(name)} $i/$count');
      final from = await engine.currentPosition();
      final start = _elapsed();
      final shown = await _bounded(operation(i), options.timeout);
      if (shown) {
        series.samplesMs.add((_elapsed() - start).inMicroseconds / 1000);
        streak = 0;
      } else {
        series.timeouts++;
        streak++;
      }
      // Every attempted step is classified, timed out or not: a step that
      // never moved is "stuck" either way.
      if (forward != null && frame != null) {
        final to = await engine.currentPosition();
        series.landings.add(classifyStep(from: from, to: to, forward: forward, frame: frame));
      }
      if (streak >= options.giveUpAfter) {
        series.timeouts += count - i;
        break;
      }
    }
    return series;
  }

  void _checkCancelled() {
    if (cancelled) throw const BenchmarkCancelled();
  }

  /// [operation]'s result, false after [timeout], or [BenchmarkCancelled].
  /// An operation that outlives its timeout keeps running in the engine; the
  /// next one is sent anyway, as bench.lua does.
  Future<bool> _bounded(Future<bool> operation, Duration timeout) {
    final timedOut = Completer<bool>();
    final timer = Timer(timeout, () => timedOut.complete(false));
    return Future.any<bool>([
      operation,
      timedOut.future,
      _cancel.future.then<bool>((_) => throw const BenchmarkCancelled()),
    ]).whenComplete(timer.cancel);
  }

  static String _label(String series) => switch (series) {
    final s when s.startsWith('fwd_step') => 'Forward steps',
    final s when s.endsWith('_offset0') => 'Back steps, offset 0',
    final s when s.startsWith('back_step') => 'Back steps',
    'seek_far_keyframe' => 'Far keyframe seeks',
    'seek_far_exact' => 'Far exact seeks',
    _ => '±5 s seeks',
  };
}

Duration Function() _stopwatch() {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
}
