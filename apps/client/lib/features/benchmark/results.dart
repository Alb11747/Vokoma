import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/api.dart';

/// A file in the benchmark set, or the one file a single run is for.
class BenchFile {
  const BenchFile({
    required this.rootId,
    required this.path,
    required this.fileId,
    required this.sizeBytes,
    this.duration,
  });

  factory BenchFile.of(String rootId, String folder, FileEntry file) => BenchFile(
    rootId: rootId,
    path: folder.isEmpty ? file.name : '$folder/${file.name}',
    fileId: file.fileId,
    sizeBytes: file.sizeBytes,
    duration: file.duration,
  );

  factory BenchFile.fromJson(Map<String, dynamic> json) => BenchFile(
    rootId: json['rootId'] as String,
    path: json['path'] as String,
    fileId: json['fileId'] as String,
    sizeBytes: (json['sizeBytes'] as num).toInt(),
    duration: json['durationMs'] == null ? null : Duration(milliseconds: (json['durationMs'] as num).toInt()),
  );

  final String rootId;

  /// Relative to the root, with the file name.
  final String path;

  /// Stable for a path within a root, so the set can store it.
  final String fileId;
  final int sizeBytes;
  final Duration? duration;

  String get name => path.split('/').last;
  bool get isMpegTs => name.toLowerCase().endsWith('.ts');

  Map<String, Object?> toJson() => {
    'rootId': rootId,
    'path': path,
    'fileId': fileId,
    'sizeBytes': sizeBytes,
    'durationMs': duration?.inMilliseconds,
  };
}

/// The standard set, kept in preferences until the server can provide it.
class BenchmarkSet {
  BenchmarkSet(this._preferences);

  static const _key = 'benchmark.set';
  final SharedPreferences _preferences;

  static Future<BenchmarkSet> open() async => BenchmarkSet(await SharedPreferences.getInstance());

  List<BenchFile> get files => [
    for (final e in jsonDecode(_preferences.getString(_key) ?? '[]') as List)
      BenchFile.fromJson(e as Map<String, dynamic>),
  ];

  /// Adds [more], skipping files already in the set. Returns how many were new.
  Future<int> add(Iterable<BenchFile> more) async {
    final current = files;
    final known = {for (final f in current) f.fileId};
    final added = [
      for (final f in more)
        if (known.add(f.fileId)) f,
    ];
    await _preferences.setString(_key, jsonEncode([...current, ...added]));
    return added.length;
  }

  Future<void> clear() => _preferences.remove(_key);
}

/// One line of the results file.
Map<String, Object?> benchmarkRecord({
  required DateTime time,
  required String appVersion,
  required Map<String, Object?> device,
  required BenchFile file,
  Map<String, Object?>? measurements,
  String? error,
}) => {
  'schema': 1,
  'time': time.toUtc().toIso8601String(),
  'appVersion': appVersion,
  'device': device,
  'file': {...file.toJson(), 'name': file.name, 'mpegTs': file.isMpegTs},
  ...?measurements,
  'error': ?error,
};

/// One row of the results table, read back from a record.
class ResultRow {
  ResultRow(this.record);

  /// Null unless [line] is a JSON record with the fields the table needs.
  static ResultRow? tryParse(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final file = decoded['file'], time = decoded['time'];
    if (file is! Map<String, dynamic> || file['name'] is! String) return null;
    if (time is! String || DateTime.tryParse(time) == null) return null;
    final summary = decoded['summary'];
    if (summary != null && summary is! Map<String, dynamic>) return null;
    return ResultRow(decoded);
  }

  final Map<String, dynamic> record;

  Map<String, dynamic> get _summary => (record['summary'] as Map<String, dynamic>?) ?? const {};
  Map<String, dynamic>? get _engine => record['engine'] as Map<String, dynamic>?;

  String get file => (record['file'] as Map<String, dynamic>)['name'] as String;
  String? get error => record['error'] as String?;
  DateTime get time => DateTime.parse(record['time'] as String);

  /// For example `hevc yuv420p10le · matroska,webm · d3d11va`.
  String get kind {
    final e = _engine;
    if (e == null) return '';
    return [
      [e['codec'], e['pixelFormat']].whereType<String>().join(' '),
      e['container'],
      e['hardwareDecoding'] ?? 'software',
    ].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
  }

  Map<String, dynamic>? get backStep => _summary['backStep'] as Map<String, dynamic>?;
  Map<String, dynamic>? get backStepOffset0 => _summary['backStepOffset0'] as Map<String, dynamic>?;
  num? get exactSeekMedianMs => _summary['exactSeekMedianMs'] as num?;
  int get timeouts => (_summary['timeouts'] as int?) ?? 0;
  List<String> get notMeasured => [...?(_summary['notMeasured'] as List?)?.cast<String>()];
  List<String> get engineErrors => [...?(record['engineErrors'] as List?)?.cast<String>()];
}

/// The JSON Lines file in the app's documents folder. Nothing is uploaded.
class ResultsLog {
  ResultsLog(this.file);

  final File file;

  static Future<ResultsLog> open() async =>
      ResultsLog(File('${(await getApplicationDocumentsDirectory()).path}/Vokoma/engine-benchmark.jsonl'));

  /// Appends [record] as one line. A previous append that was cut off
  /// (app killed mid-write) leaves a partial line; this one then starts on a
  /// fresh line so it stays readable.
  Future<void> append(Map<String, Object?> record) async {
    await file.parent.create(recursive: true);
    final out = await file.open(mode: FileMode.append);
    try {
      final length = await out.length();
      var cutOff = false;
      if (length > 0) {
        await out.setPosition(length - 1);
        cutOff = (await out.readByte()) != 0x0a;
        await out.setPosition(length);
      }
      await out.writeString('${cutOff ? '\n' : ''}${jsonEncode(record)}\n');
      await out.flush();
    } finally {
      await out.close();
    }
  }

  Future<String> read() async => await file.exists() ? await file.readAsString() : '';

  /// The readable records, newest first, and how many non-empty lines
  /// could not be read (a cut-off write, or a record of an unknown shape).
  static (List<ResultRow>, int skipped) rowsOf(String jsonLines) {
    final rows = <ResultRow>[];
    var skipped = 0;
    for (final line in const LineSplitter().convert(jsonLines).reversed) {
      if (line.trim().isEmpty) continue;
      final row = ResultRow.tryParse(line);
      if (row == null) {
        skipped++;
      } else {
        rows.add(row);
      }
    }
    return (rows, skipped);
  }
}
