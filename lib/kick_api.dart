/// Client for the official Kick API (https://api.kick.com/public/v1).
///
/// All endpoints require a user access token (see `kick_oauth.dart`) or an
/// app access token passed as `Authorization: Bearer <token>`.
library kick_api;

import 'dart:convert';

import 'package:http/http.dart' as http;

const String kKickApiBase = 'https://api.kick.com/public/v1';

class KickApiException implements Exception {
  KickApiException(this.message);
  final String message;

  @override
  String toString() => 'KickApiException: $message';
}

/// The authenticated user (`user:read`).
class KickUser {
  const KickUser({
    required this.userId,
    required this.name,
    this.email,
    this.profilePicture,
  });

  final int userId;
  final String name;
  final String? email;
  final String? profilePicture;

  factory KickUser.fromJson(Map<String, dynamic> json) => KickUser(
        userId: json['user_id'] as int,
        name: json['name'] as String,
        email: json['email'] as String?,
        profilePicture: json['profile_picture'] as String?,
      );
}

/// Public channel info (`channel:read`).
class KickChannelInfo {
  const KickChannelInfo({
    required this.broadcasterUserId,
    required this.slug,
    this.streamTitle,
    this.isLive = false,
    this.viewerCount = 0,
  });

  /// Needed as the `broadcaster_user_id` when posting to this channel's chat.
  final int broadcasterUserId;
  final String slug;
  final String? streamTitle;
  final bool isLive;
  final int viewerCount;

  factory KickChannelInfo.fromJson(Map<String, dynamic> json) {
    final stream = (json['stream'] as Map<String, dynamic>?) ?? const {};
    return KickChannelInfo(
      broadcasterUserId: json['broadcaster_user_id'] as int,
      slug: json['slug'] as String,
      streamTitle: json['stream_title'] as String?,
      isLive: stream['is_live'] as bool? ?? false,
      viewerCount: (stream['viewer_count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Who a chat message is posted as: the authorized user or the app (bot).
enum KickChatPosterType { user, bot }

/// Official Kick API client.
class KickApiClient {
  KickApiClient({required String accessToken, http.Client? httpClient})
      : _accessToken = accessToken,
        _http = httpClient ?? http.Client();

  final String _accessToken;
  final http.Client _http;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $_accessToken',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };

  /// The currently authenticated user.
  Future<KickUser> getCurrentUser() async {
    final data = await _request('GET', '/users');
    final list = (data['data'] as List?) ?? const [];
    if (list.isEmpty) {
      throw KickApiException('GET /users returned no data');
    }
    return KickUser.fromJson(list.first as Map<String, dynamic>);
  }

  /// Channel info by slug. Returns null if the channel does not exist.
  Future<KickChannelInfo?> getChannelBySlug(String slug) async {
    final data = await _request('GET', '/channels?slug=$slug');
    final list = (data['data'] as List?) ?? const [];
    if (list.isEmpty) return null;
    return KickChannelInfo.fromJson(list.first as Map<String, dynamic>);
  }

  /// Sends a chat message (max 500 chars). Scope: `chat:write`.
  ///
  /// Returns the message ID, or throws if the API rejected the message
  /// (e.g. slow mode, follower-only, banned word).
  Future<String> sendMessage({
    required int broadcasterUserId,
    required String content,
    KickChatPosterType type = KickChatPosterType.user,
    String? replyToMessageId,
  }) async {
    if (content.isEmpty || content.length > 500) {
      throw KickApiException('content must be 1..500 characters');
    }
    final data = await _request('POST', '/chat', body: {
      'broadcaster_user_id': broadcasterUserId,
      'content': content,
      'type': type.name,
      if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
    });
    final payload = (data['data'] as Map<String, dynamic>?) ?? const {};
    if (payload['is_sent'] != true) {
      throw KickApiException('message not sent: $data');
    }
    return payload['message_id'] as String? ?? '';
  }

  /// Deletes a chat message. Scope: `moderation:chat_message:manage`.
  Future<void> deleteMessage(String messageId) async {
    await _request('DELETE', '/chat/$messageId');
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final uri = Uri.parse('$kKickApiBase$path');
    late final http.Response resp;
    switch (method) {
      case 'GET':
        resp = await _http.get(uri, headers: _headers);
      case 'POST':
        resp = await _http.post(uri, headers: _headers, body: jsonEncode(body));
      case 'DELETE':
        resp = await _http.delete(uri, headers: _headers);
      default:
        throw ArgumentError.value(method, 'method');
    }
    final data = resp.body.isNotEmpty
        ? jsonDecode(resp.body) as Map<String, dynamic>
        : <String, dynamic>{};
    if (resp.statusCode >= 400) {
      final error = data['kick_error_description'] ??
          data['kick_error'] ??
          data['error_description'] ??
          data['error'] ??
          data['message'] ??
          resp.body;
      throw KickApiException('$method $path -> ${resp.statusCode}: $error');
    }
    return data;
  }
}
