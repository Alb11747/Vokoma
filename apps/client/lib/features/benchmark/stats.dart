/// Statistics and step classification for the engine benchmark. Quantiles
/// use the nearest-rank rule of tools/engine-bench/bench.lua, so results
/// compare with the tables in docs/ARCHITECTURE.md, section 3.
library;

class TimingStats {
  const TimingStats({required this.n, this.min, this.median, this.p90, this.p95, this.max});

  factory TimingStats.of(Iterable<double> samplesMs) {
    final s = samplesMs.toList()..sort();
    if (s.isEmpty) return const TimingStats(n: 0);
    double q(double p) => s[(p * (s.length - 1)).round().clamp(0, s.length - 1)];
    return TimingStats(n: s.length, min: s.first, median: q(0.5), p90: q(0.9), p95: q(0.95), max: s.last);
  }

  final int n;
  final double? min, median, p90, p95, max;

  Map<String, Object?> toJson() => {
    'n': n,
    'minMs': _round(min),
    'medianMs': _round(median),
    'p90Ms': _round(p90),
    'p95Ms': _round(p95),
    'maxMs': _round(max),
  };
}

double? _round(double? ms) => ms == null ? null : (ms * 10).round() / 10;

/// Where a back step landed.
enum StepLanding {
  /// On the previous frame.
  exact,

  /// Within half a frame of where it started: did not move (for back steps
  /// in `.ts`, typically stuck on a keyframe).
  stuck,

  /// Earlier than the previous frame.
  skipped,

  /// Later than where it started (as a late `.ts` seek lands).
  wrongDirection,

  /// Not checkable: the step started or landed off the known frames.
  unverified,
}

/// Classifies a back step from [from] to [to] against [frames], the frame
/// timestamps the forward steps visited over the same range (ascending).
///
/// Using real neighbouring timestamps instead of a nominal frame duration
/// keeps variable frame rate files correct: with 20 and 80 ms intervals a
/// 40 ms nominal frame would call correct steps stuck or skipped.
StepLanding classifyBackStep({required List<Duration> frames, required Duration from, required Duration to}) {
  // Positions of one frame are reported identically; allow rounding only.
  const same = Duration(milliseconds: 1);
  final i = frames.indexWhere((f) => (f - from).abs() <= same);
  if (i <= 0) return StepLanding.unverified;
  final target = frames[i - 1];
  final interval = from - target;
  final below = i >= 2 ? target - frames[i - 2] : interval;
  final tolerance = (interval < below ? interval : below) ~/ 2;
  if ((to - target).abs() <= tolerance) return StepLanding.exact;
  if ((to - from).abs() <= interval ~/ 2) return StepLanding.stuck;
  if (to > from) return StepLanding.wrongDirection;
  if (to < target) return StepLanding.skipped;
  // Between two known frames: the forward steps missed a frame here.
  return StepLanding.unverified;
}

/// Counts of each [StepLanding], as written to the results.
Map<String, int> landingCounts(Iterable<StepLanding> landings) => {
  for (final kind in StepLanding.values) kind.name: landings.where((l) => l == kind).length,
};
