import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kick_chat/kick_api.dart';
import 'package:kick_chat/kick_auth_dialog.dart';
import 'package:kick_chat/kick_chat.dart';
import 'package:kick_chat/kick_emotes.dart';
import 'package:kick_chat/kick_emote_picker.dart';
import 'package:kick_chat/kick_oauth.dart';
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
  final _composerController = TextEditingController();
  final _scrollController = ScrollController();
  final _emoteRepository = KickEmoteRepository();
  final _messages = <KickChatMessage>[];
  var _emotes = <String, KickEmote>{};

  KickChatClient? _client;
  KickToken? _token;
  KickOAuth? _oauth;
  KickApiClient? _api;
  KickUser? _user;
  StreamSubscription<KickChatMessage>? _messageSubscription;
  StreamSubscription<KickChatStatus>? _statusSubscription;

  KickChatStatus _status = KickChatStatus.disconnected;
  String _channel = '';
  String? _error;
  int _generation = 0;
  bool _scrollScheduled = false;
  bool _authBusy = false;
  bool _sending = false;

  bool get _isConnecting =>
      _status == KickChatStatus.resolving ||
      _status == KickChatStatus.connecting ||
      _status == KickChatStatus.reconnecting;

  bool get _isConnected => _status == KickChatStatus.connected;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreSession());
  }

  @override
  void dispose() {
    _generation++;
    _channelController.dispose();
    _composerController.dispose();
    _scrollController.dispose();
    _emoteRepository.dispose();
    unawaited(_messageSubscription?.cancel());
    unawaited(_statusSubscription?.cancel());
    final client = _client;
    if (client != null) unawaited(client.dispose());
    super.dispose();
  }

  Future<void> _restoreSession() async {
    final file = File('.kick_token.json');
    if (!await file.exists()) return;

    try {
      var token = KickToken.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
      final clientId = Platform.environment['KICK_CLIENT_ID'];
      final clientSecret = Platform.environment['KICK_CLIENT_SECRET'];
      KickOAuth? oauth;
      if (clientId != null && clientSecret != null) {
        oauth = KickOAuth(
          clientId: clientId,
          clientSecret: clientSecret,
          redirectUri: 'http://localhost:3000/callback',
        );
      }
      if (token.isExpired) {
        if (oauth == null || token.refreshToken.isEmpty) return;
        token = await oauth.refresh(token);
        await file.writeAsString(jsonEncode(token.toJson()));
      }

      final api = KickApiClient(accessToken: token.accessToken);
      final user = await api.getCurrentUser();
      if (!mounted) return;
      setState(() {
        _token = token;
        _oauth = oauth;
        _api = api;
        _user = user;
      });
    } catch (_) {
      // An invalid or expired cache must not prevent manual sign-in.
    }
  }

  Future<void> _login() async {
    final result = await showDialog<KickLoginResult>(
      context: context,
      builder: (_) => const KickLoginDialog(),
    );
    if (result == null || !mounted) return;

    setState(() => _authBusy = true);
    try {
      final api = KickApiClient(accessToken: result.token.accessToken);
      final user = await api.getCurrentUser();
      await File('.kick_token.json').writeAsString(
        jsonEncode(result.token.toJson()),
      );
      if (!mounted) return;
      setState(() {
        _token = result.token;
        _oauth = result.oauth;
        _api = api;
        _user = user;
      });
      _showMessage('Вы вошли как ${user.name}');
    } catch (error) {
      _showMessage('Не удалось завершить вход: $error');
    } finally {
      if (mounted) setState(() => _authBusy = false);
    }
  }

  Future<void> _signOut() async {
    final oauth = _oauth;
    final token = _token;
    setState(() {
      _token = null;
      _oauth = null;
      _api = null;
      _user = null;
    });

    try {
      if (oauth != null && token != null && token.refreshToken.isNotEmpty) {
        await oauth.revoke(token.refreshToken);
      }
    } catch (_) {
      // Local sign-out still succeeds if the revocation endpoint is unavailable.
    }
    try {
      final file = File('.kick_token.json');
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<KickApiClient?> _validApi() async {
    var token = _token;
    if (token == null) return null;

    if (token.isExpired) {
      final oauth = _oauth;
      if (oauth == null || token.refreshToken.isEmpty) {
        setState(() {
          _token = null;
          _api = null;
          _user = null;
        });
        return null;
      }
      token = await oauth.refresh(token);
      await File('.kick_token.json').writeAsString(jsonEncode(token.toJson()));
      _token = token;
      _api = KickApiClient(accessToken: token.accessToken);
    }
    return _api;
  }

  Future<void> _sendMessage() async {
    final content = _composerController.text.trim();
    if (content.isEmpty || _sending) return;
    if (!_isConnected) {
      _showMessage('Сначала подключитесь к каналу.');
      return;
    }

    setState(() => _sending = true);
    try {
      final api = await _validApi();
      if (api == null) {
        _showMessage('Сначала войдите через Kick.');
        return;
      }
      final target = await api.getChannelBySlug(_channel);
      if (target == null) {
        throw KickApiException('Канал $_channel не найден.');
      }
      await api.sendMessage(
        broadcasterUserId: target.broadcasterUserId,
        content: content,
      );
      _composerController.clear();
    } catch (error) {
      _showMessage('Сообщение не отправлено: $error');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
    if (!mounted || generation != _generation) return;

    setState(() {
      _channel = channel;
      _messages.clear();
      _emotes = {};
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
      unawaited(_loadEmotes(client, generation));
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

  Future<void> _loadEmotes(KickChatClient client, int generation) async {
    final channelId = client.channelIds?.channelId;
    final global = await _emoteRepository.globalEmotes();
    final channel = channelId == null
        ? const <KickEmote>[]
        : await _emoteRepository.channelEmotes(channelId);
    if (!mounted || generation != _generation) return;
    setState(() {
      _emotes = {
        for (final emote in [...global, ...channel]) emote.name: emote,
      };
    });
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
          if (_user != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(child: Text(_user!.name)),
            ),
          TextButton.icon(
            onPressed: _authBusy
                ? null
                : _user == null
                    ? _login
                    : _signOut,
            icon: Icon(_user == null ? Icons.login : Icons.logout),
            label: Text(_user == null ? 'Войти' : 'Выйти'),
          ),
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
            _Composer(
              controller: _composerController,
              signedIn: _user != null,
              connected: _isConnected,
              sending: _sending,
              emotes: _emotes,
              onSend: _sendMessage,
            ),
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
      itemBuilder: (context, index) => _MessageRow(
        message: _messages[index],
        thirdPartyEmotes: _emotes,
      ),
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.signedIn,
    required this.connected,
    required this.sending,
    required this.emotes,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool signedIn;
  final bool connected;
  final bool sending;
  final Map<String, KickEmote> emotes;
  final VoidCallback onSend;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  var _suggestions = <KickEmote>[];

  @override
  void didUpdateWidget(covariant _Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.emotes != widget.emotes) _updateSuggestions();
    if (widget.sending && !oldWidget.sending) {
      setState(() => _suggestions = []);
    }
  }

  void _updateSuggestions() {
    final value = widget.controller.value;
    final cursor = value.selection.isValid ? value.selection.baseOffset : -1;
    if (cursor < 0 || cursor > value.text.length) {
      setState(() => _suggestions = []);
      return;
    }

    final match = RegExp(r'(?:^|\s)([^\s]*)$').firstMatch(
      value.text.substring(0, cursor),
    );
    final prefix = match?.group(1) ?? '';
    if (prefix.length < 2) {
      setState(() => _suggestions = []);
      return;
    }

    final query = prefix.toLowerCase();
    final matches = widget.emotes.values
        .where((emote) => emote.name.toLowerCase().startsWith(query))
        .take(6)
        .toList();
    if (mounted) setState(() => _suggestions = matches);
  }

  void _insertEmote(KickEmote emote) {
    final value = widget.controller.value;
    if (!value.selection.isValid) return;
    final cursor = value.selection.baseOffset;
    final before = value.text.substring(0, cursor);
    final match = RegExp(r'(?:^|\s)([^\s]*)$').firstMatch(before);
    final prefix = match?.group(1) ?? '';
    final start = cursor - prefix.length;
    final replacement = '${emote.name} ';
    final updated = value.text.replaceRange(start, cursor, replacement);
    widget.controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: start + replacement.length),
    );
    setState(() => _suggestions = []);
  }

  Future<void> _openEmotePicker() async {
    final emote = await showKickEmotePicker(
      context: context,
      emotes: widget.emotes,
    );
    if (emote == null || !mounted) return;
    _insertPickedEmote(emote);
  }

  void _insertPickedEmote(KickEmote emote) {
    final value = widget.controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final before = value.text.substring(0, start);
    final after = value.text.substring(end);
    final leadingSpace = before.isNotEmpty && !RegExp(r'\s$').hasMatch(before) ? ' ' : '';
    final trailingSpace = after.isEmpty || !RegExp(r'^\s').hasMatch(after) ? ' ' : '';
    final replacement = '$leadingSpace${emote.name}$trailingSpace';
    final updated = value.text.replaceRange(start, end, replacement);
    widget.controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: start + replacement.length),
    );
    setState(() => _suggestions = []);
  }

  void _submit() {
    setState(() => _suggestions = []);
    widget.onSend();
  }

  @override
  Widget build(BuildContext context) {
    final canSend = widget.signedIn && widget.connected && !widget.sending;
    final hint = !widget.connected
        ? 'Сначала подключитесь к каналу'
        : !widget.signedIn
            ? 'Можно проверить эмоуты; для отправки нужен вход'
            : 'Сообщение в чат…';

    return Material(
      color: const Color(0xFF111712),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            if (_suggestions.isNotEmpty)
              Container(
                constraints: const BoxConstraints(maxHeight: 280),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1B241C),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _suggestions.length,
                  itemBuilder: (context, index) {
                    final emote = _suggestions[index];
                    return ListTile(
                      dense: true,
                      onTap: () => _insertEmote(emote),
                      leading: Image.network(
                        emote.imageUrl,
                        width: 32,
                        height: 32,
                        fit: BoxFit.contain,
                      ),
                      title: Text(emote.name),
                      subtitle: Text(emote.provider),
                    );
                  },
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    enabled: widget.connected,
                    maxLength: 500,
                    textInputAction: TextInputAction.send,
                    onChanged: (_) => _updateSuggestions(),
                    onSubmitted: canSend ? (_) => _submit() : null,
                    decoration: InputDecoration(
                      hintText: hint,
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  onPressed: widget.connected && widget.emotes.isNotEmpty
                      ? _openEmotePicker
                      : null,
                  tooltip: 'Эмоуты',
                  icon: const Icon(Icons.emoji_emotions_outlined),
                ),
                IconButton(
                  onPressed: canSend ? _submit : null,
                  tooltip: 'Отправить',
                  icon: widget.sending
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                ),
              ],
            ),
          ],
        ),
      ),
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
  const _MessageRow({required this.message, required this.thirdPartyEmotes});

  final KickChatMessage message;
  final Map<String, KickEmote> thirdPartyEmotes;

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
        _addTextSpans(spans, content.substring(offset, match.start));
      }
      final emoteId = match.group(1)!;
      final emoteName = match.group(2)!;
      spans.add(_emoteSpan(kickEmoteUrl(emoteId), emoteName, 'Kick'));
      offset = match.end;
    }

    if (offset < content.length) _addTextSpans(spans, content.substring(offset));
    if (spans.isEmpty) _addTextSpans(spans, content);
    return spans;
  }

  void _addTextSpans(List<InlineSpan> spans, String text) {
    for (final part in text.split(RegExp(r'(\s+)'))) {
      if (part.isEmpty) continue;
      final emote = thirdPartyEmotes[part];
      if (emote == null) {
        spans.add(TextSpan(text: part));
      } else {
        spans.add(_emoteSpan(emote.imageUrl, emote.name, emote.provider));
      }
    }
  }

  WidgetSpan _emoteSpan(String url, String name, String provider) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Tooltip(
        message: '$name • $provider',
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Image.network(
            url,
            width: 30,
            height: 30,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => Text(name),
          ),
        ),
      ),
    );
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
