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
    late Duration current;
    late bool sent;
    bool? result;

    void start(FrameCommand kind, {Duration from = const Duration(seconds: 10), bool seekingAtStart = false}) {
      positions = StreamController<Duration>.broadcast(sync: true);
      seeking = StreamController<bool>.broadcast(sync: true);
      isSeeking = seekingAtStart;
      current = from;
      sent = false;
      result = null;
      runUntilFrameShown(
        kind: kind,
        send: () async => sent = true,
        positions: positions.stream,
        position: () => current,
        seeking: seeking.stream,
        isSeeking: () => isSeeking,
        timeout: const Duration(seconds: 3),
      ).then((s) => result = s);
    }

    void seek(bool on) {
      isSeeking = on;
      seeking.add(on);
    }

    void move(int ms) {
      current = Duration(milliseconds: ms);
      positions.add(current);
    }

    test('a back step completes on its own seek, not on position ticks', () {
      fakeAsync((async) {
        start(FrameCommand.backward);
        async.flushMicrotasks();
        move(10016); // playback still ticking forward
        seek(true);
        move(9983);
        async.flushMicrotasks();
        expect(result, isNull);
        seek(false);
        async.flushMicrotasks();
        expect(result, isTrue);
        expect(positions.hasListener || seeking.hasListener, isFalse);
      });
    });

    test('an initial or stale seeking=false does not complete a back step or seek', () {
      for (final kind in [FrameCommand.backward, FrameCommand.seek]) {
        fakeAsync((async) {
          start(kind);
          async.flushMicrotasks();
          seek(false); // mpv's initial notification, or a late one
          async.flushMicrotasks();
          expect(result, isNull, reason: '$kind');
          seek(true);
          seek(false);
          async.flushMicrotasks();
          expect(result, isTrue, reason: '$kind');
        });
      }
    });

    test('a fast back step whose seek notifications coalesced completes on the move', () {
      fakeAsync((async) {
        start(FrameCommand.backward);
        async.flushMicrotasks();
        move(9983);
        async.flushMicrotasks();
        expect(result, isTrue);
        expect(async.elapsed, lessThan(const Duration(seconds: 1)));
      });
    });

    test('a command sent while a seek runs waits for that seek to end first', () {
      fakeAsync((async) {
        start(FrameCommand.backward, seekingAtStart: true);
        async.flushMicrotasks();
        expect(sent, isFalse);
        seek(false); // the earlier seek ends; not ours
        async.flushMicrotasks();
        expect(sent, isTrue);
        expect(result, isNull);
        seek(true);
        seek(false);
        async.flushMicrotasks();
        expect(result, isTrue);
      });
    });

    test('a back step slower than the timeout is not released before its seek ends', () {
      fakeAsync((async) {
        start(FrameCommand.backward);
        async.flushMicrotasks();
        seek(true);
        async.elapse(const Duration(seconds: 10));
        expect(result, isNull);
        seek(false);
        async.flushMicrotasks();
        expect(result, isTrue);
      });
    });

    test('a forward frame delivered during a seek counts once the seek clears', () {
      fakeAsync((async) {
        start(FrameCommand.forward);
        async.flushMicrotasks();
        move(10000); // same frame reported again
        seek(true);
        move(10016);
        async.flushMicrotasks();
        expect(result, isNull);
        seek(false); // no further position event follows
        async.flushMicrotasks();
        expect(result, isTrue);
        expect(async.elapsed, lessThan(const Duration(seconds: 1)));
      });
    });

    test('a forward step completes on a move outside a seek', () {
      fakeAsync((async) {
        start(FrameCommand.forward);
        async.flushMicrotasks();
        move(10016);
        async.flushMicrotasks();
        expect(result, isTrue);
      });
    });

    test('a step that cannot move (first frame) completes false after the timeout', () {
      fakeAsync((async) {
        start(FrameCommand.backward, from: Duration.zero);
        async.elapse(const Duration(milliseconds: 2999));
        expect(result, isNull);
        async.elapse(const Duration(milliseconds: 1));
        expect(result, isFalse); // the benchmark counts this as a timeout
      });
    });
  });
}
