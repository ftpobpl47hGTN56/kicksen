import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, Process;
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

const String kKickChatMessageEvent = r'App\Events\ChatMessageEvent';
const String kKickBrowserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/120.0.0.0 Safari/537.36';

String kickEmoteUrl(String id) => 'https://files.kick.com/emotes/$id/fullsize';

class KickPusherConfig {
  const KickPusherConfig({required this.appKey, required this.cluster});

  static const fallback = KickPusherConfig(
    appKey: '34bf7a0ff419a2a775b9',
    cluster: 'us2',
  );

  final String appKey;
  final String cluster;

  String get url =>
      'wss://ws-$cluster.pusher.com/app/$appKey'
      '?protocol=7&client=js&version=8.4.0&flash=false';
}

class KickChannelIds {
  const KickChannelIds({
    required this.channelId,
    required this.chatroomId,
    this.userId,
  });

  final int channelId;
  final int chatroomId;
  final int? userId;
}

enum KickChatStatus {
  resolving,
  connecting,
  connected,
  reconnecting,
  disconnected,
}

class KickChatException implements Exception {
  const KickChatException(this.message);
  final String message;

  @override
  String toString() => message;
}

class KickBadge {
  const KickBadge({required this.type, required this.text, this.count});

  final String type;
  final String text;
  final int? count;

  factory KickBadge.fromJson(Map<String, dynamic> json) => KickBadge(
        type: json['type'] as String? ?? '',
        text: json['text'] as String? ?? '',
        count: json['count'] as int?,
      );
}

class KickChatSender {
  const KickChatSender({
    required this.id,
    required this.username,
    required this.slug,
    this.color,
    this.badges = const [],
  });

  final int id;
  final String username;
  final String slug;
  final String? color;
  final List<KickBadge> badges;
}

class KickChatMessage {
  const KickChatMessage({
    required this.id,
    required this.chatroomId,
    required this.type,
    required this.content,
    required this.sender,
    this.createdAt,
    this.replyToId,
    this.replyToSender,
    this.replyToSlug,
    this.replyToContent,
    this.raw = const {},
  });

  final String id;
  final int chatroomId;
  final String type;
  final String content;
  final KickChatSender sender;
  final DateTime? createdAt;
  final String? replyToId;
  final String? replyToSender;
  final String? replyToSlug;
  final String? replyToContent;
  final Map<String, dynamic> raw;
}

class KickChatClient {
  static http.Client Function()? httpClientFactory;

  KickChatClient({http.Client? httpClient})
      : _http = httpClient ?? httpClientFactory?.call() ?? http.Client();

  final http.Client _http;
  final _messages = StreamController<KickChatMessage>.broadcast();
  final _status = StreamController<KickChatStatus>.broadcast();
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  Stream<KickChatMessage> get messages => _messages.stream;
  Stream<KickChatStatus> get status => _status.stream;
  Stream<Map<String, dynamic>> get rawEvents => _events.stream;

  WebSocketChannel? _ws;
  StreamSubscription<dynamic>? _wsSub;
  Timer? _keepalive;
  Timer? _retry;
  bool _closed = true;
  KickChannelIds? _ids;
  KickPusherConfig? _config;

  KickChannelIds? get channelIds => _ids;

  static final _random = Random.secure();

  Future<KickChannelIds> resolveChannelIds(String channel) async {
    try {
      final resp = await _http
          .get(
            Uri.parse('https://kick.com/api/v2/channels/$channel'),
            headers: {
              'User-Agent': kKickBrowserUserAgent,
              'Accept': 'application/json',
              'Referer': 'https://kick.com/$channel',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode == 200) {
        final ids = parseChannelIds(resp.body);
        if (ids != null) return ids;
      }
    } catch (_) {}
    if (!Platform.isAndroid) return _resolveChannelIdsViaCurl(channel);
    throw KickChatException(
      'Не удалось открыть канал "$channel": Kick заблокировал запрос.',
    );
  }

  Future<KickChannelIds> _resolveChannelIdsViaCurl(String channel) async {
    try {
      final result = await Process.run('curl', [
        '-s',
        '-m',
        '20',
        '-H',
        'User-Agent: $kKickBrowserUserAgent',
        '-H',
        'Accept: application/json',
        '-H',
        'Referer: https://kick.com/$channel',
        'https://kick.com/api/v2/channels/$channel',
      ]);
      if (result.exitCode == 0) {
        final ids = parseChannelIds(result.stdout as String);
        if (ids != null) return ids;
      }
    } catch (_) {}
    throw KickChatException(
      'Не удалось получить идентификаторы канала "$channel".',
    );
  }

  static KickChannelIds? parseChannelIds(String body) {
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final channelId = data['id'];
      final userId = data['user_id'];
      final chatroomId = (data['chatroom'] as Map<String, dynamic>?)?['id'];
      if (channelId is int && chatroomId is int) {
        return KickChannelIds(
          channelId: channelId,
          chatroomId: chatroomId,
          userId: userId is int ? userId : null,
        );
      }
    } catch (_) {}
    return null;
  }

  Future<KickPusherConfig> fetchRealtimeConfig(int channelId) async {
    try {
      final resp = await _http
          .post(
            Uri.parse(
              'https://web.kick.com/api/v1/realtime'
              '/channels/$channelId/chat/connection',
            ),
            headers: {
              'User-Agent': kKickBrowserUserAgent,
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'client': {
                'id': List.generate(
                  16,
                  (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
                ).join(),
                'type': 'web',
              },
              'capabilities': {
                'accepted_providers': [
                  {'provider': 'pusher'},
                ],
              },
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final connections =
            ((data['data'] as Map<String, dynamic>?)?['connections'] as List?) ??
                const [];
        for (final conn in connections.whereType<Map<String, dynamic>>()) {
          if (conn['provider'] == 'pusher') {
            final creds =
                (conn['credentials'] as Map<String, dynamic>?) ?? const {};
            final key = creds['app_key'];
            final cluster = creds['cluster'];
            if (key is String && cluster is String) {
              return KickPusherConfig(appKey: key, cluster: cluster);
            }
          }
        }
      }
    } catch (_) {}
    return KickPusherConfig.fallback;
  }

  Future<void> connect(String channel) async {
    _closed = false;
    _emitStatus(KickChatStatus.resolving);
    _ids = await resolveChannelIds(channel);
    if (_closed) return;
    _config = await fetchRealtimeConfig(_ids!.channelId);
    if (_closed) return;
    await _openSocket();
  }

  Future<void> disconnect() async {
    _closed = true;
    _retry?.cancel();
    _keepalive?.cancel();
    await _wsSub?.cancel();
    await _ws?.sink.close();
    _ws = null;
    _emitStatus(KickChatStatus.disconnected);
  }

  Future<void> dispose() async {
    await disconnect();
    await _messages.close();
    await _status.close();
    await _events.close();
    _http.close();
  }

  Future<void> _openSocket() async {
    final config = _config ?? KickPusherConfig.fallback;
    _emitStatus(KickChatStatus.connecting);
    try {
      final ws = WebSocketChannel.connect(Uri.parse(config.url));
      _ws = ws;
      await ws.ready;
      if (_closed) {
        await ws.sink.close();
        return;
      }
      _wsSub = ws.stream.listen(
        _onFrame,
        onDone: _onDone,
        onError: (_) => _onDone(),
      );
      _keepalive = Timer.periodic(const Duration(seconds: 30), (_) {
        _send({'event': 'pusher:ping', 'data': const {}});
      });
    } catch (_) {
      _onDone();
    }
  }

  void _send(Map<String, dynamic> payload) =>
      _ws?.sink.add(jsonEncode(payload));

  void _onFrame(dynamic frame) {
    final Map<String, dynamic> event;
    try {
      event = jsonDecode(frame as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (event['event']) {
      case 'pusher:connection_established':
        _send({
          'event': 'pusher:subscribe',
          'data': {'auth': '', 'channel': 'chatrooms.${_ids!.chatroomId}.v2'},
        });
      case 'pusher:error':
        _handlePusherError(event['data']);
      case 'pusher_internal:subscription_succeeded':
        _emitStatus(KickChatStatus.connected);
      case kKickChatMessageEvent:
        final msg = _parseMessage(event['data']);
        if (msg != null && !_messages.isClosed) _messages.add(msg);
      default:
        if (!_events.isClosed) _events.add(event);
    }
  }

  void _handlePusherError(dynamic rawData) {
    int code = 0;
    try {
      final data = rawData is String ? jsonDecode(rawData) : rawData;
      code = (data as Map<String, dynamic>)['code'] as int? ?? 0;
    } catch (_) {}
    if (code >= 4000 && code < 4100 && _ids != null && !_closed) {
      unawaited(
        fetchRealtimeConfig(_ids!.channelId).then((config) async {
          _config = config;
          await _teardownSocket();
          if (!_closed) await _openSocket();
        }),
      );
    }
  }

  Future<void> _teardownSocket() async {
    _retry?.cancel();
    _keepalive?.cancel();
    await _wsSub?.cancel();
    await _ws?.sink.close();
    _ws = null;
  }

  void _onDone() {
    _keepalive?.cancel();
    _wsSub?.cancel();
    _ws = null;
    if (_closed) {
      _emitStatus(KickChatStatus.disconnected);
      return;
    }
    _emitStatus(KickChatStatus.reconnecting);
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 3), () {
      if (!_closed) _openSocket();
    });
  }

  KickChatMessage? _parseMessage(dynamic raw) {
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      final map = decoded as Map<String, dynamic>;
      final sender = (map['sender'] as Map<String, dynamic>?) ?? const {};
      final identity =
          (sender['identity'] as Map<String, dynamic>?) ?? const {};
      final badges = ((identity['badges'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(KickBadge.fromJson)
          .toList();
      final originalSender =
          (map['original_sender'] as Map<String, dynamic>?) ?? const {};
      final originalMessage =
          (map['original_message'] as Map<String, dynamic>?) ?? const {};
      return KickChatMessage(
        id: map['id'] as String? ?? '',
        chatroomId: map['chatroom_id'] as int? ?? _ids?.chatroomId ?? 0,
        type: map['type'] as String? ?? 'message',
        content: map['content'] as String? ?? '',
        sender: KickChatSender(
          id: sender['id'] as int? ?? 0,
          username: sender['username'] as String? ?? 'unknown',
          slug: sender['slug'] as String? ?? '',
          color: identity['color'] as String?,
          badges: badges,
        ),
        createdAt: DateTime.tryParse(map['created_at'] as String? ?? ''),
        replyToId: originalMessage['id'] as String?,
        replyToSender: originalSender['username'] as String?,
        replyToSlug: originalSender['slug'] as String?,
        replyToContent: originalMessage['content'] as String?,
        raw: map,
      );
    } catch (_) {
      return null;
    }
  }

  void _emitStatus(KickChatStatus status) {
    if (!_status.isClosed) _status.add(status);
  }
}

class KickApiException implements Exception {
  const KickApiException(this.message);
  final String message;

  @override
  String toString() => message;
}

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

  Future<Map<String, dynamic>> getCurrentUser() async {
    final data = await _request('GET', '/users');
    final list = (data['data'] as List?) ?? const [];
    if (list.isEmpty) throw const KickApiException('Kick не вернул профиль.');
    return list.first as Map<String, dynamic>;
  }

  Future<String> sendMessage({
    required int broadcasterUserId,
    required String content,
    String? replyToMessageId,
  }) async {
    if (content.isEmpty || content.length > 500) {
      throw const KickApiException('Сообщение должно содержать 1–500 символов.');
    }
    final data = await _request('POST', '/chat', body: {
      'broadcaster_user_id': broadcasterUserId,
      'content': content,
      'type': 'user',
      if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
    });
    final payload = (data['data'] as Map<String, dynamic>?) ?? const {};
    if (payload['is_sent'] != true) {
      throw KickApiException('Kick не отправил сообщение: $data');
    }
    return payload['message_id'] as String? ?? '';
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final uri = Uri.parse('https://api.kick.com/public/v1$path');
    late final http.Response resp;
    switch (method) {
      case 'GET':
        resp = await _http.get(uri, headers: _headers);
      case 'POST':
        resp = await _http.post(uri, headers: _headers, body: jsonEncode(body));
      default:
        throw ArgumentError.value(method, 'method');
    }
    if (resp.body.isEmpty) {
      if (resp.statusCode >= 400) {
        throw KickApiException(
          'Kick API (${resp.statusCode}): пустой ответ для $method $path',
        );
      }
      return <String, dynamic>{};
    }
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(resp.body) as Map<String, dynamic>;
    } on FormatException {
      throw KickApiException(
        'Kick API (${resp.statusCode}): не JSON для $method $path: ${resp.body}',
      );
    }
    if (resp.statusCode >= 400) {
      final error = data['kick_error_description'] ??
          data['kick_error'] ??
          data['error_description'] ??
          data['error'] ??
          data['message'] ??
          resp.body;
      throw KickApiException('Kick API (${resp.statusCode}): $error');
    }
    return data;
  }

  void dispose() => _http.close();
}
