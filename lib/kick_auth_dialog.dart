import 'dart:async';
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

  KickOAuth? _oauth;
  KickPkceSession? _pkce;
  HttpServer? _callbackServer;
  StreamSubscription<HttpRequest>? _callbackSubscription;
  Uri? _authorizationUrl;
  bool _busy = false;
  bool _callbackReceived = false;
  bool _showManualUrl = false;
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
    unawaited(_stopCallbackServer());
    _clientIdController.dispose();
    _clientSecretController.dispose();
    super.dispose();
  }

  Future<void> _openAuthorization() async {
    final clientId = _clientIdController.text.trim();
    final clientSecret = _clientSecretController.text.trim();
    if (clientId.isEmpty || clientSecret.isEmpty) {
      setState(() => _error = 'Введите Client ID и Client Secret.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _callbackReceived = false;
      _showManualUrl = false;
    });

    try {
      await _startCallbackServer();
      final oauth = KickOAuth(
        clientId: clientId,
        clientSecret: clientSecret,
        redirectUri: _redirectUri,
      );
      final pkce = KickOAuth.generatePkce();
      final url = oauth.buildAuthorizationUrl(scopes: _scopes, pkce: pkce);

      if (!mounted) return;
      setState(() {
        _oauth = oauth;
        _pkce = pkce;
        _authorizationUrl = url;
      });

      try {
        await _launchBrowser(url);
      } catch (_) {
        if (mounted) {
          setState(() {
            _showManualUrl = true;
            _error = 'Не удалось открыть браузер. Скопируйте ссылку ниже.';
          });
        }
      }
    } catch (_) {
      await _stopCallbackServer();
      if (mounted) {
        setState(() {
          _authorizationUrl = null;
          _error = 'Не удалось открыть локальный порт 3000. Закройте программу, '
              'которая его использует, и повторите вход.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Opens the URL without passing it through a command shell.
  ///
  /// In particular, `cmd /c start` can treat the OAuth query separators (`&`)
  /// as command separators, opening a truncated URL and causing a Kick 404.
  Future<void> _launchBrowser(Uri url) async {
    final value = url.toString();
    if (Platform.isWindows) {
      await Process.start('rundll32.exe', [
        'url.dll,FileProtocolHandler',
        value,
      ]);
    } else if (Platform.isMacOS) {
      await Process.start('open', [value]);
    } else {
      await Process.start('xdg-open', [value]);
    }
  }

  Future<void> _startCallbackServer() async {
    await _stopCallbackServer();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 3000);
    _callbackServer = server;
    _callbackSubscription = server.listen(
      (request) => unawaited(_handleCallback(request)),
      onError: (_) {},
    );
  }

  Future<void> _stopCallbackServer() async {
    await _callbackSubscription?.cancel();
    _callbackSubscription = null;
    await _callbackServer?.close(force: true);
    _callbackServer = null;
  }

  Future<void> _handleCallback(HttpRequest request) async {
    final oauth = _oauth;
    final pkce = _pkce;
    if (request.uri.path != '/callback' || oauth == null || pkce == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final code = request.uri.queryParameters['code'];
    final state = request.uri.queryParameters['state'];
    final oauthError = request.uri.queryParameters['error'];
    if (oauthError != null || code == null || code.isEmpty || state != pkce.state) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.headers.contentType = ContentType('text', 'html', charset: 'utf-8');
      request.response.write(_callbackPage(
        'Не удалось подтвердить вход',
        'Вернитесь в Kicksen и повторите попытку.',
      ));
      await request.response.close();
      if (mounted) {
        setState(() => _error = 'Kick не подтвердил вход. Повторите попытку.');
      }
      return;
    }

    if (_callbackReceived) {
      request.response.headers.contentType = ContentType('text', 'html', charset: 'utf-8');
      request.response.write(_callbackPage(
        'Подтверждение уже получено',
        'Можно закрыть эту страницу и вернуться в Kicksen.',
      ));
      await request.response.close();
      return;
    }

    _callbackReceived = true;
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }

    request.response.headers.contentType = ContentType('text', 'html', charset: 'utf-8');
    request.response.write(_callbackPage(
      'Подтверждение получено',
      'Можно закрыть эту страницу и вернуться в Kicksen.',
    ));
    await request.response.close();
    await _stopCallbackServer();

    try {
      final token = await oauth.exchangeCode(code: code, pkce: pkce);
      if (!mounted) return;
      Navigator.of(context).pop(KickLoginResult(token: token, oauth: oauth));
    } catch (error) {
      if (mounted) {
        setState(() {
          _authorizationUrl = null;
          _callbackReceived = false;
          _error = error.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _callbackPage(String title, String message) {
    return '<!doctype html><html lang="ru"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>Kicksen</title></head><body style="margin:0;padding:48px;'
        'font-family:system-ui,sans-serif;background:#0d110e;color:#f1f5f1">'
        '<main style="max-width:560px;margin:10vh auto"><h1>$title</h1>'
        '<p style="font-size:18px;line-height:1.5">$message</p></main>'
        '</body></html>';
  }

  Future<void> _cancelLogin() async {
    await _stopCallbackServer();
    if (mounted) Navigator.of(context).pop();
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
                'Client Secret используется только в памяти и не сохраняется '
                'в файлах или репозитории.',
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
                  '1. В открывшемся браузере разрешите доступ Kicksen.\n'
                  '2. Вернитесь в приложение — вход завершится автоматически.\n'
                  'Ничего копировать не нужно.',
                  style: TextStyle(height: 1.5),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    if (_busy)
                      const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      const Icon(Icons.open_in_browser, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _callbackReceived
                            ? 'Подтверждение получено. Завершаем вход…'
                            : 'Ожидаем подтверждение в браузере…',
                      ),
                    ),
                  ],
                ),
                if (_showManualUrl) ...[
                  const SizedBox(height: 12),
                  SelectableText(
                    _authorizationUrl.toString(),
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
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
          onPressed: _busy ? null : _cancelLogin,
          child: const Text('Отмена'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _openAuthorization,
          icon: const Icon(Icons.open_in_new),
          label: Text(
            _busy
                ? 'Ожидайте…'
                : authorizationStarted
                    ? 'Открыть Kick снова'
                    : 'Открыть Kick',
          ),
        ),
      ],
    );
  }
}
