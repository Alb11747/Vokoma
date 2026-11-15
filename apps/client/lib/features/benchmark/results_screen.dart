import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/api.dart';
import '../../platform/device.dart';
import '../../updates/update_service.dart';
import 'results.dart';

/// The results file as a table, newest first, with Share / copy and
/// Upload to server.
class ResultsScreen extends StatefulWidget {
  const ResultsScreen({super.key, required this.api});

  final Api api;

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  late final Future<(ResultsLog, String)> _load = () async {
    final log = await ResultsLog.open();
    return (log, await log.read());
  }();

  Future<void> _share(ResultsLog log, String content) async {
    if (Platform.isAndroid) return Device.shareFile(log.file.path, subject: 'Vokoma engine benchmark');
    await Clipboard.setData(ClipboardData(text: '${log.file.path}\n\n$content'));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('File path and results copied')));
    }
  }

  bool _uploading = false;

  /// Sends [content] to the server, which keeps it in its data directory.
  /// Share sheets on phones often refuse a file this large.
  Future<void> _upload(String content) async {
    setState(() => _uploading = true);
    String message;
    try {
      await widget.api.uploadBenchmark(
        content: content,
        device: await Device.label(),
        appVersion: UpdateService.instance.currentVersion,
      );
      message = 'Uploaded';
    } catch (error) {
      message = 'Upload failed: $error';
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Benchmark results')),
    body: FutureBuilder(
      future: _load,
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Text('Could not read the results: ${snapshot.error}'));
        final data = snapshot.data;
        if (data == null) return const Center(child: CircularProgressIndicator());
        final (log, content) = data;
        final (rows, skipped) = ResultsLog.rowsOf(content);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: content.isEmpty ? null : () => _share(log, content),
                  icon: const Icon(Icons.share),
                  label: const Text('Share / copy results'),
                ),
                OutlinedButton.icon(
                  onPressed: content.isEmpty || _uploading ? null : () => _upload(content),
                  icon: _uploading
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.cloud_upload),
                  label: Text(_uploading ? 'Uploading…' : 'Upload to server'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(log.file.path, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            if (skipped > 0) Text('$skipped unreadable lines skipped (a run was cut off while saving).'),
            if (rows.isEmpty) const Text('No results yet.') else _table(rows),
          ],
        );
      },
    ),
  );

  Widget _table(List<ResultRow> rows) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: DataTable(
      columns: const [
        DataColumn(label: Text('File')),
        DataColumn(label: Text('Kind')),
        DataColumn(label: Text('Back step\nmedian / p95 ms')),
        DataColumn(label: Text('Exact\nback steps')),
        DataColumn(label: Text('Exact seek\nmedian ms')),
        DataColumn(label: Text('Timeouts')),
        DataColumn(label: Text('Notes')),
      ],
      rows: [
        for (final row in rows) ...[
          DataRow(
            cells: [
              DataCell(Text(row.file)),
              DataCell(Text(row.error == null ? row.kind : 'Failed: ${row.error}')),
              DataCell(Text(_timing(row.backStep))),
              DataCell(Text(_exactness(row.backStep))),
              DataCell(Text(_ms(row.exactSeekMedianMs))),
              DataCell(Text(row.error == null ? '${row.timeouts}' : '')),
              DataCell(Text(_notes(row))),
            ],
          ),
          if (row.backStepOffset0 case final offset0?)
            DataRow(
              cells: [
                DataCell(Text('  same, .ts offset 0')),
                const DataCell(Text('')),
                DataCell(Text(_timing(offset0))),
                DataCell(Text(_exactness(offset0))),
                const DataCell(Text('')),
                DataCell(Text('${offset0['timeouts']}')),
                const DataCell(Text('')),
              ],
            ),
        ],
      ],
    ),
  );

  static String _ms(Object? ms) => ms is num ? ms.round().toString() : '–';

  static String _timing(Map<String, dynamic>? s) => s == null ? '' : '${_ms(s['medianMs'])} / ${_ms(s['p95Ms'])}';

  /// `38 / 40 (stuck 2)`: exact out of attempted, then any other landings.
  static String _exactness(Map<String, dynamic>? s) {
    if (s == null) return '';
    if (s['classified'] == 0) return s['notMeasured'] == 0 ? '' : 'not measured';
    final other = [
      for (final k in ['stuck', 'skipped', 'wrongDirection', 'unverified'])
        if (((s[k] as int?) ?? 0) > 0) '${k == 'wrongDirection' ? 'wrong way' : k} ${s[k]}',
    ];
    return '${s['exact']} / ${s['attempted']}${other.isEmpty ? '' : ' (${other.join(', ')})'}';
  }

  /// Series that could not run, and engine errors seen during the run.
  static String _notes(ResultRow row) => [
    if (row.notMeasured.isNotEmpty) 'not measured: ${row.notMeasured.join(', ')}',
    if (row.engineErrors.isNotEmpty) 'engine errors (${row.engineErrors.length}): ${row.engineErrors.first}',
  ].join('; ');
}
