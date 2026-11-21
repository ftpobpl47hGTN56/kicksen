import 'dart:io';

import 'package:kick_chat/kick_oauth.dart';
import 'package:material_ui/material_ui.dart';

class KickLoginResult {
  const KickLoginResult({required this.token, required this.oauth});

  final KickToken token;
  final KickOAuth oauth;
}

class KickLoginDialog extends StatefulWidget {
  const KickLoginDialog({super.key});

  @override
  State<KickLoginDialog> createState() => _KickLoginDialogState();
}

class _KickLoginDialogState extends State<KickLoginDialog> {
  static const _redirectUri = 'http://localhost:3000/callback';
  static const _scopes = ['user:read', 'channel:read', 'chat:write'];

  late final TextEditingController _clientIdController;
  late final TextEditingController _clientSecretController;
  final _callbackController = TextEditingController();

  KickOAuth? _oauth;
  KickPkceSession? _pkce;
  Uri? _authorizationUrl;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _clientIdController = TextEditingController(
      text: Platform.environment['KICK_CLIENT_ID'] ?? '',
    );
    _clientSecretController = TextEditingController(
      text: Platform.environment['KICK_CLIENT_SECRET'] ?? '',
    );
  }

  @override
  void dispose() {
    _clientIdController.dispose();
    _clientSecretController.dispose();
    _callbackController.dispose();
    super.dispose();
  }

  Future<void> _openAuthorization() async {
    final clientId = _clientIdController.text.trim();
    final clientSecret = _clientSecretController.text.trim();
    if (clientId.isEmpty || clientSecret.isEmpty) {
      setState(() => _error = 'Введите Client ID и Client Secret.');
      return;
    }

    final oauth = KickOAuth(
      clientId: clientId,
      clientSecret: clientSecret,
      redirectUri: _redirectUri,
    );
    final pkce = KickOAuth.generatePkce();
    final url = oauth.buildAuthorizationUrl(scopes: _scopes, pkce: pkce);

    setState(() {
      _oauth = oauth;
      _pkce = pkce;
      _authorizationUrl = url;
      _error = null;
      _busy = true;
    });

    try {
      await Process.start(
        'cmd',
        ['/c', 'start', '', url.toString()],
        runInShell: true,
      );
    } catch (_) {
      // The selectable URL remains available when the browser cannot be opened.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finishLogin() async {
    final oauth = _oauth;
    final pkce = _pkce;
    if (oauth == null || pkce == null) return;

    final uri = Uri.tryParse(_callbackController.text.trim());
    final code = uri?.queryParameters['code'];
    final state = uri?.queryParameters['state'];
    if (code == null || code.isEmpty) {
      setState(() => _error = 'В ссылке нет параметра code. Вставьте полный callback URL.');
      return;
    }
    if (state != pkce.state) {
      setState(() => _error = 'state не совпадает. Повторите вход с самого начала.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final token = await oauth.exchangeCode(code: code, pkce: pkce);
      if (!mounted) return;
      Navigator.of(context).pop(KickLoginResult(token: token, oauth: oauth));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authorizationStarted = _authorizationUrl != null;

    return AlertDialog(
      title: const Text('Вход через Kick'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Используются OAuth 2.1 и PKCE. Client Secret не сохраняется '
                'в файлах и не попадает в репозиторий.',
                style: TextStyle(height: 1.45),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _clientIdController,
                enabled: !_busy && !authorizationStarted,
                decoration: const InputDecoration(labelText: 'Client ID'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _clientSecretController,
                enabled: !_busy && !authorizationStarted,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Client Secret'),
              ),
              if (authorizationStarted) ...[
                const SizedBox(height: 20),
                const Text(
                  '1. В браузере войдите на id.kick.com и разрешите доступ.\n'
                  '2. После перенаправления localhost может показать ошибку — это нормально.\n'
                  '3. Скопируйте весь URL из адресной строки и вставьте ниже.',
                  style: TextStyle(height: 1.5),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _callbackController,
                  enabled: !_busy,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Callback URL',
                    hintText: 'http://localhost:3000/callback?code=...&state=...',
                  ),
                ),
                const SizedBox(height: 12),
                const Text('Если браузер не открылся, скопируйте ссылку вручную:'),
                const SizedBox(height: 6),
                SelectableText(
                  _authorizationUrl.toString(),
                  style: const TextStyle(fontSize: 12),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: const TextStyle(color: Color(0xFFFFB4AB)),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _busy
              ? null
              : authorizationStarted
                  ? _finishLogin
                  : _openAuthorization,
          child: Text(
            _busy
                ? 'Ожидайте…'
                : authorizationStarted
                    ? 'Завершить вход'
                    : 'Открыть Kick',
          ),
        ),
      ],
    );
  }
}
