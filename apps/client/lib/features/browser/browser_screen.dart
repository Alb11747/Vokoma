import 'package:flutter/material.dart';

import '../../api/api.dart';
import '../../updates/update_screen.dart';
import '../../format.dart';
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

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final root = _root;
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
            IconButton(
              tooltip: 'About / updates',
              icon: const Icon(Icons.system_update),
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const UpdateScreen())),
            ),
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
    if (listing.entries.isEmpty) return const Center(child: Text('This folder is empty.'));
    return ListView.builder(
      itemCount: listing.entries.length,
      itemBuilder: (context, i) => switch (listing.entries[i]) {
        FolderEntry(:final name) => ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(name),
          onTap: () => _openFolder(name),
        ),
        final FileEntry file => ListTile(
          leading: const Icon(Icons.movie_outlined),
          title: Text(file.name),
          subtitle: Text(
            [formatSize(file.sizeBytes), if (file.duration != null) formatDuration(file.duration!)].join(' · '),
          ),
          onTap: () {
            if (UpdateService.instance.installing) return;
            // Reserve playback before the next frame constructs PlayerScreen.
            UpdateService.instance.setPlayerOpen(true);
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => PlayerScreen(api: widget.api, file: file),
              ),
            );
          },
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
