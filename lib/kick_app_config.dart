import 'dart:io';

import 'package:kick_chat/kick_oauth.dart';
import 'package:kick_chat/kick_proxy_http_client.dart';

const kKicksenClientId = '01M7XZE4WQFNX8NQ5BZS8YWB6M';
const kKicksenRedirectUri = 'http://localhost:3000/callback';
const kKicksenOAuthProxyUrl = String.fromEnvironment(
  'KICK_OAUTH_PROXY_URL',
  defaultValue: 'https://kicksen-oauth.gullampis810.workers.dev',
);

KickOAuth? createKicksenOAuth() {
  final clientId = Platform.environment['KICK_CLIENT_ID'];
  final clientSecret = Platform.environment['KICK_CLIENT_SECRET'];
  if (clientId != null && clientSecret != null) {
    return KickOAuth(
      clientId: clientId,
      clientSecret: clientSecret,
      redirectUri: kKicksenRedirectUri,
    );
  }

  if (kKicksenOAuthProxyUrl.isEmpty) return null;
  return KickOAuth.proxy(
    clientId: kKicksenClientId,
    proxyBaseUrl: kKicksenOAuthProxyUrl,
    redirectUri: kKicksenRedirectUri,
    httpClient: Platform.isAndroid ? KickProxyHttpClient() : null,
  );
}
