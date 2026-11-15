import 'dart:io';

import 'package:flutter/services.dart';

/// Device facts and sharing for the engine benchmark. Android implements
/// them in MainActivity.kt; elsewhere they come from dart:io.
class Device {
  static const _channel = MethodChannel('app.vokoma/device');

  static Future<Map<String, Object?>> info() async {
    final base = <String, Object?>{
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'processors': Platform.numberOfProcessors,
    };
    if (!Platform.isAndroid) return base;
    final android = await _channel.invokeMapMethod<String, Object?>('info');
    return {...base, ...?android};
  }

  /// The Android share sheet with [text]. Android only.
  static Future<void> shareText(String text, {String? subject}) =>
      _channel.invokeMethod<void>('shareText', {'text': text, 'subject': subject});

  /// Keeps the screen on during a benchmark run. Android only; a no-op elsewhere.
  static Future<void> keepScreenOn(bool on) async {
    if (Platform.isAndroid) await _channel.invokeMethod<void>('keepScreenOn', on);
  }
}
