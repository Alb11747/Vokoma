import 'package:flutter/material.dart';

import '../../api/api.dart';
import '../../updates/update_screen.dart';
import '../../format.dart';
import '../benchmark/benchmark_screen.dart';
import '../benchmark/benchmark_section.dart';
import '../benchmark/results.dart';
import '../../updates/update_service.dart';
import '../player/player_screen.dart';

/// Roots, then folders inside a root. Folders first, as the server sorts.
class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key, required this.api, required this.onSignedOut});

  final Api api;
  final void Function(String? message) onSignedOut;

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  MediaRoot? _root;
  final _folders = <String>[];
  Future<Object>? _load;

  /// The folder listing on screen, for "Add current folder's files" in About.
  Listing? _shown;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final root = _root;
    _shown = null;
    setState(() {
      _load = root == null ? widget.api.roots() : widget.api.entries(root.id, path: _folders.join('/'));
    });
  }

  void _openRoot(MediaRoot root) {
    _root = root;
    _folders.clear();
    _reload();
  }

  void _openFolder(String name) {
    _folders.add(name);
    _reload();
  }

  void _up() {
    if (_folders.isNotEmpty) {
      _folders.removeLast();
    } else {
      _root = null;
    }
    _reload();
  }

  Future<void> _signOut() async {
    String? message;
    try {
      await widget.api.logout();
    } catch (error) {
      message = 'Signed out on this device, but the server did not confirm it: $error';
    }
    widget.onSignedOut(message);
  }

  List<BenchFile> _folderFiles() {
    final root = _root, shown = _shown;
    if (root == null || shown == null) return const [];
    return [
      for (final e in shown.entries)
        if (e is FileEntry) BenchFile.of(root.id, shown.path, e),
    ];
  }

  void _openAbout() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => UpdateScreen(
        benchmark: BenchmarkSection(api: widget.api, folderFiles: _folderFiles()),
      ),
    ),
  );

  /// Long press (Android) or right click (Windows) on a file.
  Future<void> _fileMenu(MediaRoot root, String folder, FileEntry file, Offset position) async {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final run = await showMenu<bool>(
      context: context,
      position: RelativeRect.fromRect(position & Size.zero, Offset.zero & overlay.size),
      items: const [PopupMenuItem(value: true, child: Text('Run engine benchmark'))],
    );
    if (run == true && mounted) startBenchmark(context, widget.api, [BenchFile.of(root.id, folder, file)]);
  }

  @override
  Widget build(BuildContext context) {
    final root = _root;
    final atTop = root == null;
    return PopScope(
      canPop: atTop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: atTop ? null : IconButton(icon: const Icon(Icons.arrow_back), onPressed: _up),
          title: Text(atTop ? 'Vokoma' : [root.name, ..._folders].join(' / '), overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(tooltip: 'About / updates', icon: const Icon(Icons.system_update), onPressed: _openAbout),
            IconButton(icon: const Icon(Icons.refresh), tooltip: 'Reload', onPressed: _reload),
            PopupMenuButton<void>(
              itemBuilder: (_) => [PopupMenuItem(onTap: _signOut, child: const Text('Sign out'))],
            ),
          ],
        ),
        body: FutureBuilder<Object>(
          future: _load,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _ErrorView(error: snapshot.error!, onRetry: _reload);
            }
            final data = snapshot.data;
            if (snapshot.connectionState != ConnectionState.done || data == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return switch (data) {
              final List<MediaRoot> roots => _rootList(roots),
              final Listing listing => _entryList(root!, listing),
              _ => throw StateError('Unexpected listing $data'),
            };
          },
        ),
      ),
    );
  }

  Widget _rootList(List<MediaRoot> roots) {
    if (roots.isEmpty) return const Center(child: Text('The server has no media folders.'));
    return ListView(
      children: [
        for (final r in roots)
          ListTile(
            leading: const Icon(Icons.video_library_outlined),
            title: Text(r.name),
            subtitle: Text(r.kind),
            onTap: () => _openRoot(r),
          ),
      ],
    );
  }

  Widget _entryList(MediaRoot root, Listing listing) {
    _shown = listing;
    if (listing.entries.isEmpty) return const Center(child: Text('This folder is empty.'));
    return ListView.builder(
      itemCount: listing.entries.length,
      itemBuilder: (context, i) => switch (listing.entries[i]) {
        FolderEntry(:final name) => ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(name),
          onTap: () => _openFolder(name),
        ),
        final FileEntry file => GestureDetector(
          onLongPressStart: (d) => _fileMenu(root, listing.path, file, d.globalPosition),
          onSecondaryTapUp: (d) => _fileMenu(root, listing.path, file, d.globalPosition),
          child: ListTile(
            leading: const Icon(Icons.movie_outlined),
            title: Text(file.name),
            subtitle: Text(
              [formatSize(file.sizeBytes), if (file.duration != null) formatDuration(file.duration!)].join(' · '),
            ),
            onTap: () {
              if (UpdateService.instance.installing) return;
              // Reserve playback before the next frame constructs PlayerScreen.
              final releasePlayback = UpdateService.instance.reservePlayer();
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PlayerScreen(api: widget.api, file: file, releasePlayback: releasePlayback),
                ),
              );
            },
          ),
        ),
      },
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$error', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}
