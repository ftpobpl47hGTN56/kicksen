import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

const String kKickOAuthBase = 'https://id.kick.com';

class KickOAuthException implements Exception {
  const KickOAuthException(this.message);
  final String message;

  @override
  String toString() => message;
}

class KickToken {
  const KickToken({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.scope,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final String scope;

  bool get isExpired => DateTime.now().isAfter(expiresAt.subtract(const Duration(minutes: 1)));

  factory KickToken.fromJson(Map<String, dynamic> json) => KickToken(
        accessToken: json['access_token'] as String,
        refreshToken: json['refresh_token'] as String? ?? '',
        expiresAt: json['expires_at'] != null
            ? DateTime.parse(json['expires_at'] as String)
            : DateTime.now().add(Duration(seconds: (json['expires_in'] as num? ?? 3600).toInt())),
        scope: json['scope'] as String? ?? '',
      );
}

class KickPkceSession {
  const KickPkceSession({required this.verifier, required this.challenge, required this.state});

  final String verifier;
  final String challenge;
  final String state;
}

class KickOAuth {
  KickOAuth({
    required this.clientId,
    required String clientSecret,
    required this.redirectUri,
    http.Client? httpClient,
  })  : clientSecret = clientSecret,
        proxyBaseUrl = null,
        _http = httpClient ?? http.Client();

  KickOAuth.proxy({
    required this.clientId,
    required String proxyBaseUrl,
    required this.redirectUri,
    http.Client? httpClient,
  })  : clientSecret = null,
        proxyBaseUrl = proxyBaseUrl.replaceAll(RegExp(r'/$'), ''),
        _http = httpClient ?? http.Client();

  static const String authorizeUrl = '$kKickOAuthBase/oauth/authorize';
  static const String tokenUrl = '$kKickOAuthBase/oauth/token';

  final String clientId;
  final String? clientSecret;
  final String? proxyBaseUrl;
  final String redirectUri;
  final http.Client _http;

  static final _random = Random.secure();

  static KickPkceSession generatePkce() {
    String randomString(int length) {
      const charset = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
      return List.generate(length, (_) => charset[_random.nextInt(charset.length)]).join();
    }

    final verifier = randomString(64);
    final challenge = base64Url.encode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', '');
    return KickPkceSession(verifier: verifier, challenge: challenge, state: randomString(24));
  }

  Uri buildAuthorizationUrl({required List<String> scopes, required KickPkceSession pkce}) {
    return Uri.parse(authorizeUrl).replace(queryParameters: {
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'state': pkce.state,
      'scope': scopes.join(' '),
      'code_challenge': pkce.challenge,
      'code_challenge_method': 'S256',
      if (Uri.parse(redirectUri).host == '127.0.0.1') 'redirect': '127.0.0.1',
    });
  }

  Future<KickToken> exchangeCode({required String code, required KickPkceSession pkce}) {
    return _tokenRequest({
      'grant_type': 'authorization_code',
      'code': code,
      'code_verifier': pkce.verifier,
      'redirect_uri': redirectUri,
    });
  }

  Future<KickToken> refresh(KickToken token) {
    return _tokenRequest({
      'grant_type': 'refresh_token',
      'refresh_token': token.refreshToken,
    });
  }

  Future<KickToken> _tokenRequest(Map<String, String> body) async {
    final proxy = proxyBaseUrl;
    final resp = await _http.post(
      Uri.parse(proxy == null ? tokenUrl : '$proxy/token'),
      headers: {
        'Content-Type': proxy == null ? 'application/x-www-form-urlencoded' : 'application/json',
      },
      body: proxy == null
          ? {'client_id': clientId, 'client_secret': clientSecret!, ...body}
          : jsonEncode(body),
    );
    if (resp.statusCode != 200) {
      final details = resp.body.isEmpty ? 'пустой ответ' : resp.body;
      throw KickOAuthException(
        'Ошибка обмена кода Kick (${resp.statusCode}): $details',
      );
    }
    if (resp.body.isEmpty) {
      throw const KickOAuthException('Kick вернул пустой ответ при обмене кода.');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return KickToken.fromJson(data);
  }
}
