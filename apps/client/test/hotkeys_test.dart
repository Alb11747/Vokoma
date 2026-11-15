import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vokoma/features/player/hotkeys.dart';

typedef K = LogicalKeyboardKey;

void main() {
  const left = K.arrowLeft, right = K.arrowRight;

  test('arrow seek sizes: 5 s, Shift 30 s, Ctrl 90 s, Alt 1 s', () {
    expect(actionFor(right), const SeekBy(Duration(seconds: 5)));
    expect(actionFor(left), const SeekBy(Duration(seconds: -5)));
    expect(actionFor(right, shift: true), const SeekBy(Duration(seconds: 30)));
    expect(actionFor(left, ctrl: true), const SeekBy(Duration(seconds: -90)));
    expect(actionFor(right, alt: true), const SeekBy(Duration(seconds: 1)));
    expect(actionFor(right, shift: true, ctrl: true), isNull);
  });

  test('plain keys', () {
    expect(actionFor(K.space), isA<TogglePlay>());
    expect(actionFor(K.comma), const StepFrame(forward: false));
    expect(actionFor(K.period), const StepFrame(forward: true));
    expect(actionFor(K.bracketLeft), const ChangeSpeed(-0.1));
    expect(actionFor(K.bracketRight), const ChangeSpeed(0.1));
    expect(actionFor(K.slash), isA<ToggleNormalSpeed>());
    expect(actionFor(K.keyF), isA<ToggleFullscreen>());
    expect(actionFor(K.escape), isA<Back>());
  });

  test('mute is Shift+M or Ctrl+M; plain M and Alt+M do nothing', () {
    expect(actionFor(K.keyM, shift: true), isA<ToggleMute>());
    expect(actionFor(K.keyM, ctrl: true), isA<ToggleMute>());
    expect(actionFor(K.keyM), isNull);
    expect(actionFor(K.keyM, alt: true), isNull);
    expect(actionFor(K.keyM, shift: true, ctrl: true), isNull);
  });

  test('number keys do nothing, with or without modifiers', () {
    final digits = [
      K.digit0, K.digit1, K.digit2, K.digit3, K.digit4, K.digit5, K.digit6, K.digit7, K.digit8, K.digit9, //
      K.numpad0, K.numpad1, K.numpad2, K.numpad3, K.numpad4, K.numpad5, K.numpad6, K.numpad7, K.numpad8, K.numpad9,
    ];
    for (final d in digits) {
      expect(actionFor(d), isNull, reason: d.debugName);
      expect(actionFor(d, shift: true), isNull, reason: d.debugName);
      expect(actionFor(d, alt: true), isNull, reason: d.debugName);
    }
  });

  test('modified plain keys do nothing', () {
    expect(actionFor(K.space, ctrl: true), isNull);
    expect(actionFor(K.keyF, ctrl: true), isNull);
    expect(actionFor(K.comma, alt: true), isNull);
    expect(actionFor(K.escape, ctrl: true), isNull);
    expect(actionFor(K.escape, alt: true), isNull);
  });

  test('nothing is bound with the Windows (Meta) key', () {
    for (final key in [K.space, K.comma, K.keyF, K.escape, left, right, K.keyM]) {
      expect(actionFor(key, meta: true), isNull, reason: key.debugName);
    }
    expect(actionFor(K.keyM, shift: true, meta: true), isNull);
  });

  testWidgets('the player reads Meta from the keyboard', (tester) async {
    expect(actionForKeyboard(K.space, HardwareKeyboard.instance), isA<TogglePlay>());
    await simulateKeyDownEvent(K.metaLeft);
    expect(actionForKeyboard(K.space, HardwareKeyboard.instance), isNull);
    await simulateKeyUpEvent(K.metaLeft);
  });

  test('held keys repeat seeks, steps and speed only', () {
    expect(actionFor(right)!.repeats, isTrue);
    expect(actionFor(K.comma)!.repeats, isTrue);
    expect(actionFor(K.bracketRight)!.repeats, isTrue);
    for (final key in [K.space, K.slash, K.keyF, K.escape]) {
      expect(actionFor(key)!.repeats, isFalse, reason: key.debugName);
    }
    expect(actionFor(K.keyM, shift: true)!.repeats, isFalse);
  });
}
