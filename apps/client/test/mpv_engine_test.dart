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

  test('a step completes when the position moves', () {
    fakeAsync((async) {
      final positions = StreamController<Duration>.broadcast();
      var done = false;
      nextPositionChange(
        positions.stream,
        const Duration(seconds: 10),
        const Duration(seconds: 3),
      ).then((_) => done = true);
      positions.add(const Duration(seconds: 10)); // same frame reported again
      async.flushMicrotasks();
      expect(done, isFalse);
      positions.add(const Duration(milliseconds: 9983));
      async.flushMicrotasks();
      expect(done, isTrue);
      expect(positions.hasListener, isFalse);
    });
  });

  test('a step that cannot move (first frame) completes after the timeout', () {
    fakeAsync((async) {
      final positions = StreamController<Duration>.broadcast();
      var done = false;
      nextPositionChange(positions.stream, Duration.zero, const Duration(seconds: 3)).then((_) => done = true);
      async.elapse(const Duration(milliseconds: 2999));
      expect(done, isFalse);
      async.elapse(const Duration(milliseconds: 1));
      expect(done, isTrue);
    });
  });
}
