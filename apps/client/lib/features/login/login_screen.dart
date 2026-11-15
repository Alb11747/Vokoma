import 'dart:io';

import 'package:flutter/material.dart';

import '../../api/api.dart';
import '../../updates/update_screen.dart';
import '../../api/token_store.dart';

/// Server address plus user name and password. One account per server.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.store, required this.onSignedIn, this.message});

  final TokenStore store;
  final void Function(Api api) onSignedIn;

  /// Shown above the form, for example why the last session ended.
  final String? message;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  /// The server speaks this API version; others are refused up front.
  static const supportedApiVersion = 1;

  final _address = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final server = Api.parseServerAddress(_address.text);
      final info = await Api.fetchServerInfo(server);
      if (info.apiVersion != supportedApiVersion) {
        throw FormatException(
          'This server speaks API version ${info.apiVersion}; this app needs version $supportedApiVersion.',
        );
      }
      final api = await Api.login(
        server: server,
        username: _username.text,
        password: _password.text,
        deviceName: _deviceName(),
        platform: Platform.operatingSystem,
        store: widget.store,
      );
      if (mounted) widget.onSignedIn(api);
    } catch (error) {
      if (mounted) setState(() => _error = _describe(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _deviceName() {
    if (Platform.isAndroid) return 'Android';
    final host = Platform.localHostname;
    return host.isEmpty ? Platform.operatingSystem : host;
  }

  static String _describe(Object error) => switch (error) {
    ApiException(statusCode: 401) => 'Wrong user name or password.',
    ApiException(statusCode: 429) => 'Too many attempts. Wait a minute and try again.',
    FormatException(:final message) => message,
    SocketException() || HttpException() => 'Cannot reach the server: $error',
    _ => '$error',
  };

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: 'About / updates',
            icon: const Icon(Icons.system_update),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const UpdateScreen())),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: AutofillGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Vokoma', style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 24),
                  if (message != null) ...[Text(message), const SizedBox(height: 16)],
                  TextField(
                    controller: _address,
                    decoration: const InputDecoration(labelText: 'Server address', hintText: 'https://…'),
                    keyboardType: TextInputType.url,
                    autofillHints: const [AutofillHints.url],
                    enabled: !_busy,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _username,
                    decoration: const InputDecoration(labelText: 'User name'),
                    autofillHints: const [AutofillHints.username],
                    enabled: !_busy,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    decoration: const InputDecoration(labelText: 'Password'),
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    enabled: !_busy,
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(onPressed: _busy ? null : _submit, child: Text(_busy ? 'Signing in…' : 'Sign in')),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
