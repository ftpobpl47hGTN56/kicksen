import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class KickEmote {
  const KickEmote({
    required this.name,
    required this.imageUrl,
    required this.provider,
  });

  final String name;
  final String imageUrl;
  final String provider;
}

/// Loads third-party emotes without making chat depend on their availability.
/// 7TV supports Kick channel sets; BetterTTV currently contributes global emotes.
class KickEmoteRepository {
  KickEmoteRepository({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final http.Client _http;
  Future<List<KickEmote>>? _globalFuture;
  final _channelCache = <int, Future<List<KickEmote>>>{};

  Future<List<KickEmote>> globalEmotes() {
    return _globalFuture ??= Future.wait([
      _load7TvGlobal(),
      _loadBttvGlobal(),
    ]).then((groups) => groups.expand((group) => group).toList());
  }

  Future<List<KickEmote>> channelEmotes(int kickUserId) {
    return _channelCache.putIfAbsent(
      kickUserId,
      () => _load7TvChannel(kickUserId),
    );
  }

  Future<List<KickEmote>> _load7TvGlobal() async {
    try {
      final data = await _getJson('https://7tv.io/v3/emote-sets/global');
      return _parse7TvEmotes((data['emotes'] as List?) ?? const []);
    } catch (_) {
      return [];
    }
  }

  Future<List<KickEmote>> _load7TvChannel(int kickUserId) async {
    try {
      final data = await _getJson('https://7tv.io/v3/users/kick/$kickUserId');
      final set = data['emote_set'] as Map<String, dynamic>?;
      return _parse7TvEmotes((set?['emotes'] as List?) ?? const []);
    } catch (_) {
      return [];
    }
  }

  Future<List<KickEmote>> _loadBttvGlobal() async {
    try {
      final data = await _getJson(
        'https://api.betterttv.net/3/cached/emotes/global',
      );
      if (data is! List) return [];
      return [
        for (final item in data.whereType<Map<String, dynamic>>())
          if (item['id'] is String && item['code'] is String)
            KickEmote(
              name: item['code'] as String,
              imageUrl:
                  'https://cdn.betterttv.net/emote/${item['id']}/2x',
              provider: 'BTTV',
            ),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<dynamic> _getJson(String url) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await _http
            .get(
              Uri.parse(url),
              headers: {
                'Accept': 'application/json',
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                    'AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36',
              },
            )
            .timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) {
          throw StateError('Emote request failed: ${response.statusCode}');
        }
        return jsonDecode(utf8.decode(response.bodyBytes));
      } catch (error) {
        lastError = error;
        if (attempt == 0) await Future.delayed(const Duration(seconds: 1));
      }
    }
    throw lastError ?? StateError('Emote request failed');
  }

  List<KickEmote> _parse7TvEmotes(List<dynamic> items) {
    final emotes = <KickEmote>[];
    for (final item in items.whereType<Map<String, dynamic>>()) {
      final name = item['name'];
      final data = item['data'] as Map<String, dynamic>?;
      final host = data?['host'] as Map<String, dynamic>?;
      final hostUrl = host?['url'];
      final files = (host?['files'] as List?) ?? const [];
      if (name is! String || hostUrl is! String) continue;

      Map<String, dynamic>? selected;
      for (final file in files.whereType<Map<String, dynamic>>()) {
        if (file['format'] != 'WEBP') continue;
        if (file['name'] == '2x.webp') {
          selected = file;
          break;
        }
        selected ??= file;
      }
      if (selected == null) continue;

      emotes.add(
        KickEmote(
          name: name,
          imageUrl: 'https:$hostUrl/${selected['name']}',
          provider: '7TV',
        ),
      );
    }
    return emotes;
  }

  void dispose() => _http.close();
}
