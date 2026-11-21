/// Real-time Kick.com chat client.
///
/// Reading chat requires no authentication: Kick delivers chat over a public
/// Pusher WebSocket — the same one the kick.com frontend uses. Sending
/// messages is done separately through the official Kick API
/// (`https://api.kick.com/public/v1`) with OAuth 2.1 — see `kick_oauth.dart`
/// and `kick_api.dart`.
///
/// Note: the Pusher endpoint and the channel-lookup REST call are
/// undocumented/internal and may change without notice.
library kick_chat;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Process;

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

/// Pusher endpoint used by the kick.com frontend.
const String kKickPusherUrl =
    'wss://ws-us2.pusher.com/app/32cbd69e4b950bf97679'
    '?protocol=7&client=js&version=7.6.0&flash=false';

/// Pusher event carrying a chat message.
const String kChatMessageEvent = r'App\Events\ChatMessageEvent';

/// Browser UA used for the internal channel-lookup endpoint.
const String kBrowserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/120.0.0.0 Safari/537.36';

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
    this.raw = const {},
  });

  final String id;
  final int chatroomId;
  final String type;

  /// Raw message text. Emotes arrive as `[emote:ID:name]` tokens.
  final String content;

  final KickChatSender sender;
  final DateTime? createdAt;
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
  int? _chatroomId;

  /// Resolves the numeric chatroom ID for a channel slug.
  ///
  /// Uses Kick's internal `api/v2` endpoint because the official API does not
  /// expose chatroom IDs. The endpoint sits behind Cloudflare: Dart's HTTP
  /// stack gets TLS-fingerprint-blocked on many networks (HTTP 403), so on
  /// failure we fall back to a `curl` subprocess — the same workaround other
  /// Kick libraries use. If both fail, call [connectByChatroomId] with an ID
  /// taken from a real browser.
  Future<int> resolveChatroomId(String channel) async {
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
        final id = _parseChatroomId(resp.body);
        if (id != null) return id;
      }
    } catch (_) {
      // Fall through to the curl fallback.
    }
    return _resolveViaCurl(channel);
  }

  /// Fallback for [resolveChatroomId] when Cloudflare blocks Dart's TLS
  /// fingerprint: shells out to `curl`, which presents a browser-like
  /// fingerprint on most systems. Requires curl in PATH (present by default
  /// on macOS/Linux/Windows 10+; inside Flutter apps on mobile the Dart HTTP
  /// path usually works because the request comes from a residential IP).
  Future<int> _resolveViaCurl(String channel) async {
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
        final id = _parseChatroomId(result.stdout as String);
        if (id != null) return id;
      }
    } catch (_) {
      // curl missing or failed — handled below.
    }
    throw KickChatException(
      'could not resolve chatroom id for "$channel" (Cloudflare blocked the '
      'request). Use connectByChatroomId() with an ID taken from '
      'https://kick.com/api/v2/channels/$channel in a browser.',
    );
  }

  static int? _parseChatroomId(String body) {
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final id = (data['chatroom'] as Map<String, dynamic>?)?['id'];
      return id is int ? id : null;
    } catch (_) {
      return null;
    }
  }

  /// Resolves the chatroom ID and starts listening.
  Future<void> connect(String channel) async {
    _closed = false;
    _emitStatus(KickChatStatus.resolving);
    _chatroomId = await resolveChatroomId(channel);
    await _openSocket();
  }

  /// Starts listening with a known chatroom ID (skips the REST lookup).
  Future<void> connectByChatroomId(int chatroomId) async {
    _closed = false;
    _chatroomId = chatroomId;
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
    _emitStatus(KickChatStatus.connecting);
    try {
      final ws = WebSocketChannel.connect(Uri.parse(kKickPusherUrl));
      _ws = ws;
      await ws.ready;
      _wsSub = ws.stream.listen(_onFrame, onDone: _onDone, onError: (_) => _onDone());
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
          'data': {'auth': '', 'channel': 'chatrooms.$_chatroomId.v2'},
        });
      case 'pusher_internal:subscription_succeeded':
        _emitStatus(KickChatStatus.connected);
      case kChatMessageEvent:
        final msg = _parseMessage(event['data']);
        if (msg != null) _messages.add(msg);
      default:
        if (!_events.isClosed) _events.add(event);
    }
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
      return KickChatMessage(
        id: map['id'] as String? ?? '',
        chatroomId: map['chatroom_id'] as int? ?? _chatroomId ?? 0,
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
