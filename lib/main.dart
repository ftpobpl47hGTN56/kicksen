import 'dart:async';

import 'package:kick_chat/kick_chat.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  runApp(const KicksenApp());
}

class KicksenApp extends StatelessWidget {
  const KicksenApp({super.key});

  static const kickGreen = Color(0xFF53FC18);

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: kickGreen,
      brightness: Brightness.dark,
    );

    return MaterialApp(
      title: 'Kicksen',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFF0D110E),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF111712),
          foregroundColor: Color(0xFFF1F5F1),
          centerTitle: false,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: const ChatPage(),
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  static const _maxMessages = 400;

  final _channelController = TextEditingController(text: 'xqc');
  final _scrollController = ScrollController();
  final _messages = <KickChatMessage>[];

  KickChatClient? _client;
  StreamSubscription<KickChatMessage>? _messageSubscription;
  StreamSubscription<KickChatStatus>? _statusSubscription;

  KickChatStatus _status = KickChatStatus.disconnected;
  String _channel = '';
  String? _error;
  int _generation = 0;
  bool _scrollScheduled = false;

  bool get _isConnecting =>
      _status == KickChatStatus.resolving ||
      _status == KickChatStatus.connecting ||
      _status == KickChatStatus.reconnecting;

  bool get _isConnected => _status == KickChatStatus.connected;

  @override
  void dispose() {
    _generation++;
    _channelController.dispose();
    _scrollController.dispose();
    unawaited(_messageSubscription?.cancel());
    unawaited(_statusSubscription?.cancel());
    final client = _client;
    if (client != null) unawaited(client.dispose());
    super.dispose();
  }

  Future<void> _connect() async {
    final channel = _normalizeChannel(_channelController.text);
    if (channel.isEmpty) {
      setState(() => _error = 'Введите название канала или ссылку на него.');
      return;
    }

    FocusScope.of(context).unfocus();
    final generation = ++_generation;
    await _closeClient();

    setState(() {
      _channel = channel;
      _messages.clear();
      _error = null;
      _status = KickChatStatus.resolving;
    });

    final client = KickChatClient();
    _client = client;

    _statusSubscription = client.status.listen((status) {
      if (!mounted || generation != _generation) return;
      setState(() => _status = status);
    });

    _messageSubscription = client.messages.listen((message) {
      if (!mounted || generation != _generation) return;

      final followLatest = !_scrollController.hasClients ||
          _scrollController.position.pixels >=
              _scrollController.position.maxScrollExtent - 96;

      setState(() {
        _messages.add(message);
        if (_messages.length > _maxMessages) {
          _messages.removeRange(0, _messages.length - _maxMessages);
        }
      });

      if (followLatest) _scheduleScrollToLatest();
    });

    try {
      await client.connect(channel);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _status = KickChatStatus.disconnected;
        _error = error.toString();
      });
      await client.dispose();
      if (generation == _generation) _client = null;
    }
  }

  Future<void> _disconnect() async {
    _generation++;
    await _closeClient();
    if (!mounted) return;
    setState(() {
      _status = KickChatStatus.disconnected;
      _error = null;
    });
  }

  Future<void> _closeClient() async {
    await _messageSubscription?.cancel();
    await _statusSubscription?.cancel();
    _messageSubscription = null;
    _statusSubscription = null;

    final client = _client;
    _client = null;
    if (client != null) await client.dispose();
  }

  void _scheduleScrollToLatest() {
    if (_scrollScheduled) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  String _normalizeChannel(String input) {
    var value = input.trim();
    if (value.contains('kick.com')) {
      final uri = Uri.tryParse(
        value.contains('://') ? value : 'https://$value',
      );
      if (uri != null && uri.pathSegments.isNotEmpty) {
        value = uri.pathSegments.first;
      }
    }
    value = value.replaceFirst(RegExp(r'^@+'), '');
    return value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
  }

  String get _statusLabel => switch (_status) {
        KickChatStatus.resolving => 'Поиск канала',
        KickChatStatus.connecting => 'Подключение',
        KickChatStatus.connected => 'В эфире',
        KickChatStatus.reconnecting => 'Переподключение',
        KickChatStatus.disconnected => 'Отключено',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Kicksen',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: _StatusBadge(label: _statusLabel)),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            _ChannelBar(
              controller: _channelController,
              isConnecting: _isConnecting,
              isConnected: _isConnected,
              onConnect: _connect,
              onDisconnect: _disconnect,
            ),
            if (_error != null) _ErrorBanner(message: _error!),
            Expanded(child: _buildChat()),
          ],
        ),
      ),
    );
  }

  Widget _buildChat() {
    if (_messages.isEmpty) {
      return _EmptyChat(
        status: _status,
        channel: _channel,
      );
    }

    return ListView.separated(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: _messages.length,
      separatorBuilder: (_, _) => const SizedBox(height: 7),
      itemBuilder: (context, index) => _MessageRow(message: _messages[index]),
    );
  }
}

class _ChannelBar extends StatelessWidget {
  const _ChannelBar({
    required this.controller,
    required this.isConnecting,
    required this.isConnected,
    required this.onConnect,
    required this.onDisconnect,
  });

  final TextEditingController controller;
  final bool isConnecting;
  final bool isConnected;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: controller,
      enabled: !isConnecting,
      textInputAction: TextInputAction.go,
      onSubmitted: isConnecting ? null : (_) => onConnect(),
      decoration: const InputDecoration(
        labelText: 'Канал Kick',
        hintText: 'xqc или https://kick.com/xqc',
        prefixIcon: Icon(Icons.tag),
      ),
    );

    final button = FilledButton.icon(
      onPressed: isConnecting || isConnected ? onDisconnect : onConnect,
      icon: isConnecting
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(isConnected ? Icons.stop : Icons.play_arrow),
      label: Text(
        isConnecting
            ? 'Отмена'
            : isConnected
                ? 'Отключиться'
                : 'Подключиться',
      ),
    );

    return Material(
      color: const Color(0xFF111712),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 560) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  field,
                  const SizedBox(height: 12),
                  SizedBox(height: 48, child: button),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: field),
                const SizedBox(width: 12),
                SizedBox(height: 48, child: button),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1B241C),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF3B1919),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: SelectableText(
        message,
        style: const TextStyle(color: Color(0xFFFFB4AB)),
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.status, required this.channel});

  final KickChatStatus status;
  final String channel;

  @override
  Widget build(BuildContext context) {
    final isLoading = status == KickChatStatus.resolving ||
        status == KickChatStatus.connecting ||
        status == KickChatStatus.reconnecting;
    final isLive = status == KickChatStatus.connected;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLoading)
              const CircularProgressIndicator()
            else
              Icon(
                isLive ? Icons.chat_bubble_outline : Icons.forum_outlined,
                size: 42,
                color: KicksenApp.kickGreen,
              ),
            const SizedBox(height: 16),
            Text(
              isLoading
                  ? 'Подключаемся к $channel…'
                  : isLive
                      ? 'Чат $channel подключён. Ожидаем сообщения…'
                      : 'Введите канал и подключитесь к живому чату.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.message});

  final KickChatMessage message;

  @override
  Widget build(BuildContext context) {
    final senderColor = _parseColor(message.sender.color);

    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.replyToSender != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                'Ответ ${message.replyToSender}: ${message.replyToContent ?? ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF9AA69B),
                  fontSize: 12,
                ),
              ),
            ),
          Text.rich(
            TextSpan(
              style: const TextStyle(
                color: Color(0xFFE7ECE8),
                fontSize: 15,
                height: 1.35,
              ),
              children: [
                for (final badge in message.sender.badges)
                  if (badge.text.isNotEmpty)
                    TextSpan(
                      text: '[${badge.text}] ',
                      style: const TextStyle(
                        color: Color(0xFFADB8AE),
                        fontSize: 12,
                      ),
                    ),
                TextSpan(
                  text: message.sender.username,
                  style: TextStyle(
                    color: senderColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const TextSpan(text: ': '),
                ..._contentSpans(message.content),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<InlineSpan> _contentSpans(String content) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'\[emote:(\d+):([^\]]+)\]');
    var offset = 0;

    for (final match in pattern.allMatches(content)) {
      if (match.start > offset) {
        spans.add(TextSpan(text: content.substring(offset, match.start)));
      }
      final emoteId = match.group(1)!;
      final emoteName = match.group(2)!;
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Tooltip(
            message: emoteName,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Image.network(
                kickEmoteUrl(emoteId),
                width: 30,
                height: 30,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Text(emoteName),
              ),
            ),
          ),
        ),
      );
      offset = match.end;
    }

    if (offset < content.length) {
      spans.add(TextSpan(text: content.substring(offset)));
    }
    if (spans.isEmpty) spans.add(TextSpan(text: content));
    return spans;
  }

  Color _parseColor(String? value) {
    if (value == null) return KicksenApp.kickGreen;
    final hex = value.replaceFirst('#', '');
    if (hex.length != 6 && hex.length != 8) return KicksenApp.kickGreen;
    final parsed = int.tryParse(hex, radix: 16);
    if (parsed == null) return KicksenApp.kickGreen;
    return Color(hex.length == 6 ? 0xFF000000 | parsed : parsed);
  }
}
