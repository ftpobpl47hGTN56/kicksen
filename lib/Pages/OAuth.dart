import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_chatsen_irc/Kick.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '/Accounts/AccountModel.dart';
import '/Accounts/AccountsCubit.dart';
import '/Components/UserPrefs.dart';
import '/kick_account.dart';
import '/kick_app_config.dart';
import '/kick_oauth.dart';
import 'package:flutter_chatsen_irc/Twitch.dart' as twitch;

class OAuthPage extends StatefulWidget {
  final twitch.Client client;

  const OAuthPage({Key? key, required this.client}) : super(key: key);

  @override
  State<OAuthPage> createState() => _OAuthPageState();
}

class _OAuthPageState extends State<OAuthPage> {
  static const _scopes = ['user:read', 'channel:read', 'chat:write'];

  KickOAuth? _oauth;
  KickPkceSession? _pkce;
  HttpServer? _callbackServer;
  StreamSubscription<HttpRequest>? _callbackSubscription;
  Uri? _authorizationUrl;
  bool _busy = false;
  bool _callbackReceived = false;
  String? _error;

  @override
  void dispose() {
    unawaited(_stopCallbackServer());
    super.dispose();
  }

  Future<void> _startLogin() async {
    final oauth = createKickOAuth();
    if (oauth == null) {
      setState(() => _error = tr('The Kick login server is not configured.', 'Сервер входа Kick не настроен.'));
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _callbackReceived = false;
    });
    try {
      await _startCallbackServer();
      final pkce = KickOAuth.generatePkce();
      final url = oauth.buildAuthorizationUrl(scopes: _scopes, pkce: pkce);
      setState(() {
        _oauth = oauth;
        _pkce = pkce;
        _authorizationUrl = url;
      });
      final launched = await launchUrl(url, mode: LaunchMode.externalApplication);
      if (!launched) throw StateError('No browser available');
    } catch (e) {
      await _stopCallbackServer();
      if (mounted) {
        setState(() => _error = tr(
              'Could not open the browser or local callback port 3000: $e',
              'Не удалось открыть браузер или локальный порт 3000: $e',
            ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
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
    if (code == null || code.isEmpty || state != pkce.state || _callbackReceived) {
      request.response.statusCode = HttpStatus.badRequest;
      await _writeCallbackPage(request, 'Не удалось подтвердить вход', 'Вернитесь в Chatsen Kick и повторите попытку.');
      return;
    }

    _callbackReceived = true;
    await _writeCallbackPage(
      request,
      'Подтверждение получено',
      'Сейчас вы автоматически вернётесь в Chatsen Kick.',
      returnToApp: true,
    );
    await _stopCallbackServer();
    if (mounted) setState(() => _busy = true);

    try {
      final token = await oauth.exchangeCode(code: code, pkce: pkce);
      final api = KickApiClient(accessToken: token.accessToken);
      final Map<String, dynamic> user;
      try {
        user = await api.getCurrentUser();
      } finally {
        api.dispose();
      }
      final userId = user['user_id'] as int;
      final login = user['name'] as String;
      final avatarUrl = user['profile_picture'] as String?;
      final avatarBytes = avatarUrl == null || avatarUrl.isEmpty
          ? null
          : (await http.get(Uri.parse(avatarUrl))).bodyBytes;
      if (!mounted) return;

      final cubit = BlocProvider.of<AccountsCubit>(context);
      var account = cubit.state.firstWhereOrNull((model) => model.id == userId);
      if (account == null) {
        account = AccountModel(id: userId);
        await cubit.add(account);
      }
      account
        ..clientId = kKicksenClientId
        ..token = token.accessToken
        ..refreshToken = token.refreshToken
        ..tokenExpiresAt = token.expiresAt
        ..id = userId
        ..login = login
        ..avatarBytes = avatarBytes;
      await account.save();
      await cubit.setActive(account);
      await widget.client.swapCredentials(kickCredentials(account));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _callbackReceived = false;
          _error = e.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _writeCallbackPage(
    HttpRequest request,
    String title,
    String message, {
    bool returnToApp = false,
  }) async {
    const returnUrl = 'kicksen://oauth/complete';
    final returnContent = returnToApp
        ? '<a href="$returnUrl" style="color:#8bc34a;font-size:18px">'
            'Вернуться в Chatsen Kick</a>'
            '<script>window.location.replace("$returnUrl");</script>'
        : '';
    request.response.headers.contentType = ContentType('text', 'html', charset: 'utf-8');
    request.response.write(
      '<!doctype html><html lang="ru"><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<title>Chatsen Kick</title></head><body style="margin:0;padding:48px;'
      'font-family:system-ui,sans-serif;background:#0d110e;color:#f1f5f1">'
      '<main style="max-width:560px;margin:10vh auto"><h1>$title</h1>'
      '<p style="font-size:18px;line-height:1.5">$message</p>'
      '$returnContent'
      '</main></body></html>',
    );
    await request.response.close();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('Login with Kick', 'Вход через Kick'))),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              tr(
                'The official Kick page will open in your browser. The app never receives your password.',
                'Откроется официальная страница Kick в браузере. Приложение не получает ваш пароль.',
              ),
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            if (_authorizationUrl != null)
              Text(
                _callbackReceived
                    ? tr('Confirmation received. Finishing login…', 'Подтверждение получено. Завершаем вход…')
                    : tr(
                        'Allow access in the browser. The app will reopen automatically.',
                        'Разрешите доступ в браузере — приложение откроется автоматически.',
                      ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _busy ? null : _startLogin,
              icon: _busy
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.open_in_new),
              label: Text(_authorizationUrl == null
                  ? tr('Login with Kick', 'Войти через Kick')
                  : tr('Open Kick again', 'Открыть Kick снова')),
            ),
          ],
        ),
      );
}
