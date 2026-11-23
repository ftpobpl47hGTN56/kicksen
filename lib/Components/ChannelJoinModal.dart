import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_chatsen_irc/Kick.dart';
import 'package:flutter_chatsen_irc/Twitch.dart' as twitch;
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;

import '/Components/UserPrefs.dart';

class ChannelJoinModal extends StatefulWidget {
  final twitch.Client? client;
  final Function refresh;

  const ChannelJoinModal({
    Key? key,
    required this.client,
    required this.refresh,
  }) : super(key: key);

  @override
  State<ChannelJoinModal> createState() => _ChannelJoinModalState();
}

class _Ch {
  final String login;
  final String name;
  bool live;
  int? viewers;
  String? game;
  String? title;
  bool followed;

  _Ch(
      {required this.login,
      required this.name,
      this.live = false,
      this.viewers,
      this.game,
      this.title,
      this.followed = false});
}

class _ChannelJoinModalState extends State<ChannelJoinModal> {
  static const _initialChannels =
      'xqc,gladvalakaspwnz,myrongainesx,jonros,jfjrtkkygk-ftjftfvgym4,velcuz,greekgodx,creapoo,th3gazette1,westtennessee';

  final textEditingController = TextEditingController();
  final Set<String> selected = {};
  late final http.Client _http =
      KickChatClient.httpClientFactory?.call() ?? http.Client();

  List<_Ch> follows = [];
  List<_Ch> searchResults = [];
  bool loadingFollows = true;
  bool searching = false;
  bool joining = false;
  String? followsError;
  String? searchError;
  Timer? _debounce;
  int _searchGeneration = 0;

  twitch.Credentials? get _creds {
    final c = widget.client?.credentials;
    if (c?.token?.isNotEmpty == true) return c;
    final t = widget.client?.transmitters[null]?.credentials;
    if (t?.token?.isNotEmpty == true) return t;
    return null;
  }

  Map<String, String> get _baseHeaders => const {
        'User-Agent': kKickBrowserUserAgent,
        'Accept': 'application/json',
      };

  bool _joined(String login) =>
      widget.client?.channels
          .any((c) => c.name?.toLowerCase() == '#${login.toLowerCase()}') ??
      false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    String? importError;
    try {
      final settings = await Hive.openBox('KickLocal');
      if (settings.get('initialChannelsAdded') != true) {
        final names = _initialChannels
            .split(',')
            .map((name) => '#${name.trim().toLowerCase()}')
            .toList();
        final missing = names
            .where((name) =>
                !widget.client!.channels.any((channel) => channel.name == name))
            .toList();
        if (missing.isNotEmpty) {
          await widget.client!.joinChannels(missing);
        }
        final channelsBox = await Hive.openBox('Channels');
        await channelsBox.clear();
        await channelsBox
            .addAll(widget.client!.channels.map((channel) => channel.name));
        await settings.put('initialChannelsAdded', true);
        widget.refresh();
      }
    } catch (e) {
      importError = tr('Could not import the starter channels: $e',
          'Не удалось добавить стартовый список каналов: $e');
    }
    if (!mounted) return;
    await _loadFollows();
    if (importError != null && mounted) {
      setState(() => followsError = importError);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    textEditingController.dispose();
    _http.close();
    super.dispose();
  }

  Future<dynamic> _get(Uri uri) async {
    final headers = Map<String, String>.from(_baseHeaders);
    headers['Authorization'] = 'Bearer ${_creds!.token}';
    final response = await _http
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 20));
    dynamic body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw Exception(
          'HTTP ${response.statusCode}: пустой или неверный ответ Kick');
    }
    if (response.statusCode != 200) {
      final message = body is Map<String, dynamic> ? body['message'] : null;
      throw Exception(
          'HTTP ${response.statusCode}${message != null ? ': $message' : ''}');
    }
    return body;
  }

  Future<void> _loadFollows() async {
    setState(() {
      loadingFollows = true;
      followsError = null;
    });
    try {
      final channelsBox = await Hive.openBox('Channels');
      final logins = channelsBox.values
          .whereType<String>()
          .map((name) => name.replaceAll('#', '').trim().toLowerCase())
          .where((name) => name.isNotEmpty)
          .toSet()
          .toList();
      final list = [
        for (final login in logins)
          _Ch(login: login, name: login, followed: true),
      ];
      follows = list;
      final byLogin = {for (final channel in list) channel.login: channel};

      if (_creds != null) {
        for (var index = 0; index < list.length; index += 50) {
          final chunk = logins.sublist(
              index, index + 50 > logins.length ? logins.length : index + 50);
          final json = await _get(Uri.https(
              'api.kick.com', '/public/v1/channels', {'slug': chunk}));
          for (final raw in (json['data'] as List? ?? const [])) {
            if (raw is! Map<String, dynamic> || raw['slug'] is! String) {
              continue;
            }
            final channel = byLogin[(raw['slug'] as String).toLowerCase()];
            if (channel == null) continue;
            final stream = raw['stream'] is Map<String, dynamic>
                ? raw['stream'] as Map<String, dynamic>
                : const <String, dynamic>{};
            final category = raw['category'] is Map<String, dynamic>
                ? raw['category'] as Map<String, dynamic>
                : const <String, dynamic>{};
            channel
              ..live = stream['is_live'] == true
              ..viewers = _asInt(stream['viewer_count'])
              ..game = category['name'] as String?
              ..title = raw['stream_title'] as String?;
          }
        }
      }
      list.sort((a, b) {
        if (a.live != b.live) return a.live ? -1 : 1;
        if (a.live) return (b.viewers ?? 0).compareTo(a.viewers ?? 0);
        return a.login.compareTo(b.login);
      });
      if (!mounted) return;
      setState(() => loadingFollows = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loadingFollows = false;
        followsError = tr(
          'Could not update online statuses: $e. Pull down to retry.',
          'Не удалось обновить онлайн-статусы: $e. Потяните список вниз для повторной попытки.',
        );
      });
    }
  }

  int? _asInt(dynamic value) => value is int
      ? value
      : value is num
          ? value.toInt()
          : int.tryParse('$value');

  void _onQuery(String value) {
    setState(() {});
    _debounce?.cancel();
    _searchGeneration++;
    final query = value.trim().replaceAll('#', '');
    if (query.length < 2 ||
        query.contains(',') ||
        query.contains(' ') ||
        _creds == null) {
      setState(() {
        searchResults = [];
        searchError = null;
        searching = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350),
        () => _search(query, _searchGeneration));
  }

  Future<void> _search(String query, int generation) async {
    setState(() {
      searching = true;
      searchError = null;
    });
    try {
      final uri =
          Uri.https('api.kick.com', '/public/v1/channels', {'slug': query});
      final json = await _get(uri);
      if (!mounted || generation != _searchGeneration) return;
      final followed = {for (final channel in follows) channel.login};
      searchResults = [];
      for (final raw in (json['data'] as List? ?? const [])) {
        if (raw is! Map<String, dynamic> || raw['slug'] is! String) continue;
        final slug = (raw['slug'] as String).toLowerCase();
        final stream = raw['stream'] is Map<String, dynamic>
            ? raw['stream'] as Map<String, dynamic>
            : const <String, dynamic>{};
        final category = raw['category'] is Map<String, dynamic>
            ? raw['category'] as Map<String, dynamic>
            : const <String, dynamic>{};
        searchResults.add(_Ch(
          login: slug,
          name: slug,
          live: stream['is_live'] == true,
          viewers: _asInt(stream['viewer_count']),
          game: category['name'] as String?,
          title: raw['stream_title'] as String?,
          followed: followed.contains(slug),
        ));
      }
    } catch (e) {
      if (!mounted || generation != _searchGeneration) return;
      searchResults = [];
      searchError = tr('Search failed: $e', 'Ошибка поиска: $e');
    }
    if (mounted && generation == _searchGeneration)
      setState(() => searching = false);
  }

  Future<void> _join(Iterable<String> logins) async {
    if (joining) return;
    final names = logins
        .map((value) => '#${value.replaceAll('#', '').trim().toLowerCase()}')
        .where((name) => name.length > 1)
        .toSet()
        .toList();
    names.removeWhere((name) =>
        widget.client!.channels.any((channel) => channel.name == name));
    setState(() => joining = true);
    try {
      if (names.isNotEmpty) {
        await widget.client!.joinChannels(names);
        final channelsBox = await Hive.openBox('Channels');
        await channelsBox.clear();
        await channelsBox
            .addAll(widget.client!.channels.map((channel) => channel.name));
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('Could not add channels: $e',
              'Не удалось добавить каналы: $e'))));
    } finally {
      if (mounted) setState(() => joining = false);
    }
  }

  void _submitText() {
    final typed = textEditingController.text
        .replaceAll(' ', ',')
        .split(',')
        .where((value) => value.trim().isNotEmpty);
    _join([...selected, ...typed]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query =
        textEditingController.text.trim().replaceAll('#', '').toLowerCase();
    final filteredFollows = query.isEmpty
        ? follows
        : follows
            .where((channel) =>
                channel.login.contains(query) ||
                channel.name.toLowerCase().contains(query))
            .toList();
    final followLogins = {for (final channel in filteredFollows) channel.login};
    final extraSearch = searchResults
        .where((channel) => !followLogins.contains(channel.login))
        .toList();

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: textEditingController,
              autocorrect: false,
              autofocus: false,
              enabled: !joining,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search),
                hintText: tr('Saved channels or exact Kick username',
                    'Сохранённые каналы или точный ник Kick'),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                suffixIcon: textEditingController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          textEditingController.clear();
                          _onQuery('');
                        },
                      ),
              ),
              onChanged: _onQuery,
              onSubmitted: (_) => _submitText(),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _loadFollows,
              child: ListView(
                children: [
                  if (followsError != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(followsError!,
                          style: TextStyle(color: theme.colorScheme.error)),
                    ),
                  if (loadingFollows)
                    const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator())),
                  if (query.isEmpty &&
                      !loadingFollows &&
                      follows.isEmpty &&
                      followsError == null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(tr(
                        'No saved channels yet. Type an exact Kick username above.',
                        'Сохранённых каналов пока нет. Введите выше точный ник Kick.',
                      )),
                    ),
                  if (!loadingFollows && filteredFollows.isNotEmpty)
                    _header(
                      theme,
                      query.isEmpty
                          ? tr(
                              'Saved channels (${follows.length}) · LIVE: ${follows.where((channel) => channel.live).length}',
                              'Мои каналы (${follows.length}) · LIVE: ${follows.where((channel) => channel.live).length}')
                          : tr('Saved channels', 'Сохранённые каналы'),
                    ),
                  for (final channel in filteredFollows) _tile(theme, channel),
                  if (query.isNotEmpty && (searching || extraSearch.isNotEmpty))
                    _header(theme, tr('Kick API result', 'Результат Kick API')),
                  if (searching)
                    const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(
                            child: CircularProgressIndicator(strokeWidth: 2))),
                  for (final channel in extraSearch) _tile(theme, channel),
                  if (searchError != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(searchError!,
                          style: TextStyle(color: theme.colorScheme.error)),
                    ),
                  if (query.isNotEmpty &&
                      !searching &&
                      filteredFollows.isEmpty &&
                      extraSearch.isEmpty)
                    ListTile(
                      leading: const Icon(Icons.add),
                      title: Text(tr('Add \'$query\'', 'Добавить «$query»')),
                      subtitle: Text(tr('Nothing found — join by name directly',
                          'Ничего не найдено — подключиться по нику напрямую')),
                      onTap: _submitText,
                    ),
                ],
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: joining
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.add),
                  label: Text(selected.isEmpty
                      ? (query.isEmpty
                          ? tr('Select channels', 'Отметьте каналы')
                          : tr('Add \'$query\'', 'Добавить «$query»'))
                      : tr('Add (${selected.length})',
                          'Добавить (${selected.length})')),
                  onPressed: joining || (selected.isEmpty && query.isEmpty)
                      ? null
                      : _submitText,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(text,
            style: theme.textTheme.labelLarge
                ?.copyWith(color: theme.colorScheme.primary)),
      );

  Widget _tile(ThemeData theme, _Ch channel) {
    final joined = _joined(channel.login);
    final isSelected = selected.contains(channel.login);
    final subtitle = [
      if (channel.live)
        '🔴 ${channel.viewers != null ? '${channel.viewers} · ' : ''}${channel.game ?? 'LIVE'}',
      if (!channel.live && channel.followed && joined)
        tr('already open', 'уже открыт'),
      if (!channel.followed && !channel.live) tr('offline', 'оффлайн'),
    ].join();
    return ListTile(
      dense: true,
      enabled: !joined && !joining,
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipOval(
            child: SizedBox(
              width: 36,
              height: 36,
              child: Container(
                  color: theme.dividerColor,
                  child: const Icon(Icons.person, size: 20)),
            ),
          ),
          if (channel.live)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                      border: Border.all(color: theme.canvasColor, width: 2))),
            ),
        ],
      ),
      title: Text(
          channel.name.toLowerCase() == channel.login
              ? channel.name
              : '${channel.name} (${channel.login})',
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty && channel.title == null
          ? null
          : Text(
              channel.live && channel.title != null
                  ? '$subtitle — ${channel.title}'
                  : subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
      trailing: joined
          ? const Icon(Icons.check, size: 20)
          : IconButton(
              tooltip: tr('Add now', 'Добавить сразу'),
              icon: const Icon(Icons.add_circle_outline),
              onPressed: () => _join([channel.login, ...selected]),
            ),
      onTap: joined || joining
          ? null
          : () => setState(() {
                if (!selected.remove(channel.login))
                  selected.add(channel.login);
              }),
      selected: isSelected,
      selectedTileColor: theme.colorScheme.primary.withAlpha(30),
    );
  }
}
