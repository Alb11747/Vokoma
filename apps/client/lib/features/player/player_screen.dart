import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/api.dart';
import '../../api/media_proxy.dart';
import '../../engine/mpv_engine.dart';
import '../../engine/player_engine.dart';
import '../../format.dart';
import '../../platform/window.dart';
import 'hotkeys.dart';
import 'player_controller.dart';

/// Plays one file. Keyboard: the M0 hotkeys. Mouse clicks on the video do
/// nothing. Touch (Android): a tap shows or hides the controls.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.api, required this.file});

  final Api api;
  final FileEntry file;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final PlayerEngine _engine = MpvEngine();
  late final PlayerController _controller = PlayerController(_engine);
  MediaProxy? _proxy;
  StreamSubscription<String>? _errors;
  bool _fullscreen = false;

  String? _osd;
  Timer? _osdTimer;
  bool _controlsVisible = false;
  Timer? _controlsTimer;

  @override
  void initState() {
    super.initState();
    _errors = _engine.errorStream.listen(_showError);
    if (Platform.isAndroid) unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final proxy = await MediaProxy.start(widget.api);
      if (!mounted) return unawaited(proxy.close());
      _proxy = proxy;
      await _engine.open(
        proxy.uriFor(widget.file.fileId),
        httpHeaders: proxy.playerHeaders,
        fileName: widget.file.name,
      );
    } catch (error) {
      _showError('Could not open the file: $error');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _osdTimer?.cancel();
    _controlsTimer?.cancel();
    unawaited(_errors?.cancel());
    if (_fullscreen && Platform.isWindows) unawaited(AppWindow.setFullscreen(false));
    if (Platform.isAndroid) unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    unawaited(_engine.dispose().whenComplete(() => _proxy?.close()));
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final action = actionFor(
      event.logicalKey,
      shift: keyboard.isShiftPressed,
      ctrl: keyboard.isControlPressed,
      alt: keyboard.isAltPressed,
    );
    if (action == null) return KeyEventResult.ignored;
    final isRepeat = event is KeyRepeatEvent;
    switch (action) {
      case ToggleFullscreen():
        if (!isRepeat) unawaited(_setFullscreen(!_fullscreen));
      case Back():
        if (isRepeat) break;
        if (_fullscreen) {
          unawaited(_setFullscreen(false));
        } else {
          Navigator.of(context).maybePop();
        }
      default:
        unawaited(_controller.perform(action, isRepeat: isRepeat).then(_flashOsd));
    }
    return KeyEventResult.handled;
  }

  Future<void> _setFullscreen(bool value) async {
    if (!Platform.isWindows) return;
    await AppWindow.setFullscreen(value);
    if (mounted) setState(() => _fullscreen = value);
  }

  /// Shows the position, plus [message] if given, for a moment.
  void _flashOsd(String? message) {
    if (!mounted) return;
    _osdTimer?.cancel();
    setState(() => _osd = message ?? '');
    _osdTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _osd = null);
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    _scheduleHide();
  }

  void _scheduleHide() {
    _controlsTimer?.cancel();
    if (!_controlsVisible) return;
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _engine.state == EngineState.playing) setState(() => _controlsVisible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final touch = Platform.isAndroid;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The view takes no input; on desktop nothing else does either,
            // so clicks on the video do nothing.
            _engine.buildView(),
            if (touch) GestureDetector(behavior: HitTestBehavior.opaque, onTap: _toggleControls),
            if (_osd != null)
              Positioned(
                left: 16,
                top: 16,
                child: _Osd(engine: _engine, message: _osd!),
              ),
            if (touch && _controlsVisible)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _TouchControls(controller: _controller, onInteract: _scheduleHide),
              ),
          ],
        ),
      ),
    );
  }
}

class _Osd extends StatelessWidget {
  const _Osd({required this.engine, required this.message});

  final PlayerEngine engine;
  final String message;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: StreamBuilder<Duration>(
        stream: engine.positionStream,
        builder: (context, _) => Text(
          [
            if (message.isNotEmpty) message,
            '${formatDuration(engine.position)} / ${formatDuration(engine.duration)}',
          ].join('   '),
          style: const TextStyle(color: Colors.white, fontFeatures: [FontFeature.tabularFigures()]),
        ),
      ),
    ),
  );
}

/// Android M0 controls: play/pause, a seek bar and frame step buttons.
class _TouchControls extends StatefulWidget {
  const _TouchControls({required this.controller, required this.onInteract});

  final PlayerController controller;
  final VoidCallback onInteract;

  @override
  State<_TouchControls> createState() => _TouchControlsState();
}

class _TouchControlsState extends State<_TouchControls> {
  /// Seek bar position while the finger is on it, in milliseconds.
  double? _dragMs;

  PlayerEngine get _engine => widget.controller.engine;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black54,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: StreamBuilder<Duration>(
        stream: _engine.positionStream,
        builder: (context, _) {
          final durationMs = _engine.duration.inMilliseconds.toDouble();
          final positionMs = _dragMs ?? _engine.position.inMilliseconds.toDouble().clamp(0, durationMs);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(formatDuration(Duration(milliseconds: positionMs.round()))),
                  Expanded(
                    child: Slider(
                      max: durationMs > 0 ? durationMs : 1,
                      value: durationMs > 0 ? positionMs : 0,
                      // Keyframe seeks while dragging are fast; the exact seek
                      // on release lands on the chosen frame.
                      onChanged: durationMs > 0
                          ? (v) {
                              setState(() => _dragMs = v);
                              widget.onInteract();
                              unawaited(_engine.seekTo(Duration(milliseconds: v.round()), mode: SeekMode.keyframe));
                            }
                          : null,
                      onChangeEnd: (v) {
                        setState(() => _dragMs = null);
                        unawaited(_engine.seekTo(Duration(milliseconds: v.round())));
                      },
                    ),
                  ),
                  Text(formatDuration(_engine.duration)),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    iconSize: 32,
                    icon: const Icon(Icons.skip_previous),
                    tooltip: 'Previous frame',
                    onPressed: () {
                      widget.onInteract();
                      widget.controller.step(forward: false);
                    },
                  ),
                  const SizedBox(width: 24),
                  StreamBuilder<EngineState>(
                    stream: _engine.stateStream,
                    builder: (context, _) => IconButton(
                      iconSize: 48,
                      icon: Icon(_engine.state == EngineState.playing ? Icons.pause : Icons.play_arrow),
                      tooltip: 'Play or pause',
                      onPressed: () {
                        widget.onInteract();
                        unawaited(_engine.playOrPause());
                      },
                    ),
                  ),
                  const SizedBox(width: 24),
                  IconButton(
                    iconSize: 32,
                    icon: const Icon(Icons.skip_next),
                    tooltip: 'Next frame',
                    onPressed: () {
                      widget.onInteract();
                      widget.controller.step(forward: true);
                    },
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
