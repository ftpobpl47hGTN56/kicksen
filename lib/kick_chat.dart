/// Real-time Kick.com chat client.
///
/// Reading chat requires no authentication: Kick delivers chat over a public
/// Pusher WebSocket. Since October 2026 the Pusher app is **per-channel and
/// dynamic**: the client asks `web.kick.com/api/v1/realtime/...` which app
/// key/cluster to use (the old hardcoded key `32cbd69e4b950bf97679` now
/// returns Pusher error 4001). This client replicates that flow and keeps a
/// compiled-in fallback config.
///
/// Sending messages is done separately through the official Kick API
/// (`https://api.kick.com/public/v1`) with OAuth 2.1 — see `kick_oauth.dart`
/// and `kick_api.dart`.
///
/// Note: these endpoints are undocumented/internal and may change without
/// notice.
library kick_chat;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Process;
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

/// Pusher event carrying a chat message.
const String kChatMessageEvent = r'App\Events\ChatMessageEvent';

/// Browser UA used for the internal endpoints (they sit behind Cloudflare).
const String kBrowserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/120.0.0.0 Safari/537.36';

/// URL of the full-size image for an emote (from `[emote:{id}:{name}]` tokens).
String kickEmoteUrl(String id) => 'https://files.kick.com/emotes/$id/fullsize';

/// Which Pusher app to connect to. Since 2026-10 this is resolved at runtime
/// per channel; [fallback] is the last known-good compiled-in value.
class KickPusherConfig {
  const KickPusherConfig({required this.appKey, required this.cluster});

  /// Last known-good config (observed 2026-11), used when the realtime
  /// config endpoint is unreachable.
  static const fallback = KickPusherConfig(appKey: '34bf7a0ff419a2a775b9', cluster: 'us2');

  final String appKey;
  final String cluster;

  /// Same version parameters the kick.com web client sends.
  String get url =>
      'wss://ws-$cluster.pusher.com/app/$appKey'
      '?protocol=7&client=js&version=8.4.0&flash=false';
}

/// IDs of a Kick channel, resolved from its slug.
class KickChannelIds {
  const KickChannelIds({required this.channelId, required this.chatroomId});
  final int channelId;
  final int chatroomId;
}

enum KickChatStatus { resolving, connecting, connected, reconnecting, disconnected }

class KickChatException implements Exception {
  KickChatException(this.message);
  final String message;

  @override
  String toString() => 'KickChatException: $message';
}

/// A chat badge attached to a sender (subscriber, moderator, ...).
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

/// The author of a chat message.
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

/// A single chat message.
class KickChatMessage {
  const KickChatMessage({
    required this.id,
    required this.chatroomId,
    required this.type,
    required this.content,
    required this.sender,
    this.createdAt,
    this.replyToSender,
    this.replyToContent,
    this.raw = const {},
  });

  final String id;
  final int chatroomId;

  /// `message` or `reply`.
  final String type;

  /// Raw message text. Emotes arrive as `[emote:ID:name]` tokens —
  /// resolve them with [kickEmoteUrl].
  final String content;

  final KickChatSender sender;
  final DateTime? createdAt;

  /// For `type == 'reply'`: the author and text of the quoted message.
  final String? replyToSender;
  final String? replyToContent;

  final Map<String, dynamic> raw;
}

/// Reads the live chat of one Kick channel.
class KickChatClient {
  KickChatClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;

  final _messages = StreamController<KickChatMessage>.broadcast();
  final _status = StreamController<KickChatStatus>.broadcast();
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  /// Chat messages.
  Stream<KickChatMessage> get messages => _messages.stream;

  /// Connection lifecycle.
  Stream<KickChatStatus> get status => _status.stream;

  /// All other Pusher events (polls, deletions, bans, subscriptions) — raw.
  Stream<Map<String, dynamic>> get rawEvents => _events.stream;

  WebSocketChannel? _ws;
  StreamSubscription<dynamic>? _wsSub;
  Timer? _keepalive;
  bool _closed = true;

  KickChannelIds? _ids;
  KickPusherConfig? _config;

  /// Resolved IDs for the current channel, available after [connect] starts.
  KickChannelIds? get channelIds => _ids;

  static final _random = Random.secure();

  // ---------------------------------------------------------------------------
  // Channel + realtime config resolution
  // ---------------------------------------------------------------------------

  /// Resolves channel and chatroom IDs for a channel slug.
  ///
  /// Uses Kick's internal `api/v2` endpoint because the official API does not
  /// expose chatroom IDs. The endpoint sits behind Cloudflare: Dart's HTTP
  /// stack gets TLS-fingerprint-blocked on many networks (HTTP 403), so on
  /// failure we fall back to a `curl` subprocess — the same workaround other
  /// Kick libraries use.
  Future<KickChannelIds> resolveChannelIds(String channel) async {
    try {
      final resp = await _http
          .get(
            Uri.parse('https://kick.com/api/v2/channels/$channel'),
            headers: {
              'User-Agent': kBrowserUserAgent,
              'Accept': 'application/json',
              'Referer': 'https://kick.com/$channel',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode == 200) {
        final ids = _parseChannelIds(resp.body);
        if (ids != null) return ids;
      }
    } catch (_) {
      // Fall through to the curl fallback.
    }
    return _resolveChannelIdsViaCurl(channel);
  }

  Future<KickChannelIds> _resolveChannelIdsViaCurl(String channel) async {
    try {
      final result = await Process.run('curl', [
        '-s',
        '-m',
        '20',
        '-H',
        'User-Agent: $kBrowserUserAgent',
        '-H',
        'Accept: application/json',
        '-H',
        'Referer: https://kick.com/$channel',
        'https://kick.com/api/v2/channels/$channel',
      ]);
      if (result.exitCode == 0) {
        final ids = _parseChannelIds(result.stdout as String);
        if (ids != null) return ids;
      }
    } catch (_) {
      // curl missing or failed — handled below.
    }
    throw KickChatException(
      'could not resolve ids for "$channel" (Cloudflare blocked the request). '
      'Open https://kick.com/api/v2/channels/$channel in a browser and pass '
      'the ids via connectByIds().',
    );
  }

  static KickChannelIds? _parseChannelIds(String body) {
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final channelId = data['id'];
      final chatroomId = (data['chatroom'] as Map<String, dynamic>?)?['id'];
      if (channelId is int && chatroomId is int) {
        return KickChannelIds(channelId: channelId, chatroomId: chatroomId);
      }
    } catch (_) {}
    return null;
  }

  /// Asks Kick which Pusher app serves this channel's chat — the same call
  /// the kick.com frontend makes on every page load. Falls back to
  /// [KickPusherConfig.fallback] when the endpoint is unreachable.
  Future<KickPusherConfig> fetchRealtimeConfig(int channelId) async {
    try {
      final resp = await _http
          .post(
            Uri.parse('https://web.kick.com/api/v1/realtime'
                '/channels/$channelId/chat/connection'),
            headers: {
              'User-Agent': kBrowserUserAgent,
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'client': {
                'id': List.generate(
                    16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join(),
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
            ((data['data'] as Map<String, dynamic>?)?['connections'] as List?) ?? const [];
        for (final conn in connections.whereType<Map<String, dynamic>>()) {
          if (conn['provider'] == 'pusher') {
            final creds = (conn['credentials'] as Map<String, dynamic>?) ?? const {};
            final key = creds['app_key'];
            final cluster = creds['cluster'];
            if (key is String && cluster is String) {
              return KickPusherConfig(appKey: key, cluster: cluster);
            }
          }
        }
      }
    } catch (_) {
      // Fall through to the compiled-in fallback.
    }
    return KickPusherConfig.fallback;
  }

  // ---------------------------------------------------------------------------
  // Connection lifecycle
  // ---------------------------------------------------------------------------

  /// Resolves the channel IDs + realtime config and starts listening.
  Future<void> connect(String channel) async {
    _closed = false;
    _emitStatus(KickChatStatus.resolving);
    _ids = await resolveChannelIds(channel);
    _config = await fetchRealtimeConfig(_ids!.channelId);
    await _openSocket();
  }

  /// Starts listening with known IDs (skips the REST lookups, uses the
  /// fallback Pusher config).
  Future<void> connectByIds({required int channelId, required int chatroomId}) async {
    _closed = false;
    _ids = KickChannelIds(channelId: channelId, chatroomId: chatroomId);
    _config = KickPusherConfig.fallback;
    await _openSocket();
  }

  Future<void> disconnect() async {
    _closed = true;
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
      _wsSub = ws.stream.listen(_onFrame, onDone: _onDone, onError: (_) => _onDone());
      // Server activity_timeout is 120 s; ping well within it.
      _keepalive = Timer.periodic(const Duration(seconds: 30), (_) {
        _send({'event': 'pusher:ping', 'data': const {}});
      });
    } catch (_) {
      _onDone();
    }
  }

  void _send(Map<String, dynamic> payload) => _ws?.sink.add(jsonEncode(payload));

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
      case kChatMessageEvent:
        final msg = _parseMessage(event['data']);
        if (msg != null) _messages.add(msg);
      default:
        if (!_events.isClosed) _events.add(event);
    }
  }

  /// Pusher errors 4000–4099 mean the connection is not retryable with the
  /// current config (e.g. 4001 "app key not in this cluster" — Kick rotated
  /// the app). Re-ask the realtime config endpoint and reconnect.
  void _handlePusherError(dynamic rawData) {
    int code = 0;
    try {
      final data = rawData is String ? jsonDecode(rawData) : rawData;
      code = (data as Map<String, dynamic>)['code'] as int? ?? 0;
    } catch (_) {}
    if (code >= 4000 && code < 4100 && _ids != null && !_closed) {
      unawaited(fetchRealtimeConfig(_ids!.channelId).then((config) async {
        _config = config;
        await _teardownSocket();
        if (!_closed) await _openSocket();
      }));
    }
  }

  Future<void> _teardownSocket() async {
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
    Timer(const Duration(seconds: 3), () {
      if (!_closed) _openSocket();
    });
  }

  // ---------------------------------------------------------------------------
  // Message parsing
  // ---------------------------------------------------------------------------

  KickChatMessage? _parseMessage(dynamic raw) {
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      final map = decoded as Map<String, dynamic>;
      final sender = (map['sender'] as Map<String, dynamic>?) ?? const {};
      final identity = (sender['identity'] as Map<String, dynamic>?) ?? const {};
      final badges = ((identity['badges'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(KickBadge.fromJson)
          .toList();
      final originalSender = (map['original_sender'] as Map<String, dynamic>?) ?? const {};
      final originalMessage = (map['original_message'] as Map<String, dynamic>?) ?? const {};
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
        replyToSender: originalSender['username'] as String?,
        replyToContent: originalMessage['content'] as String?,
        raw: map,
      );
    } catch (_) {
      return null;
    }
  }

  void _emitStatus(KickChatStatus s) {
    if (!_status.isClosed) _status.add(s);
  }
}
