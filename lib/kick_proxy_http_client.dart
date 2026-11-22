import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class KickProxyHttpClient extends http.BaseClient {
  static const _channel = MethodChannel('kicksen/oauth_proxy');

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    final result = await _channel.invokeMethod<Map<String, dynamic>>('post', {
      'url': request.url.toString(),
      'headers': request.headers,
      'body': body,
    });
    final responseBody = result?['body'] as List<int>? ?? const <int>[];
    final responseHeaders =
        (result?['headers'] as Map?)?.map(
          (key, value) => MapEntry(key.toString(), value.toString()),
        ) ??
        const <String, String>{};
    return http.StreamedResponse(
      http.ByteStream.fromBytes(responseBody),
      result?['status'] as int? ?? 500,
      headers: responseHeaders,
    );
  }
}
