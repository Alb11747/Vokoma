import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vokoma/engine/player_engine.dart';
import 'package:vokoma/features/player/hotkeys.dart';
import 'package:vokoma/features/player/player_controller.dart';

/// Records calls; steps complete only when the test releases them.
class FakeEngine implements PlayerEngine {
  final calls = <String>[];
  final pendingSteps = <Completer<bool>>[];
  @override
  double speed = 1.0;
  @override
  bool muted = false;

  void finishStep() => pendingSteps.removeAt(0).complete(true);

  @override
  Future<bool> stepBackward() => _step('back');
  @override
  Future<bool> stepForward() => _step('forward');
  Future<bool> _step(String name) {
    calls.add(name);
    final c = Completer<bool>();
    pendingSteps.add(c);
    return c.future;
  }

  @override
  Future<void> setSpeed(double value) async {
    calls.add('speed $value');
    speed = value;
  }

  @override
  Future<void> setMuted(bool value) async {
    calls.add('mute $value');
    muted = value;
  }

  @override
  Future<void> seekBy(Duration offset, {SeekMode mode = SeekMode.exact}) async =>
      calls.add('seekBy ${offset.inSeconds} ${mode.name}');
  @override
  Future<void> playOrPause() async => calls.add('playOrPause');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeEngine engine;
  late PlayerController c;

  setUp(() {
    engine = FakeEngine();
    c = PlayerController(engine);
  });

  test('arrow seeks are exact', () async {
    await c.perform(const SeekBy(Duration(seconds: -30)));
    expect(engine.calls, ['seekBy -30 exact']);
  });

  test('speed steps by 0.1 without drift and stays within 0.25–4', () async {
    for (var i = 0; i < 7; i++) {
      await c.perform(const ChangeSpeed(0.1));
    }
    expect(engine.speed, 1.7);
    engine.speed = 3.95;
    await c.perform(const ChangeSpeed(0.1));
    expect(engine.speed, 4.0);
    engine.speed = 0.3;
    await c.perform(const ChangeSpeed(-0.1));
    expect(engine.speed, 0.25);
    expect(await c.perform(const ChangeSpeed(-0.1)), '0.25×');
  });

  test('/ switches to normal speed and back to the previous speed', () async {
    expect(await c.perform(const ToggleNormalSpeed()), '1.00×');
    expect(engine.calls, isEmpty, reason: 'no previous speed yet');
    engine.speed = 1.8;
    await c.perform(const ToggleNormalSpeed());
    expect(engine.speed, 1.0);
    await c.perform(const ToggleNormalSpeed());
    expect(engine.speed, 1.8);
  });

  test('mute toggles', () async {
    expect(await c.perform(const ToggleMute()), 'Muted');
    expect(await c.perform(const ToggleMute()), 'Sound on');
  });

  test('auto-repeat is ignored for non-repeating actions', () async {
    await c.perform(const TogglePlay(), isRepeat: true);
    await c.perform(const ToggleMute(), isRepeat: true);
    expect(engine.calls, isEmpty);
    await c.perform(const TogglePlay());
    expect(engine.calls, ['playOrPause']);
  });

  test('every press steps once, in order, one at a time', () async {
    c.step(forward: false);
    c.step(forward: false);
    c.step(forward: true);
    await settle();
    expect(engine.calls, ['back'], reason: 'the next step waits for the frame');
    engine.finishStep();
    await settle();
    engine.finishStep();
    await settle();
    expect(engine.calls, ['back', 'back', 'forward']);
    engine.finishStep();
    await c.stepsIdle;
  });

  test('holding the key repeats only when the last step has landed', () async {
    c.step(forward: false); // key down
    for (var i = 0; i < 10; i++) {
      c.step(forward: false, isRepeat: true); // OS auto-repeat during a slow step
    }
    await settle();
    engine.finishStep();
    await c.stepsIdle;
    expect(engine.calls, ['back']);
    c.step(forward: false, isRepeat: true);
    await settle();
    expect(engine.calls, ['back', 'back']);
    engine.finishStep();
    await c.stepsIdle;
  });

  test('a step queued right as the queue drains still runs', () async {
    c.step(forward: true);
    await settle();
    engine.finishStep();
    c.step(forward: true);
    await settle();
    expect(engine.calls, ['forward', 'forward']);
    engine.finishStep();
    await c.stepsIdle;
  });
}
