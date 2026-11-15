import 'package:flutter/services.dart';

/// What a key does in the player. The M0 set from docs/milestones/M0.md.
sealed class PlayerAction {
  const PlayerAction();

  /// Whether holding the key repeats the action.
  bool get repeats => false;
}

class TogglePlay extends PlayerAction {
  const TogglePlay();
}

class SeekBy extends PlayerAction {
  const SeekBy(this.offset);
  final Duration offset;
  @override
  bool get repeats => true;
  @override
  bool operator ==(Object other) => other is SeekBy && other.offset == offset;
  @override
  int get hashCode => offset.hashCode;
}

class StepFrame extends PlayerAction {
  const StepFrame({required this.forward});
  final bool forward;
  @override
  bool get repeats => true;
  @override
  bool operator ==(Object other) => other is StepFrame && other.forward == forward;
  @override
  int get hashCode => forward.hashCode;
}

class ChangeSpeed extends PlayerAction {
  const ChangeSpeed(this.delta);
  final double delta;
  @override
  bool get repeats => true;
  @override
  bool operator ==(Object other) => other is ChangeSpeed && other.delta == delta;
  @override
  int get hashCode => delta.hashCode;
}

/// Normal speed, or back to the speed before it.
class ToggleNormalSpeed extends PlayerAction {
  const ToggleNormalSpeed();
}

class ToggleFullscreen extends PlayerAction {
  const ToggleFullscreen();
}

class ToggleMute extends PlayerAction {
  const ToggleMute();
}

/// Leaves fullscreen, or the player when not fullscreen.
class Back extends PlayerAction {
  const Back();
}

/// Seek sizes for the arrow keys (docs/ARCHITECTURE.md, section 8).
const seekPlain = Duration(seconds: 5);
const seekShift = Duration(seconds: 30);
const seekCtrl = Duration(seconds: 90);
const seekAlt = Duration(seconds: 1);
const speedStep = 0.1;

/// Maps a key press to an action, or null when the key does nothing.
///
/// Modifiers must match exactly, so for example plain `M` and number keys do
/// nothing (PLAN.md: number keys must not jump around the timeline). No
/// binding uses [meta] (the Windows key), so any key held with it does nothing.
PlayerAction? actionFor(
  LogicalKeyboardKey key, {
  bool shift = false,
  bool ctrl = false,
  bool alt = false,
  bool meta = false,
}) {
  final none = !shift && !ctrl && !alt && !meta;
  final count = (shift ? 1 : 0) + (ctrl ? 1 : 0) + (alt ? 1 : 0) + (meta ? 1 : 0);

  if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
    if (count > 1 || meta) return null;
    final size = shift
        ? seekShift
        : ctrl
        ? seekCtrl
        : alt
        ? seekAlt
        : seekPlain;
    return SeekBy(key == LogicalKeyboardKey.arrowLeft ? -size : size);
  }
  if (key == LogicalKeyboardKey.keyM) {
    return (count == 1 && (shift || ctrl)) ? const ToggleMute() : null;
  }
  if (!none) return null;
  return switch (key) {
    LogicalKeyboardKey.space => const TogglePlay(),
    LogicalKeyboardKey.comma => const StepFrame(forward: false),
    LogicalKeyboardKey.period => const StepFrame(forward: true),
    LogicalKeyboardKey.bracketLeft => const ChangeSpeed(-speedStep),
    LogicalKeyboardKey.bracketRight => const ChangeSpeed(speedStep),
    LogicalKeyboardKey.slash => const ToggleNormalSpeed(),
    LogicalKeyboardKey.keyF => const ToggleFullscreen(),
    LogicalKeyboardKey.escape => const Back(),
    _ => null,
  };
}

/// [actionFor] with the modifiers currently held on [keyboard].
PlayerAction? actionForKeyboard(LogicalKeyboardKey key, HardwareKeyboard keyboard) => actionFor(
  key,
  shift: keyboard.isShiftPressed,
  ctrl: keyboard.isControlPressed,
  alt: keyboard.isAltPressed,
  meta: keyboard.isMetaPressed,
);
