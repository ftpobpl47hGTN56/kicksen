import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class KickProxyHttpClient extends http.BaseClient {
  static const _channel = MethodChannel('kicksen/oauth_proxy');

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    final result = await _channel.invokeMethod<dynamic>('request', {
      'method': request.method,
      'url': request.url.toString(),
      'headers': request.headers,
      'body': body,
    });
    final response = Map<String, dynamic>.from(result as Map);
    final responseBody = response['body'] as List<int>? ?? const <int>[];
    final responseHeaders = (response['headers'] as Map?)?.map(
          (key, value) => MapEntry(key.toString(), value.toString()),
        ) ??
        const <String, String>{};
    return http.StreamedResponse(
      http.ByteStream.fromBytes(responseBody),
      response['status'] as int? ?? 500,
      headers: responseHeaders,
    );
  }
}
