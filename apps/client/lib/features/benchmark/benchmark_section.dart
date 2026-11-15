import 'package:flutter/material.dart';

import '../../api/api.dart';
import 'benchmark_screen.dart';
import 'results.dart';
import 'results_screen.dart';

/// The Benchmark part of About: run the standard set, fill or clear it,
/// see results. [folderFiles] are the files of the folder the browser is
/// showing, if any.
class BenchmarkSection extends StatefulWidget {
  const BenchmarkSection({super.key, required this.api, this.folderFiles = const []});

  final Api api;
  final List<BenchFile> folderFiles;

  @override
  State<BenchmarkSection> createState() => _BenchmarkSectionState();
}

class _BenchmarkSectionState extends State<BenchmarkSection> {
  /// Most files one press of Add takes from a folder.
  static const _sampleSize = 6;

  BenchmarkSet? _set;

  @override
  void initState() {
    super.initState();
    BenchmarkSet.open().then((set) {
      if (mounted) setState(() => _set = set);
    });
  }

  Future<void> _add() async {
    final added = await _set!.add(sampleEvenly(widget.folderFiles, _sampleSize));
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added $added files')));
  }

  Future<void> _clear() async {
    await _set!.clear();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final set = _set;
    if (set == null) return const SizedBox.shrink();
    final files = set.files;
    final folderCount = widget.folderFiles.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Text('Benchmark', style: Theme.of(context).textTheme.titleMedium),
        Text('Standard set: ${files.length} files'),
        if (files.isEmpty && widget.folderFiles.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'To benchmark one file, go back, open a folder and long-press (or right-click) a file. '
              'To build a set, open About from inside a folder that contains video files.',
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: files.isEmpty ? null : () => startBenchmark(context, widget.api, files),
              child: Text('Run on the standard set (${files.length} ${files.length == 1 ? 'file' : 'files'})'),
            ),
            OutlinedButton(
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ResultsScreen(api: widget.api))),
              child: const Text('Results'),
            ),
            if (widget.folderFiles.isNotEmpty)
              OutlinedButton(
                onPressed: _add,
                child: Text(
                  folderCount > _sampleSize
                      ? 'Add $_sampleSize sample files from this folder (of $folderCount)'
                      : "Add this folder's $folderCount ${folderCount == 1 ? 'file' : 'files'} to the benchmark set",
                ),
              ),
            OutlinedButton(onPressed: files.isEmpty ? null : _clear, child: const Text('Clear set')),
          ],
        ),
      ],
    );
  }
}
