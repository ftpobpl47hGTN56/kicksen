// Logs in via OAuth 2.1 (PKCE) and sends chat messages as you type.
//
// Setup:
//   1. Enable 2FA on kick.com, then create an app at
//      https://kick.com/settings/developer with redirect URI
//      http://localhost:3000/callback (or your own).
//   2. export KICK_CLIENT_ID=... KICK_CLIENT_SECRET=...
//      (optionally KICK_REDIRECT_URI, default http://localhost:3000/callback)
//   3. dart run example/send_chat.dart <channel>
//
// The token is cached in .kick_token.json and refreshed automatically.
import 'dart:convert';
import 'dart:io';

import 'package:kick_chat/kick_api.dart';
import 'package:kick_chat/kick_oauth.dart';

const scopes = ['user:read', 'channel:read', 'chat:write'];
final tokenFile = File('.kick_token.json');

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run example/send_chat.dart <channel>');
    exit(64);
  }
  final channel = args.first;

  final clientId = Platform.environment['KICK_CLIENT_ID'];
  final clientSecret = Platform.environment['KICK_CLIENT_SECRET'];
  if (clientId == null || clientSecret == null) {
    stderr.writeln('Set KICK_CLIENT_ID and KICK_CLIENT_SECRET first —\n'
        'create an app at https://kick.com/settings/developer (needs 2FA).');
    exit(64);
  }
  final redirectUri =
      Platform.environment['KICK_REDIRECT_URI'] ?? 'http://localhost:3000/callback';

  final oauth = KickOAuth(
    clientId: clientId,
    clientSecret: clientSecret,
    redirectUri: redirectUri,
  );
  final token = await _getToken(oauth);

  final api = KickApiClient(accessToken: token.accessToken);
  final me = await api.getCurrentUser();
  stdout.writeln('Logged in as ${me.name} (id ${me.userId})');

  final target = await api.getChannelBySlug(channel);
  if (target == null) {
    stderr.writeln('channel not found: $channel');
    exit(1);
  }
  stdout.writeln('Target: #${target.slug} '
      '(broadcaster ${target.broadcasterUserId}, '
      '${target.isLive ? 'live, ${target.viewerCount} viewers' : 'offline'})');
  stdout.writeln('Type a message and press Enter to send. Ctrl+C to quit.');

  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final text = line.trim();
    if (text.isEmpty) continue;
    try {
      final id = await api.sendMessage(
        broadcasterUserId: target.broadcasterUserId,
        content: text,
      );
      stdout.writeln('-> sent (message $id)');
    } on KickApiException catch (e) {
      stderr.writeln('-> failed: $e');
    }
  }
}

Future<KickToken> _getToken(KickOAuth oauth) async {
  if (await tokenFile.exists()) {
    var token = KickToken.fromJson(
        jsonDecode(await tokenFile.readAsString()) as Map<String, dynamic>);
    if (token.isExpired && token.refreshToken.isNotEmpty) {
      stdout.writeln('Refreshing token...');
      token = await oauth.refresh(token);
      await tokenFile.writeAsString(jsonEncode(token.toJson()));
    }
    if (!token.isExpired) return token;
  }

  final pkce = KickOAuth.generatePkce();
  final url = oauth.buildAuthorizationUrl(scopes: scopes, pkce: pkce);
  stdout.writeln('''
Open this URL in your browser and authorize the app:
$url

After authorizing, the browser redirects to ${oauth.redirectUri}
(the page will not load — that is fine).
Copy the FULL URL from the address bar and paste it here:''');

  final input = stdin.readLineSync() ?? '';
  final uri = Uri.parse(input.trim());
  final code = uri.queryParameters['code'];
  final state = uri.queryParameters['state'];
  if (code == null) {
    stderr.writeln('no `code` parameter in that URL');
    exit(1);
  }
  if (state != pkce.state) {
    stderr.writeln('state mismatch — possible CSRF, aborting');
    exit(1);
  }
  final token = await oauth.exchangeCode(code: code, pkce: pkce);
  await tokenFile.writeAsString(jsonEncode(token.toJson()));
  return token;
}
