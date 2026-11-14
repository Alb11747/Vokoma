import 'dart:collection';

import '../../engine/player_engine.dart';
import 'hotkeys.dart';

/// Player behaviour on top of a [PlayerEngine]: speed rules and the pacing of
/// frame steps. Window actions (fullscreen, leaving) belong to the screen.
class PlayerController {
  PlayerController(this.engine);

  static const minSpeed = 0.25;
  static const maxSpeed = 4.0;

  final PlayerEngine engine;

  /// The speed `/` returns to after switching to normal speed.
  double? previousSpeed;

  final _steps = Queue<bool>();
  Future<void>? _stepping;

  /// Runs an engine action. [isRepeat] is true for auto-repeat while the key
  /// is held. Returns a short description for the on-screen display.
  Future<String?> perform(PlayerAction action, {bool isRepeat = false}) async {
    if (isRepeat && !action.repeats) return null;
    switch (action) {
      case TogglePlay():
        await engine.playOrPause();
        return null;
      case SeekBy(:final offset):
        await engine.seekBy(offset);
        return null;
      case StepFrame(:final forward):
        step(forward: forward, isRepeat: isRepeat);
        return null;
      case ChangeSpeed(:final delta):
        final speed = clampSpeed(engine.speed + delta);
        await engine.setSpeed(speed);
        return _speedLabel(speed);
      case ToggleNormalSpeed():
        final current = engine.speed;
        if (current != 1.0) {
          previousSpeed = current;
          await engine.setSpeed(1.0);
          return _speedLabel(1.0);
        }
        final previous = previousSpeed;
        if (previous == null) return _speedLabel(1.0);
        await engine.setSpeed(previous);
        return _speedLabel(previous);
      case ToggleMute():
        final muted = !engine.muted;
        await engine.setMuted(muted);
        return muted ? 'Muted' : 'Sound on';
      case ToggleFullscreen() || Back():
        return null;
    }
  }

  /// Queues one frame step. Each key press steps once, however slow the step
  /// is; while the key is held, a repeat is only taken when no step is
  /// running, so releasing the key stops stepping at once instead of
  /// draining a backlog. Back steps cost 20–500 ms depending on the file.
  void step({required bool forward, bool isRepeat = false}) {
    if (isRepeat && _stepping != null) return;
    _steps.add(forward);
    _stepping ??= _drainSteps();
  }

  /// Completes when no step is queued or running.
  Future<void> get stepsIdle => _stepping ?? Future.value();

  Future<void> _drainSteps() async {
    try {
      while (_steps.isNotEmpty) {
        final forward = _steps.removeFirst();
        await (forward ? engine.stepForward() : engine.stepBackward());
      }
    } finally {
      // Cleared in the same synchronous run as the final empty check, so a
      // step queued later always starts a new drain.
      _stepping = null;
    }
  }

  /// Clamps to [minSpeed]–[maxSpeed] and rounds to 0.05 so repeated ±0.1
  /// steps do not drift (0.1 is not exact in binary).
  static double clampSpeed(double speed) {
    final rounded = (speed * 20).round() / 20;
    return rounded.clamp(minSpeed, maxSpeed);
  }

  static String _speedLabel(double speed) => '${speed.toStringAsFixed(2)}×';
}
