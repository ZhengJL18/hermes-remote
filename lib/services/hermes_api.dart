import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/api_config.dart';
import '../models/chat_chunk.dart';

/// Hermes API 服务 — SSE 流式聊天 + 会话管理
class HermesApi {
  ApiConfig config;
  HttpClient? _client;
  String get baseUrl => config.baseUrl;

  HermesApi() : config = ApiConfig.defaults();

  /// 动态切换通道（局域网/P2P/云服务器）
  void setBaseUrl(String url, {String? apiKey}) {
    config = ApiConfig(
      baseUrl: url,
      apiKey: apiKey ?? config.apiKey,
      model: config.model,
    );
  }

  HttpClient get _http {
    if (_client != null) return _client!;
    _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..idleTimeout = const Duration(seconds: 300)
      ..autoUncompress = true;
    return _client!;
  }

  /// SSE 流式聊天
  /// 返回 Stream<ChatChunk>，UI 层逐 chunk 追加文字
  Stream<ChatChunk> chatStream({
    required List<Map<String, String>> messages,
    String? sessionId,
  }) async* {
    final client = _http;
    final uri = Uri.parse(config.chatUrl);

    final body = jsonEncode({
      'model': config.model,
      'messages': messages,
      'stream': true,
    });

    try {
      final request = await client.postUrl(uri);
      request.headers.set('Content-Type', 'application/json');
      request.headers.set('Authorization', 'Bearer ${config.apiKey}');
      if (sessionId != null) {
        request.headers.set('X-Hermes-Session-Id', sessionId);
      }
      final bytes = utf8.encode(body);
      request.headers.set('Content-Length', bytes.length.toString());
      request.add(bytes);

      final response = await request.close();

      if (response.statusCode != 200) {
        final errorBody = await response.transform(utf8.decoder).join();
        throw HttpException('HTTP ${response.statusCode}: $errorBody');
      }

      // 解析 SSE 流（逐字节解码，避免 Android 缓冲）
      String buffer = '';
      await for (final bytes in response) {
        buffer += utf8.decode(bytes);
        final lines = buffer.split('\n');
        buffer = lines.removeLast();

        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || !trimmed.startsWith('data: ')) continue;

          final payload = trimmed.substring(6);
          if (payload == '[DONE]') {
            yield ChatChunk(finishReason: 'stop');
            return;
          }

          try {
            final json = jsonDecode(payload) as Map<String, dynamic>;
            yield ChatChunk.fromJson(json);
          } catch (_) { /* skip malformed */ }
        }
      }
    } catch (e) {
      yield ChatChunk(content: '[错误] $e');
      rethrow;
    }
  }

  /// 获取会话列表
  Future<List<Map<String, dynamic>>> getSessions() async {
    final client = _http;
    final sessionBase = config.baseUrl.replaceAll('/v1', '');
    final uri = Uri.parse('$sessionBase/api/sessions');

    try {
      final request = await client.getUrl(uri);
      request.headers.set('Authorization', 'Bearer ${config.apiKey}');
      final response = await request.close();

      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        return List<Map<String, dynamic>>.from(data['data'] ?? []);
      }
    } catch (_) {}
    return [];
  }

  /// 加载某个会话的历史消息
  Future<List<Map<String, dynamic>>> getSessionMessages(String sessionId, {int limit = 20}) async {
    final client = _http;
    final sessionBase = config.baseUrl.replaceAll('/v1', '');
    final uri = Uri.parse('$sessionBase/api/sessions/$sessionId/messages?limit=$limit');

    try {
      final request = await client.getUrl(uri);
      request.headers.set('Authorization', 'Bearer ${config.apiKey}');
      final response = await request.close();

      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        return List<Map<String, dynamic>>.from(data['data'] ?? []);
      }
    } catch (_) {}
    return [];
  }

  void dispose() {
    _client?.close();
  }
}
