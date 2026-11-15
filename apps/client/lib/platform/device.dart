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

  /// A short label for the device, such as `Google Pixel 8` or `windows`,
  /// sent with uploaded benchmark results.
  static Future<String> label() async {
    final info = await Device.info();
    final model = [info['manufacturer'], info['model']].whereType<String>().join(' ');
    return model.isEmpty ? Platform.operatingSystem : model;
  }

  /// The Android share sheet with a snapshot of [path], an app file, sent
  /// as a content URI. Android only.
  static Future<void> shareFile(String path, {String? subject}) =>
      _channel.invokeMethod<void>('shareFile', {'path': path, 'subject': subject});

  /// Keeps the screen on during a benchmark run. Android only; a no-op elsewhere.
  static Future<void> keepScreenOn(bool on) async {
    if (Platform.isAndroid) await _channel.invokeMethod<void>('keepScreenOn', on);
  }
}
