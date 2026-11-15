import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vokoma/api/api.dart';
import 'package:vokoma/engine/player_engine.dart';
import 'package:vokoma/features/benchmark/results.dart';
import 'package:vokoma/features/benchmark/runner.dart';
import 'package:vokoma/features/benchmark/stats.dart';

const frame = Duration(milliseconds: 40); // 25 fps

/// A paused engine on a 25 fps file with keyframes every 2 s. Every
/// operation takes [delay] of fake time. With a demuxer offset of 0, back
/// steps that start on a 400 ms grid point stick there, like `.ts` without
/// the offset sticking on a keyframe.
class FakeBenchEngine implements PlayerEngine {
  FakeBenchEngine({this.delay = const Duration(milliseconds: 50)});

  final Duration delay;
  final calls = <String>[];
  Duration pos = Duration.zero;
  Duration? offset;

  /// When set, back steps never complete.
  bool hangBackSteps = false;

  /// When set, forward steps report the engine's own timeout (false).
  bool forwardTimesOut = false;

  Future<bool> _after(void Function() effect, {bool result = true}) => Future.delayed(delay, () {
    effect();
    return result;
  });

  @override
  Duration get duration => const Duration(minutes: 10);
  @override
  Future<Duration> currentPosition() async => pos;
  @override
  Future<EngineDiagnostics> diagnostics() async =>
      EngineDiagnostics(engine: 'fake', frameRate: 25, demuxerSeekOffset: offset);

  @override
  Future<bool> stepForward() {
    calls.add('fwd');
    if (forwardTimesOut) return _after(() {}, result: false);
    return _after(() => pos += frame);
  }

  @override
  Future<bool> stepBackward() {
    calls.add('back');
    if (hangBackSteps) return Completer<bool>().future;
    final stuck = offset == Duration.zero && pos.inMilliseconds % 400 == 0;
    return _after(() => pos = stuck ? pos : pos - frame);
  }

  @override
  Future<bool> seekAndWait(Duration time, {required bool relative, SeekMode mode = SeekMode.exact}) {
    calls.add('seek ${relative ? 'rel' : 'abs'} ${mode.name}');
    var target = relative ? pos + time : time;
    // Land on the frame grid; keyframe seeks on the 2 s keyframe grid.
    final grid = mode == SeekMode.keyframe ? 2000 : 40;
    target = Duration(milliseconds: target.inMilliseconds ~/ grid * grid);
    return _after(() => pos = target);
  }

  @override
  Future<void> overrideDemuxerSeekOffset(Duration? value) async {
    calls.add('offset ${value?.inSeconds}');
    offset = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

void main() {
  group('statistics', () {
    test('nearest-rank quantiles match bench.lua', () {
      final s = TimingStats.of([for (var i = 20; i >= 1; i--) i.toDouble()]);
      expect([s.n, s.min, s.median, s.p90, s.p95, s.max], [20, 1, 11, 18, 19, 20]);
      expect(TimingStats.of([7]).toJson(), {
        'n': 1,
        'minMs': 7.0,
        'medianMs': 7.0,
        'p90Ms': 7.0,
        'p95Ms': 7.0,
        'maxMs': 7.0,
      });
      expect(TimingStats.of([]).toJson()['medianMs'], isNull);
    });

    test('a step is exact within half a frame of one frame', () {
      StepLanding back(int fromMs, int toMs) => classifyStep(
        from: Duration(milliseconds: fromMs),
        to: Duration(milliseconds: toMs),
        forward: false,
        frame: frame,
      );
      expect(back(1000, 960), StepLanding.exact);
      expect(back(1000, 979), StepLanding.exact); // 21 ms: just over half a frame
      expect(back(1000, 940), StepLanding.exact); // 1.5 frames
      expect(back(1000, 980), StepLanding.stuck); // exactly half a frame
      expect(back(1000, 1000), StepLanding.stuck);
      expect(back(1000, 939), StepLanding.skipped);
      expect(back(1000, 2016), StepLanding.wrongDirection); // late .ts landing
      expect(classifyStep(from: Duration.zero, to: frame, forward: true, frame: frame), StepLanding.exact);
    });
  });

  group('runner', () {
    test('measures every bench.lua series and compares .ts offsets', () {
      fakeAsync((async) {
        final engine = FakeBenchEngine();
        final progress = <String>[];
        BenchmarkMeasurements? result;
        EngineBenchmark(
          engine,
          elapsed: () => async.elapsed,
          onProgress: progress.add,
        ).run(mpegTs: true).then((r) => result = r);
        async.elapse(const Duration(minutes: 5));
        final json = result!.toJson();
        final tests = json['tests'] as Map<String, Object?>;
        expect(tests.keys, [
          'fwd_step_1',
          'back_step_1',
          'back_step_1_offset0',
          'fwd_step_2',
          'back_step_2',
          'back_step_2_offset0',
          'seek_far_keyframe',
          'seek_far_exact',
          'seek_fwd5_exact',
          'seek_back5_exact',
          'seek_back5_keyframe',
        ]);
        final back = tests['back_step_1'] as Map<String, Object?>;
        expect(back['n'], 20);
        expect(back['medianMs'], 50.0);
        expect(back['landings'], {'exact': 20, 'stuck': 0, 'skipped': 0, 'wrongDirection': 0});
        expect((tests['seek_far_exact'] as Map)['n'], 10);
        expect((tests['seek_far_exact'] as Map).containsKey('landings'), isFalse);

        final summary = json['summary'] as Map<String, Object?>;
        expect(summary['backStep'], containsPair('exact', 40));
        expect(summary['backStep'], containsPair('attempted', 40));
        // With offset 0 the fake sticks on each keyframe it reaches.
        final offset0 = summary['backStepOffset0'] as Map<String, Object?>;
        expect(offset0['stuck'], greaterThan(0));
        expect((offset0['exact'] as int) + (offset0['stuck'] as int), 40);
        expect(summary['exactSeekMedianMs'], 50.0);
        expect(summary['timeouts'], 0);
        expect(json['frameMs'], 40.0);

        // The override is applied only around the offset-0 series.
        expect(engine.calls.where((c) => c.startsWith('offset')), [
          'offset 0',
          'offset null',
          'offset 0',
          'offset null',
        ]);
        expect(engine.offset, isNull);
        expect(progress, contains('Back steps, offset 0 20/20'));
      });
    });

    test('other files get no offset-0 series and no override', () {
      fakeAsync((async) {
        final engine = FakeBenchEngine();
        BenchmarkMeasurements? result;
        EngineBenchmark(engine, elapsed: () => async.elapsed).run(mpegTs: false).then((r) => result = r);
        async.elapse(const Duration(minutes: 5));
        expect(result!.series.map((s) => s.name), isNot(contains(endsWith('_offset0'))));
        expect(result!.summary()['backStepOffset0'], isNull);
        expect(engine.calls.where((c) => c.startsWith('offset')), isEmpty);
      });
    });

    test('hung operations time out and a series gives up after three in a row', () {
      fakeAsync((async) {
        final engine = FakeBenchEngine()..hangBackSteps = true;
        BenchmarkMeasurements? result;
        EngineBenchmark(
          engine,
          options: const BenchmarkOptions(timeout: Duration(seconds: 1)),
          elapsed: () => async.elapsed,
        ).run(mpegTs: false).then((r) => result = r);
        async.elapse(const Duration(minutes: 5));
        final back = result!.series.firstWhere((s) => s.name == 'back_step_1');
        expect(back.samplesMs, isEmpty);
        expect(back.timeouts, 20);
        expect(back.landings, [StepLanding.stuck, StepLanding.stuck, StepLanding.stuck]);
        expect(engine.calls.where((c) => c == 'back').length, 6); // 3 per place
        expect(result!.summary()['timeouts'], 40);
      });
    });

    test("the engine's own step timeout counts as a timeout, not a sample", () {
      fakeAsync((async) {
        final engine = FakeBenchEngine()..forwardTimesOut = true;
        BenchmarkMeasurements? result;
        EngineBenchmark(engine, elapsed: () => async.elapsed).run(mpegTs: false).then((r) => result = r);
        async.elapse(const Duration(minutes: 5));
        final fwd = result!.series.firstWhere((s) => s.name == 'fwd_step_1');
        expect(fwd.samplesMs, isEmpty);
        expect(fwd.timeouts, 20);
      });
    });

    test('cancel stops a waiting operation at once and restores the .ts offset', () {
      fakeAsync((async) {
        final engine = FakeBenchEngine();
        final benchmark = EngineBenchmark(engine, elapsed: () => async.elapsed);
        Object? error;
        benchmark.run(mpegTs: true).catchError((Object e) {
          error = e;
          return BenchmarkMeasurements(
            diagnostics: const EngineDiagnostics(engine: 'x'),
            series: [],
            frame: null,
          );
        });
        // Into the first offset-0 series: 1 seek + 20 + 20 steps + 1 seek + a few steps.
        async.elapse(const Duration(milliseconds: 50 * 45 + 10));
        expect(engine.offset, Duration.zero);
        engine.hangBackSteps = true;
        async.elapse(const Duration(milliseconds: 100));
        final sent = engine.calls.length;
        benchmark.cancel();
        async.flushMicrotasks();
        expect(error, isA<BenchmarkCancelled>());
        expect(engine.offset, isNull);
        async.elapse(const Duration(minutes: 5));
        expect(engine.calls.length, sent + 1); // only the restore
      });
    });

    test('a file that never loads fails instead of hanging', () {
      fakeAsync((async) {
        final engine = _UnloadedEngine();
        Object? error;
        EngineBenchmark(engine, elapsed: () => async.elapsed).run(mpegTs: false).catchError((Object e) {
          error = e;
          return BenchmarkMeasurements(
            diagnostics: const EngineDiagnostics(engine: 'x'),
            series: [],
            frame: null,
          );
        });
        async.elapse(const Duration(seconds: 61));
        expect(error, isA<TimeoutException>());
      });
    });
  });

  group('results', () {
    const file = BenchFile(rootId: 'r1', path: 'Show/ep 01.ts', fileId: 'f1', sizeBytes: 1000);

    test('a record round-trips through the JSON Lines file into a table row', () async {
      final measurements = BenchmarkMeasurements(
        diagnostics: const EngineDiagnostics(
          engine: 'mpv',
          codec: 'h264',
          pixelFormat: 'yuv420p',
          container: 'mpegts',
          frameRate: 60,
          demuxerSeekOffset: Duration(seconds: 3),
        ),
        frame: const Duration(microseconds: 16667),
        series: [
          Series('back_step_1')
            ..samplesMs.addAll([10, 20, 30])
            ..landings.addAll([StepLanding.exact, StepLanding.exact, StepLanding.stuck]),
          Series('back_step_1_offset0')
            ..samplesMs.add(5)
            ..timeouts = 1
            ..landings.addAll([StepLanding.stuck, StepLanding.stuck]),
          Series('seek_far_exact')..samplesMs.addAll([100, 300]),
        ],
      );
      final record = benchmarkRecord(
        time: DateTime.utc(2026, 1, 2, 3, 4, 5),
        appVersion: '1.2.3',
        device: {'os': 'android', 'model': 'Phone'},
        file: file,
        measurements: measurements.toJson(),
      );
      final dir = await Directory.systemTemp.createTemp('vokoma-bench');
      addTearDown(() => dir.delete(recursive: true));
      final log = ResultsLog(File('${dir.path}/sub/results.jsonl'));
      await log.append(record);
      await log.append(
        benchmarkRecord(
          time: DateTime.utc(2026, 1, 2, 3, 5),
          appVersion: '1.2.3',
          device: const {},
          file: file,
          error: 'Could not open',
        ),
      );
      final text = await log.read();
      expect(const LineSplitter().convert(text), hasLength(2));
      final first = jsonDecode(const LineSplitter().convert(text).first) as Map<String, dynamic>;
      expect(first['schema'], 1);
      expect(first['time'], '2026-01-02T03:04:05.000Z');
      expect(first['file'], containsPair('mpegTs', true));
      expect(first['engine'], containsPair('demuxerSeekOffsetSeconds', 3.0));
      expect(first.containsKey('error'), isFalse);

      final rows = ResultsLog.rowsOf(text);
      expect(rows.first.error, 'Could not open'); // newest first
      final row = rows.last;
      expect(row.file, 'ep 01.ts');
      expect(row.kind, 'h264 yuv420p · mpegts · software');
      expect(row.backStep, containsPair('medianMs', 20.0));
      expect(row.backStep, containsPair('exact', 2));
      expect(row.backStep, containsPair('stuck', 1));
      expect(row.backStepOffset0, containsPair('attempted', 2));
      expect(row.backStepOffset0, containsPair('timeouts', 1));
      expect(row.exactSeekMedianMs, 300.0);
      expect(row.timeouts, 1);
    });

    test('the benchmark set adds without duplicates and clears', () async {
      SharedPreferences.setMockInitialValues({});
      final set = await BenchmarkSet.open();
      expect(await set.add([file, file]), 1);
      final other = BenchFile.of(
        'r1',
        '',
        const FileEntry('clip.mkv', fileId: 'f2', sizeBytes: 5, duration: Duration(seconds: 90)),
      );
      expect(await set.add([file, other]), 1);
      expect(set.files.map((f) => f.path), ['Show/ep 01.ts', 'clip.mkv']);
      expect(set.files.last.duration, const Duration(seconds: 90));
      await set.clear();
      expect(set.files, isEmpty);
    });
  });
}

class _UnloadedEngine extends FakeBenchEngine {
  @override
  Duration get duration => Duration.zero;
  @override
  Stream<Duration> get durationStream => StreamController<Duration>().stream; // never emits
}
