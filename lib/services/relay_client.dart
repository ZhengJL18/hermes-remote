// ═══════════════════════════════════════════════════════════════════
//  [B] relay_client.dart — 手机与云端 relay 通信 (Dart) 修复版
//  改动点见各处 [FIX-n] 注释，对应聊天里的分析报告
// ═══════════════════════════════════════════════════════════════════
import 'dart:convert';
import 'dart:io';
import '../config/api_config.dart';

/// [FIX-17] fetch/status 需要区分"没有数据"和"请求失败(网络/鉴权)"，
/// 用统一的结果包装类替代直接返回空 List / 空 Map。
class RelayResult<T> {
  final T? data;
  final bool ok;
  final int? statusCode;
  const RelayResult.success(this.data)
      : ok = true,
        statusCode = 200;
  const RelayResult.failure(this.statusCode)
      : ok = false,
        data = null;
}

class RelayClient {
  final String baseUrl;
  static const _apiKey = ApiConfig.defaultRelayKey;

  // [FIX-13] 复用同一个 HttpClient，开启 keep-alive，
  // 避免每次请求都新建 TCP 连接（对本就不稳定的隧道是不小的负担）。
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 30);

  RelayClient({this.baseUrl = ApiConfig.defaultRelayUrl});

  void _setHeaders(HttpClientRequest r) {
    r.headers.set('X-API-Key', _apiKey);
    r.headers.set('Content-Type', 'application/json');
  }

  /// [FIX-14] 统一 drain 响应体，避免不读body导致连接无法正常复用/关闭。
  Future<String> _drain(HttpClientResponse resp) {
    return resp.transform(utf8.decoder).join();
  }

  Future<bool> send(String content, {String? sessionId}) async {
    try {
      final r = await _client
          .postUrl(Uri.parse('$baseUrl/send'))
          .timeout(const Duration(seconds: 10));
      _setHeaders(r);
      r.write(jsonEncode({
        'content': content,
        'session_id': sessionId ?? 'default',
        'role': 'user',
      }));
      final resp = await r.close().timeout(const Duration(seconds: 10));
      await _drain(resp); // [FIX-14] 必须读完body，否则可能造成连接挂起/泄漏
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// [FIX-15] 用统一的 sessionId 编码，防止特殊字符破坏 URL 路由。
  /// [FIX-17] 明确区分状态码，401 会被上层识别为"鉴权失败"而不是"暂无消息"。
  Future<RelayResult<List<Map<String, dynamic>>>> fetch({String? sessionId}) async {
    try {
      final encodedSid = sessionId != null ? Uri.encodeComponent(sessionId) : null;
      final url = encodedSid != null ? '$baseUrl/fetch/$encodedSid' : '$baseUrl/fetch';
      final r = await _client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 10));
      _setHeaders(r);
      final resp = await r.close().timeout(const Duration(seconds: 10));
      final body = await _drain(resp);
      if (resp.statusCode != 200) {
        return RelayResult.failure(resp.statusCode);
      }
      final list = (jsonDecode(body) as List).cast<Map<String, dynamic>>();
      return RelayResult.success(list);
    } catch (_) {
      return const RelayResult.failure(null);
    }
  }

  Future<RelayResult<Map<String, dynamic>>> status() async {
    try {
      final r = await _client.getUrl(Uri.parse('$baseUrl/status')).timeout(const Duration(seconds: 5));
      _setHeaders(r);
      final resp = await r.close().timeout(const Duration(seconds: 5));
      final body = await _drain(resp);
      if (resp.statusCode != 200) {
        return RelayResult.failure(resp.statusCode);
      }
      return RelayResult.success(jsonDecode(body) as Map<String, dynamic>);
    } catch (_) {
      return const RelayResult.failure(null);
    }
  }

  /// [FIX-6] heartbeat 现在明确声明 who=phone，配合 relay 服务端修复后
  /// 服务端会分别记录"手机在线"和"电脑在线"，不再混为一谈。
  Future<void> heartbeat() async {
    try {
      final r = await _client.postUrl(Uri.parse('$baseUrl/heartbeat')).timeout(const Duration(seconds: 5));
      _setHeaders(r);
      r.write(jsonEncode({'who': 'phone'}));
      final resp = await r.close().timeout(const Duration(seconds: 5));
      await _drain(resp);
    } catch (_) {}
  }

  void dispose() {
    _client.close(force: true);
  }
}
