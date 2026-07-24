import 'dart:convert';
import 'dart:io';

class RelayClient {
  final String baseUrl;
  static const _apiKey = 'YOUR_RELAY_KEY';

  RelayClient({this.baseUrl = 'http://YOUR_SERVER_IP/relay'});

  void _setHeaders(HttpClientRequest r) {
    r.headers.set('X-API-Key', _apiKey);
    r.headers.set('Content-Type', 'application/json');
  }

  Future<bool> send(String content, {String? sessionId}) async {
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final r = await c.postUrl(Uri.parse('$baseUrl/send'));
      _setHeaders(r);
      r.write(jsonEncode({'content': content, 'session_id': sessionId ?? 'default', 'role': 'user'}));
      final resp = await r.close().timeout(const Duration(seconds: 10));
      c.close();
      return resp.statusCode == 200;
    } catch (_) { return false; }
  }

  Future<List<Map<String, dynamic>>> fetch({String? sessionId}) async {
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final url = sessionId != null ? '$baseUrl/fetch/$sessionId' : '$baseUrl/fetch';
      final r = await c.getUrl(Uri.parse(url));
      _setHeaders(r);
      final resp = await r.close().timeout(const Duration(seconds: 10));
      final body = await resp.transform(utf8.decoder).join();
      c.close();
      return (jsonDecode(body) as List).cast<Map<String, dynamic>>();
    } catch (_) { return []; }
  }

  Future<Map<String, dynamic>> status() async {
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final r = await c.getUrl(Uri.parse('$baseUrl/status'));
      _setHeaders(r);
      final resp = await r.close().timeout(const Duration(seconds: 5));
      final body = await resp.transform(utf8.decoder).join();
      c.close();
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) { return {}; }
  }

  Future<void> heartbeat() async {
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final r = await c.postUrl(Uri.parse('$baseUrl/heartbeat'));
      _setHeaders(r);
      r.write(jsonEncode({'who': 'phone'}));
      await r.close().timeout(const Duration(seconds: 5));
      c.close();
    } catch (_) {}
  }
}
