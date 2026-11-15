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

/// Where a frame step landed relative to the frame it started on.
enum StepLanding {
  /// One frame in the expected direction, within half a frame.
  exact,

  /// Within half a frame of where it started: did not move (for back steps
  /// in `.ts`, typically stuck on a keyframe).
  stuck,

  /// More than one and a half frames in the expected direction.
  skipped,

  /// Moved the other way (for back steps: landed after the start, as a late
  /// `.ts` seek does).
  wrongDirection,
}

/// Classifies a step from [from] to [to]. [forward] is the expected
/// direction; [frame] is one frame's duration.
StepLanding classifyStep({
  required Duration from,
  required Duration to,
  required bool forward,
  required Duration frame,
}) {
  final moved = (to - from).inMicroseconds * (forward ? 1 : -1);
  final f = frame.inMicroseconds;
  final half = f / 2;
  if (moved.abs() <= half) return StepLanding.stuck;
  if (moved < 0) return StepLanding.wrongDirection;
  if (moved <= f + half) return StepLanding.exact;
  return StepLanding.skipped;
}

/// Counts of each [StepLanding], as written to the results.
Map<String, int> landingCounts(Iterable<StepLanding> landings) => {
  for (final kind in StepLanding.values) kind.name: landings.where((l) => l == kind).length,
};
