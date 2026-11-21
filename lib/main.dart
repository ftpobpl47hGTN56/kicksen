import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kick_chat/kick_api.dart';
import 'package:kick_chat/kick_auth_dialog.dart';
import 'package:kick_chat/kick_channel_session.dart';
import 'package:kick_chat/kick_chat.dart';
import 'package:kick_chat/kick_emote_picker.dart';
import 'package:kick_chat/kick_emotes.dart';
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

String _statusLabel(KickChatStatus status) => switch (status) {
      KickChatStatus.resolving => 'Поиск канала',
      KickChatStatus.connecting => 'Подключение',
      KickChatStatus.connected => 'В эфире',
      KickChatStatus.reconnecting => 'Переподключение',
      KickChatStatus.disconnected => 'Отключено',
    };

Color _statusColor(KickChatStatus status) => switch (status) {
      KickChatStatus.connected => KicksenApp.kickGreen,
      KickChatStatus.resolving ||
      KickChatStatus.connecting ||
      KickChatStatus.reconnecting => const Color(0xFFFFC107),
      KickChatStatus.disconnected => const Color(0xFF768077),
    };

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  static const _maxMessages = 400;

  final _channelController = TextEditingController(text: 'tapiviao');
  final _emoteRepository = KickEmoteRepository();
  final _sessions = <KickChannelSession>[];

  KickToken? _token;
  KickOAuth? _oauth;
  KickApiClient? _api;
  KickUser? _user;

  var _selectedIndex = 0;
  String? _homeError;
  bool _authBusy = false;

  KickChannelSession? get _activeSession =>
      _selectedIndex == 0 ? null : _sessions[_selectedIndex - 1];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreSession());
  }

  @override
  void dispose() {
    _channelController.dispose();
    _emoteRepository.dispose();
    for (final session in _sessions) {
      unawaited(session.dispose());
    }
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

  Future<void> _sendMessage(KickChannelSession session) async {
    final content = session.composerController.text.trim();
    if (content.isEmpty || session.sending) return;
    if (!session.isConnected) {
      _showMessage('Сначала подключитесь к каналу.');
      return;
    }

    setState(() => session.sending = true);
    try {
      final api = await _validApi();
      if (api == null) {
        _showMessage('Сначала войдите через Kick.');
        return;
      }
      final target = await api.getChannelBySlug(session.channel);
      if (target == null) {
        throw KickApiException('Канал ${session.channel} не найден.');
      }
      await api.sendMessage(
        broadcasterUserId: target.broadcasterUserId,
        content: content,
      );
      session.composerController.clear();
    } catch (error) {
      _showMessage('Сообщение не отправлено: $error');
    } finally {
      if (mounted && _sessions.contains(session)) {
        setState(() => session.sending = false);
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _openChannel() {
    final channel = _normalizeChannel(_channelController.text);
    if (channel.isEmpty) {
      setState(() => _homeError = 'Введите название канала или ссылку на него.');
      return;
    }

    final existingIndex = _sessions.indexWhere(
      (session) => session.channel.toLowerCase() == channel.toLowerCase(),
    );
    if (existingIndex >= 0) {
      _selectSession(existingIndex);
      return;
    }

    final session = KickChannelSession(channel);
    setState(() {
      _sessions.add(session);
      _selectedIndex = _sessions.length;
      _homeError = null;
    });
    _bindSession(session);
    unawaited(_connectSession(session));
  }

  void _bindSession(KickChannelSession session) {
    session.statusSubscription = session.client.status.listen((status) {
      if (!mounted || !_sessions.contains(session)) return;
      setState(() => session.status = status);
    });

    session.messageSubscription = session.client.messages.listen((message) {
      if (!mounted || !_sessions.contains(session)) return;
      final followLatest = !session.scrollController.hasClients ||
          session.scrollController.position.pixels >=
              session.scrollController.position.maxScrollExtent - 96;

      setState(() {
        session.messages.add(message);
        if (session.messages.length > _maxMessages) {
          session.messages.removeRange(0, session.messages.length - _maxMessages);
        }
        if (!identical(_activeSession, session)) session.unread++;
      });

      if (followLatest) _scheduleScrollToLatest(session);
    });
  }

  Future<void> _connectSession(KickChannelSession session) async {
    if (session.isConnecting || !_sessions.contains(session)) return;
    final generation = ++session.generation;
    setState(() {
      session.error = null;
      session.status = KickChatStatus.resolving;
    });

    try {
      await session.client.connect(session.channel);
      if (!mounted || !_sessions.contains(session) || generation != session.generation) {
        return;
      }
      unawaited(_loadEmotes(session, generation));
    } catch (error) {
      if (!mounted || !_sessions.contains(session) || generation != session.generation) {
        return;
      }
      setState(() {
        session.status = KickChatStatus.disconnected;
        session.error = error.toString();
      });
    }
  }

  Future<void> _loadEmotes(KickChannelSession session, int generation) async {
    final kickUserId = session.client.channelIds?.userId;
    final global = await _emoteRepository.globalEmotes();
    final channel = kickUserId == null
        ? const <KickEmote>[]
        : await _emoteRepository.channelEmotes(kickUserId);
    if (!mounted || !_sessions.contains(session) || generation != session.generation) {
      return;
    }
    setState(() {
      session.emotes = {
        for (final emote in [...global, ...channel]) emote.name: emote,
      };
    });
  }

  Future<void> _disconnectSession(KickChannelSession session) async {
    session.generation++;
    await session.client.disconnect();
    if (!mounted || !_sessions.contains(session)) return;
    setState(() {
      session.status = KickChatStatus.disconnected;
      session.error = null;
    });
  }

  void _selectHome() {
    setState(() => _selectedIndex = 0);
  }

  void _selectSession(int index) {
    setState(() {
      _selectedIndex = index + 1;
      _sessions[index].unread = 0;
      _homeError = null;
    });
    _scheduleScrollToLatest(_sessions[index]);
  }

  void _closeSession(KickChannelSession session) {
    final index = _sessions.indexOf(session);
    if (index < 0) return;

    setState(() {
      _sessions.removeAt(index);
      if (_selectedIndex > index + 1) {
        _selectedIndex--;
      } else if (_selectedIndex == index + 1) {
        _selectedIndex = index == 0 ? 0 : index;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(session.dispose());
    });
  }

  void _scheduleScrollToLatest(KickChannelSession session) {
    if (session.scrollScheduled) return;
    session.scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      session.scrollScheduled = false;
      if (!mounted || !_sessions.contains(session) || !session.scrollController.hasClients) {
        return;
      }
      session.scrollController.jumpTo(session.scrollController.position.maxScrollExtent);
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

  @override
  Widget build(BuildContext context) {
    final active = _activeSession;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Kicksen',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            if (active != null) ...[
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Text('/', style: TextStyle(color: Color(0xFF768077))),
              ),
              Flexible(
                child: Text(
                  active.channel,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ],
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
            child: Center(
              child: _StatusBadge(
                label: active == null
                    ? 'Каналы: ${_sessions.length}'
                    : _statusLabel(active.status),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: IndexedStack(
          index: _selectedIndex,
          children: [
            _HomeView(
              controller: _channelController,
              error: _homeError,
              sessions: _sessions,
              onOpen: _openChannel,
              onSelect: _selectSession,
              onClose: _closeSession,
            ),
            for (final session in _sessions)
              _ChannelView(
                key: ValueKey(session),
                session: session,
                signedIn: _user != null,
                onSend: () => _sendMessage(session),
                onConnect: () => unawaited(_connectSession(session)),
                onDisconnect: () => unawaited(_disconnectSession(session)),
              ),
          ],
        ),
      ),
      bottomNavigationBar: _ChannelTabs(
        sessions: _sessions,
        selectedIndex: _selectedIndex,
        onHome: _selectHome,
        onSelect: _selectSession,
        onClose: _closeSession,
      ),
    );
  }
}

class _HomeView extends StatelessWidget {
  const _HomeView({
    required this.controller,
    required this.error,
    required this.sessions,
    required this.onOpen,
    required this.onSelect,
    required this.onClose,
  });

  final TextEditingController controller;
  final String? error;
  final List<KickChannelSession> sessions;
  final VoidCallback onOpen;
  final ValueChanged<int> onSelect;
  final ValueChanged<KickChannelSession> onClose;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 16),
                const Text(
                  'Каналы Kick',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Добавьте канал — его чат откроется в отдельной вкладке.',
                  style: TextStyle(color: Color(0xFF9AA69B), height: 1.4),
                ),
                const SizedBox(height: 20),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final field = TextField(
                      controller: controller,
                      textInputAction: TextInputAction.go,
                      onSubmitted: (_) => onOpen(),
                      decoration: const InputDecoration(
                        labelText: 'Канал Kick',
                        hintText: 'xqc или https://kick.com/xqc',
                        prefixIcon: Icon(Icons.tag),
                      ),
                    );
                    final button = FilledButton.icon(
                      onPressed: onOpen,
                      icon: const Icon(Icons.add),
                      label: const Text('Добавить канал'),
                    );
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
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(error!, style: const TextStyle(color: Color(0xFFFFB4AB))),
                ],
                const SizedBox(height: 28),
                if (sessions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Center(
                      child: Icon(Icons.forum_outlined, size: 48, color: KicksenApp.kickGreen),
                    ),
                  )
                else ...[
                  const Text(
                    'Открытые каналы',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  for (var index = 0; index < sessions.length; index++)
                    Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      color: const Color(0xFF151C16),
                      child: ListTile(
                        onTap: () => onSelect(index),
                        leading: CircleAvatar(
                          radius: 5,
                          backgroundColor: _statusColor(sessions[index].status),
                        ),
                        title: Text(sessions[index].channel),
                        subtitle: Text(_statusLabel(sessions[index].status)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (sessions[index].unread > 0)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: _UnreadBadge(count: sessions[index].unread),
                              ),
                            IconButton(
                              onPressed: () => onClose(sessions[index]),
                              tooltip: 'Закрыть канал',
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ChannelView extends StatelessWidget {
  const _ChannelView({
    super.key,
    required this.session,
    required this.signedIn,
    required this.onSend,
    required this.onConnect,
    required this.onDisconnect,
  });

  final KickChannelSession session;
  final bool signedIn;
  final VoidCallback onSend;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Material(
          color: const Color(0xFF111712),
          child: SizedBox(
            height: 44,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _statusColor(session.status),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Text(_statusLabel(session.status)),
                const Spacer(),
                TextButton.icon(
                  onPressed: session.isConnecting || session.isConnected
                      ? onDisconnect
                      : onConnect,
                  icon: Icon(
                    session.isConnecting || session.isConnected
                        ? Icons.stop
                        : Icons.refresh,
                    size: 18,
                  ),
                  label: Text(
                    session.isConnecting || session.isConnected
                        ? 'Отключиться'
                        : 'Подключиться',
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
        if (session.error != null) _ErrorBanner(message: session.error!),
        Expanded(child: _ChatMessages(session: session)),
        _Composer(
          controller: session.composerController,
          signedIn: signedIn,
          connected: session.isConnected,
          sending: session.sending,
          emotes: session.emotes,
          onSend: onSend,
        ),
      ],
    );
  }
}

class _ChatMessages extends StatelessWidget {
  const _ChatMessages({required this.session});

  final KickChannelSession session;

  @override
  Widget build(BuildContext context) {
    if (session.messages.isEmpty) {
      return _EmptyChat(session: session);
    }

    return ListView.separated(
      controller: session.scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: session.messages.length,
      separatorBuilder: (_, _) => const SizedBox(height: 7),
      itemBuilder: (context, index) => _MessageRow(
        message: session.messages[index],
        thirdPartyEmotes: session.emotes,
      ),
    );
  }
}

class _ChannelTabs extends StatelessWidget {
  const _ChannelTabs({
    required this.sessions,
    required this.selectedIndex,
    required this.onHome,
    required this.onSelect,
    required this.onClose,
  });

  final List<KickChannelSession> sessions;
  final int selectedIndex;
  final VoidCallback onHome;
  final ValueChanged<int> onSelect;
  final ValueChanged<KickChannelSession> onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF111712),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              _HomeTab(selected: selectedIndex == 0, onTap: onHome),
              const VerticalDivider(width: 1, color: Color(0xFF263027)),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var index = 0; index < sessions.length; index++)
                        _ChannelTab(
                          session: sessions[index],
                          selected: selectedIndex == index + 1,
                          onTap: () => onSelect(index),
                          onClose: () => onClose(sessions[index]),
                        ),
                    ],
                  ),
                ),
              ),
              IconButton(
                onPressed: onHome,
                tooltip: 'Добавить канал',
                icon: const Icon(Icons.add),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeTab extends StatelessWidget {
  const _HomeTab({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        width: 56,
        height: 56,
        child: Icon(
          Icons.home_outlined,
          color: selected ? KicksenApp.kickGreen : const Color(0xFF9AA69B),
        ),
      ),
    );
  }
}

class _ChannelTab extends StatelessWidget {
  const _ChannelTab({
    required this.session,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  final KickChannelSession session;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xFF203222) : null,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 190,
          height: 56,
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? KicksenApp.kickGreen : const Color(0xFF263027),
                width: 2,
              ),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: _statusColor(session.status),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  session.channel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (session.unread > 0) ...[
                _UnreadBadge(count: session.unread),
                const SizedBox(width: 4),
              ],
              IconButton(
                onPressed: onClose,
                tooltip: 'Закрыть ${session.channel}',
                iconSize: 17,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: KicksenApp.kickGreen,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: const TextStyle(
          color: Color(0xFF0D110E),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
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
  const _EmptyChat({required this.session});

  final KickChannelSession session;

  @override
  Widget build(BuildContext context) {
    final isLoading = session.isConnecting;
    final isLive = session.isConnected;

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
                  ? 'Подключаемся к ${session.channel}…'
                  : isLive
                      ? 'Чат ${session.channel} подключён. Ожидаем сообщения…'
                      : 'Канал ${session.channel} отключён.',
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
