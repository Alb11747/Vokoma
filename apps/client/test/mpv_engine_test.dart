import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vokoma/engine/mpv_engine.dart';
import 'package:vokoma/engine/player_engine.dart';

// MpvEngine's decisions that do not need libmpv or a GPU.
void main() {
  test('seek commands use exact or keyframe flags', () {
    expect(seekCommand(const Duration(seconds: -5), relative: true, mode: SeekMode.exact), [
      'seek',
      '-5.000000',
      'relative+exact',
    ]);
    expect(seekCommand(const Duration(milliseconds: 30123), relative: false, mode: SeekMode.keyframe), [
      'seek',
      '30.123000',
      'absolute+keyframes',
    ]);
  });

  test('MPEG-TS gets a demuxer offset longer than its keyframe interval', () {
    expect(hrSeekDemuxerOffsetFor('[2026-11-10T20:00:00Z] ch - title.TS'), '3');
    expect(hrSeekDemuxerOffsetFor('episode.mkv'), '0');
    expect(hrSeekDemuxerOffsetFor('clip.mp4'), '0');
    expect(hrSeekDemuxerOffsetFor(null), '0');
  });

  test('hardware decoding is auto-safe on Windows, media_kit default elsewhere', () {
    expect(defaultHwdec('windows'), 'auto-safe');
    expect(defaultHwdec('android'), isNull);
  });

  test('engine state from mpv flags', () {
    EngineState s({bool opened = true, bool playing = false, bool buffering = false, bool completed = false}) =>
        engineStateOf(opened: opened, playing: playing, buffering: buffering, completed: completed);
    expect(s(opened: false, playing: true), EngineState.idle);
    expect(s(completed: true, buffering: true), EngineState.ended);
    expect(s(buffering: true, playing: true), EngineState.buffering);
    expect(s(playing: true), EngineState.playing);
    expect(s(), EngineState.paused);
  });

  group('frame step completion', () {
    late StreamController<Duration> positions;
    late StreamController<bool> seeking;
    late bool isSeeking;
    late bool done;

    void start({required bool backward, Duration from = const Duration(seconds: 10)}) {
      positions = StreamController<Duration>.broadcast();
      seeking = StreamController<bool>.broadcast();
      isSeeking = false;
      done = false;
      frameStepDone(
        backward: backward,
        positions: positions.stream,
        from: from,
        seeking: seeking.stream,
        isSeeking: () => isSeeking,
        timeout: const Duration(seconds: 3),
      ).then((_) => done = true);
    }

    void seek(bool on) {
      isSeeking = on;
      seeking.add(on);
    }

    test('a back step waits for its seek to end, not for the position to move', () {
      fakeAsync((async) {
        start(backward: true);
        positions.add(const Duration(milliseconds: 10016)); // playback still ticking
        seek(true);
        positions.add(const Duration(milliseconds: 9983));
        async.flushMicrotasks();
        expect(done, isFalse);
        seek(false);
        async.flushMicrotasks();
        expect(done, isTrue);
        expect(positions.hasListener || seeking.hasListener, isFalse);
      });
    });

    test('a back step slower than the timeout is not released before its seek ends', () {
      fakeAsync((async) {
        start(backward: true);
        seek(true);
        async.elapse(const Duration(seconds: 10));
        expect(done, isFalse);
        seek(false);
        async.flushMicrotasks();
        expect(done, isTrue);
      });
    });

    test('a forward step completes when the position moves outside a seek', () {
      fakeAsync((async) {
        start(backward: false);
        positions.add(const Duration(seconds: 10)); // same frame reported again
        seek(true);
        positions.add(const Duration(seconds: 12)); // during an unrelated seek
        async.flushMicrotasks();
        expect(done, isFalse);
        seek(false);
        positions.add(const Duration(milliseconds: 12016));
        async.flushMicrotasks();
        expect(done, isTrue);
      });
    });

    test('a step that cannot move (first frame) completes after the timeout', () {
      fakeAsync((async) {
        start(backward: true, from: Duration.zero);
        async.elapse(const Duration(milliseconds: 2999));
        expect(done, isFalse);
        async.elapse(const Duration(milliseconds: 1));
        expect(done, isTrue);
      });
    });
  });
}
