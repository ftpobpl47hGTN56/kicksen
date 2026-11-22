import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

/// Displays an emote from bytes, with a desktop curl fallback for networks where
/// Flutter's HTTP stack is blocked or fails TLS interception checks.
class KickEmoteImage extends StatefulWidget {
  const KickEmoteImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;

  @override
  State<KickEmoteImage> createState() => _KickEmoteImageState();
}

class _KickEmoteImageState extends State<KickEmoteImage> {
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36';
  static final _cache = <String, Future<Uint8List>>{};

  late Future<Uint8List> _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = _cachedDownload(widget.url);
  }

  @override
  void didUpdateWidget(covariant KickEmoteImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _bytes = _cachedDownload(widget.url);
    }
  }

  Future<Uint8List> _cachedDownload(String url) {
    return _cache.putIfAbsent(url, () => _download(url));
  }

  static Future<Uint8List> _download(String url) async {
    Object? httpError;
    try {
      final response = await http
          .get(
            Uri.parse(url),
            headers: {
              'Accept': 'image/avif,image/webp,image/png,image/*,*/*;q=0.8',
              'User-Agent': _userAgent,
            },
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == HttpStatus.ok &&
          response.bodyBytes.isNotEmpty) {
        return response.bodyBytes;
      }
      httpError = 'HTTP ${response.statusCode}';
    } catch (error) {
      httpError = error;
    }

    if (Platform.isAndroid) {
      throw StateError('Image download failed: $httpError');
    }

    try {
      final result = await Process.run('curl', [
        '-sS',
        '-L',
        '--fail',
        '--max-time',
        '20',
        '-A',
        _userAgent,
        url,
      ], stdoutEncoding: null);
      final stdout = result.stdout;
      if (result.exitCode == 0 && stdout is List<int> && stdout.isNotEmpty) {
        return Uint8List.fromList(stdout);
      }
      throw StateError('curl exit ${result.exitCode}: ${result.stderr}');
    } catch (curlError) {
      throw StateError('Image download failed: $httpError; curl: $curlError');
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null) {
          return Image.memory(
            bytes,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _failure(),
          );
        }
        if (snapshot.hasError) {
          debugPrint('${snapshot.error} (${widget.url})');
          return _failure();
        }
        return SizedBox(width: widget.width, height: widget.height);
      },
    );
  }

  Widget _failure() {
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: const Center(child: Icon(Icons.image_not_supported, size: 20)),
    );
  }
}
