import 'package:flutter/services.dart';

/// Window actions implemented in the Windows runner
/// (windows/runner/flutter_window.cpp).
class AppWindow {
  static const _channel = MethodChannel('vokoma/window');

  /// Borderless fullscreen on the window's monitor. Windows only.
  static Future<void> setFullscreen(bool fullscreen) => _channel.invokeMethod<void>('setFullscreen', fullscreen);
}
