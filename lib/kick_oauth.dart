/// OAuth 2.1 (PKCE) authentication for the official Kick API.
///
/// Flow: create an app at https://kick.com/settings/developer (2FA required),
/// build an authorization URL, send the user there, exchange the returned
/// code for a token. Kick is a confidential client: `client_secret` is sent
/// alongside the PKCE verifier.
library kick_oauth;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Kick OAuth server host (deliberately separate from the API host).
const String kKickOAuthBase = 'https://id.kick.com';

final _workerAddressCache = <String, String>{};

Future<String> _resolveWorkerAddress(String host) async {
  final cached = _workerAddressCache[host];
  if (cached != null) return cached;

  try {
    final addresses = await InternetAddress.lookup(
      host,
    ).timeout(const Duration(seconds: 5));
    for (final address in addresses) {
      if (address.type == InternetAddressType.IPv4) {
        return _workerAddressCache[host] = address.address;
      }
    }
  } catch (_) {}

  Object? lastError;
  final endpoints = [
    ['1.1.1.1', '/dns-query'],
    ['8.8.8.8', '/resolve'],
  ];
  for (final endpoint in endpoints) {
    try {
      final response = await http
          .get(
            Uri.https(endpoint[0], endpoint[1], {'name': host, 'type': 'A'}),
            headers: const {'Accept': 'application/dns-json'},
          )
          .timeout(const Duration(seconds: 10));
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final answers = data['Answer'] as List? ?? const [];
      for (final answer in answers.whereType<Map<String, dynamic>>()) {
        final address = answer['data'];
        if (answer['type'] == 1 && address is String) {
          return _workerAddressCache[host] = address;
        }
      }
      throw StateError('No IPv4 address returned for $host');
    } catch (error) {
      lastError = error;
    }
  }
  throw SocketException('Failed to resolve $host: $lastError');
}

http.Client _proxyHttpClient(String proxyBaseUrl) {
  final host = Uri.parse(proxyBaseUrl).host;
  if (!Platform.isAndroid || !host.endsWith('.workers.dev')) {
    return http.Client();
  }

  final io = HttpClient();
  io.findProxy = (_) => 'DIRECT';
  io.connectionFactory = (uri, proxyHost, proxyPort) async {
    final address = await _resolveWorkerAddress(uri.host);
    final task = await Socket.startConnect(address, uri.port);
    return ConnectionTask<Socket>.fromSocket(
      task.socket.then(
        (socket) => SecureSocket.secure(socket, host: uri.host),
      ),
      task.cancel,
    );
  };
  return IOClient(io);
}

class KickOAuthException implements Exception {
  KickOAuthException(this.message);
  final String message;

  @override
  String toString() => 'KickOAuthException: $message';
}

/// An OAuth 2.1 user access token.
class KickToken {
  KickToken({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.scope,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final String scope;

  /// True if the token is expired (with a 1-minute safety margin).
  bool get isExpired =>
      DateTime.now().isAfter(expiresAt.subtract(const Duration(minutes: 1)));

  /// Accepts both the wire format (`expires_in` seconds) and the stored
  /// format (`expires_at` ISO-8601) written by [toJson].
  factory KickToken.fromJson(Map<String, dynamic> json) => KickToken(
        accessToken: json['access_token'] as String,
        refreshToken: json['refresh_token'] as String? ?? '',
        expiresAt: json['expires_at'] != null
            ? DateTime.parse(json['expires_at'] as String)
            : DateTime.now().add(
                Duration(seconds: (json['expires_in'] as num? ?? 3600).toInt())),
        scope: json['scope'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'expires_at': expiresAt.toIso8601String(),
        'scope': scope,
      };
}

/// PKCE pair + CSRF state for one authorization attempt.
class KickPkceSession {
  const KickPkceSession({
    required this.verifier,
    required this.challenge,
    required this.state,
  });

  /// Secret, kept locally, sent to the token endpoint.
  final String verifier;

  /// Public S256 hash of [verifier], sent to the authorize endpoint.
  final String challenge;

  /// CSRF token that must come back unchanged in the redirect.
  final String state;
}

/// Implements the Kick OAuth 2.1 authorization-code flow with PKCE.
class KickOAuth {
  KickOAuth({
    required this.clientId,
    required String clientSecret,
    required this.redirectUri,
    http.Client? httpClient,
  }) : clientSecret = clientSecret,
       proxyBaseUrl = null,
       _http = httpClient ?? http.Client();

  KickOAuth.proxy({
    required this.clientId,
    required String proxyBaseUrl,
    required this.redirectUri,
    http.Client? httpClient,
  }) : clientSecret = null,
       proxyBaseUrl = proxyBaseUrl.replaceAll(RegExp(r'/$'), ''),
       _http = httpClient ?? _proxyHttpClient(proxyBaseUrl);

  static const String authorizeUrl = '$kKickOAuthBase/oauth/authorize';
  static const String tokenUrl = '$kKickOAuthBase/oauth/token';

  final String clientId;
  final String? clientSecret;
  final String? proxyBaseUrl;
  final String redirectUri;
  final http.Client _http;

  static final _random = Random.secure();

  /// Generates a fresh PKCE session (verifier + S256 challenge + state).
  static KickPkceSession generatePkce() {
    String randomString(int length) {
      const charset =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
      return List.generate(length, (_) => charset[_random.nextInt(charset.length)])
          .join();
    }

    final verifier = randomString(64);
    final challenge = base64Url
        .encode(sha256.convert(utf8.encode(verifier)).bytes)
        .replaceAll('=', '');
    return KickPkceSession(
      verifier: verifier,
      challenge: challenge,
      state: randomString(24),
    );
  }

  /// Builds the URL the user must open in a browser to authorize the app.
  ///
  /// `response_type=code` is mandatory — without it Kick silently redirects
  /// to the (404) site root instead of showing an error.
  Uri buildAuthorizationUrl({
    required List<String> scopes,
    required KickPkceSession pkce,
  }) {
    return Uri.parse(authorizeUrl).replace(queryParameters: {
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'state': pkce.state,
      'scope': scopes.join(' '),
      'code_challenge': pkce.challenge,
      'code_challenge_method': 'S256',
      // Kick workaround: required when the redirect_uri host is 127.0.0.1.
      if (Uri.parse(redirectUri).host == '127.0.0.1') 'redirect': '127.0.0.1',
    });
  }

  /// Exchanges the authorization [code] for a user access token.
  Future<KickToken> exchangeCode({
    required String code,
    required KickPkceSession pkce,
  }) {
    return _tokenRequest({
      'grant_type': 'authorization_code',
      'code': code,
      'code_verifier': pkce.verifier,
      'redirect_uri': redirectUri,
    });
  }

  /// Refreshes an expired [token] using its refresh token.
  Future<KickToken> refresh(KickToken token) {
    return _tokenRequest({
      'grant_type': 'refresh_token',
      'refresh_token': token.refreshToken,
    });
  }

  /// Revokes an access or refresh token.
  Future<void> revoke(String token) async {
    final proxy = proxyBaseUrl;
    await _http.post(
      Uri.parse(proxy == null ? '$kKickOAuthBase/oauth/revoke' : '$proxy/revoke'),
      headers: proxy == null
          ? null
          : const {'Content-Type': 'application/json'},
      body: proxy == null
          ? {'token': token}
          : jsonEncode({'token': token}),
    );
  }

  Future<KickToken> _tokenRequest(Map<String, String> body) async {
    final proxy = proxyBaseUrl;
    final resp = await _http.post(
      Uri.parse(proxy == null ? tokenUrl : '$proxy/token'),
      headers: {
        'Content-Type': proxy == null
            ? 'application/x-www-form-urlencoded'
            : 'application/json',
      },
      body: proxy == null
          ? {
              'client_id': clientId,
              'client_secret': clientSecret!,
              ...body,
            }
          : jsonEncode(body),
    );
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw KickOAuthException('token request failed (${resp.statusCode}): $data');
    }
    return KickToken.fromJson(data);
  }
}
