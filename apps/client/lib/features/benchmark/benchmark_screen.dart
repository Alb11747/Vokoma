import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/api.dart';
import '../../api/media_proxy.dart';
import '../../engine/mpv_engine.dart';
import '../../engine/player_engine.dart';
import '../../platform/device.dart';
import '../../updates/update_service.dart';
import 'results.dart';
import 'results_screen.dart';
import 'runner.dart';

/// Starts a benchmark run on [files], unless something is playing or an
/// update is being installed. Playback is reserved before navigation, as
/// the browser does for the player.
void startBenchmark(BuildContext context, Api api, List<BenchFile> files) {
  final updates = UpdateService.instance;
  final reason = files.isEmpty
      ? 'The benchmark set is empty.'
      : updates.installing
      ? 'An update is being installed.'
      : updates.playerOpen
      ? 'Close the player first.'
      : null;
  if (reason != null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(reason)));
    return;
  }
  final release = updates.reservePlayer();
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => BenchmarkScreen(api: api, files: files, releasePlayback: release),
    ),
  );
}

/// Runs the benchmark file by file, with the video visible, a progress
/// line and Cancel. Each file gets a fresh engine, as each bench.lua run
/// got a fresh mpv. Ends on the results screen.
class BenchmarkScreen extends StatefulWidget {
  const BenchmarkScreen({super.key, required this.api, required this.files, required this.releasePlayback});

  final Api api;
  final List<BenchFile> files;
  final VoidCallback releasePlayback;

  @override
  State<BenchmarkScreen> createState() => _BenchmarkScreenState();
}

class _BenchmarkScreenState extends State<BenchmarkScreen> {
  PlayerEngine? _engine;
  EngineBenchmark? _benchmark;
  int _index = 0;
  String _progress = 'Starting';
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    unawaited(Device.keepScreenOn(true));
    unawaited(_runAll());
  }

  @override
  void dispose() {
    _cancel();
    unawaited(Device.keepScreenOn(false));
    super.dispose();
  }

  void _cancel() {
    _cancelled = true;
    _benchmark?.cancel();
  }

  Future<void> _runAll() async {
    try {
      final log = await ResultsLog.open();
      final device = await Device.info();
      for (_index = 0; _index < widget.files.length && !_cancelled; _index++) {
        final record = await _runOne(widget.files[_index], device);
        if (record != null) await log.append(record);
      }
    } catch (error) {
      if (mounted) _show('The benchmark stopped: $error');
    } finally {
      widget.releasePlayback();
    }
    if (!mounted) return;
    if (_cancelled) {
      Navigator.of(context).pop();
    } else {
      await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => const ResultsScreen()));
    }
  }

  /// The record for [file], or null when cancelled. Failures become a
  /// record with an error, so a file that cannot be measured still shows.
  Future<Map<String, Object?>?> _runOne(BenchFile file, Map<String, Object?> device) async {
    final engine = MpvEngine();
    final benchmark = EngineBenchmark(engine, onProgress: (p) => mounted ? setState(() => _progress = p) : null);
    final errors = <String>[];
    final errorSubscription = engine.errorStream.listen(errors.add);
    setState(() {
      _engine = engine;
      _benchmark = benchmark;
      _progress = 'Opening';
    });
    MediaProxy? proxy;
    final started = DateTime.now();
    Map<String, Object?>? measurements;
    String? error;
    try {
      proxy = await MediaProxy.start(widget.api);
      await engine.open(proxy.uriFor(file.fileId), httpHeaders: proxy.playerHeaders, fileName: file.name, play: false);
      measurements = (await benchmark.run(mpegTs: file.isMpegTs)).toJson();
    } on BenchmarkCancelled {
      return null;
    } catch (e) {
      error = [e.toString(), ...errors].join('; ');
    } finally {
      if (mounted) setState(() => _engine = null);
      await errorSubscription.cancel();
      await engine.dispose();
      await proxy?.close();
    }
    return benchmarkRecord(
      time: started,
      appVersion: UpdateService.instance.currentVersion,
      device: device,
      file: file,
      measurements: measurements,
      error: error,
    );
  }

  void _show(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final engine = _engine;
    final total = widget.files.length;
    final file = widget.files[_index.clamp(0, total - 1)];
    return PopScope(
      onPopInvokedWithResult: (didPop, _) => _cancel(),
      child: Scaffold(
        appBar: AppBar(title: const Text('Engine benchmark')),
        body: Column(
          children: [
            Expanded(
              child: ColoredBox(
                color: Colors.black,
                // A fresh subtree per engine, so the old surface is not reused.
                child: engine == null
                    ? const SizedBox.expand()
                    : KeyedSubtree(key: ObjectKey(engine), child: engine.buildView()),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'File ${_index + 1} of $total: ${file.name}\n$_progress',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 16),
                  OutlinedButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Cancel')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
