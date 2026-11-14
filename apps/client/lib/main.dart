import 'package:flutter/material.dart';

import 'api/api.dart';
import 'api/token_store.dart';
import 'engine/mpv_engine.dart';
import 'features/browser/browser_screen.dart';
import 'features/login/login_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MpvEngine.initialize();

  final store = SecureTokenStore();
  Api? api;
  String? restoreError;
  try {
    api = await Api.restore(store);
  } catch (error) {
    // A keystore that cannot be read must not stop the app from starting;
    // the user can still log in, and sees why the old session is gone.
    restoreError = 'Could not read the saved session: $error';
  }
  runApp(VokomaApp(store: store, initialApi: api, initialError: restoreError));
}

class VokomaApp extends StatefulWidget {
  const VokomaApp({super.key, required this.store, this.initialApi, this.initialError});

  final TokenStore store;
  final Api? initialApi;
  final String? initialError;

  @override
  State<VokomaApp> createState() => _VokomaAppState();
}

class _VokomaAppState extends State<VokomaApp> {
  final _navigator = GlobalKey<NavigatorState>();
  Api? _api;
  String? _message;

  @override
  void initState() {
    super.initState();
    _message = widget.initialError;
    _use(widget.initialApi);
  }

  void _use(Api? api) {
    _api = api;
    api?.onSignedOut = () => _signedOut('The server ended this session. Log in again.');
  }

  void _signedOut(String? message) {
    _navigator.currentState?.popUntil((route) => route.isFirst);
    setState(() {
      _api?.close();
      _api = null;
      _message = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final api = _api;
    return MaterialApp(
      title: 'Vokoma',
      navigatorKey: _navigator,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark),
      ),
      home: api == null
          ? LoginScreen(
              store: widget.store,
              message: _message,
              onSignedIn: (api) => setState(() {
                _use(api);
                _message = null;
              }),
            )
          : BrowserScreen(api: api, onSignedOut: _signedOut),
    );
  }
}
