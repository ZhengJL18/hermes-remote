import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

/// Hermes API 配置 — 多通道自动切换
class ApiConfig {
  static const _candidates = [
    'http://YOUR_LAN_IP:8642/v1',
    'http://YOUR_SERVER_IP/hermes/v1',
  ];

  static const String defaultApiKey = 'YOUR_API_KEY';
  static const String defaultModel = 'hermes-agent';

  final String baseUrl;
  final String apiKey;
  final String model;
  String? _lanUrl;

  ApiConfig({required this.baseUrl, required this.apiKey, required this.model});

  /// 从本地存储加载配置，没有则用默认值
  static Future<ApiConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('api_url') ?? _candidates.last;
    final key = prefs.getString('api_key') ?? defaultApiKey;
    final lanUrl = prefs.getString('lan_url');  // 局域网地址
    final config = ApiConfig(baseUrl: url, apiKey: key, model: defaultModel);
    config._lanUrl = lanUrl;
    return config;
  }

  factory ApiConfig.defaults() {
    return ApiConfig(baseUrl: _candidates.last, apiKey: defaultApiKey, model: defaultModel);
  }

  /// 探测最快通道，优先用已保存的 URL
  static Future<String> probe({String? preferUrl}) async {
    final candidates = <String>[];
    if (preferUrl != null) candidates.add(preferUrl);
    // 加载保存的地址
    final prefs = await SharedPreferences.getInstance();
    final savedUrl = prefs.getString('api_url');
    final savedLan = prefs.getString('lan_url');
    if (savedLan != null && savedLan.isNotEmpty) candidates.add(savedLan);
    if (savedUrl != null && !candidates.contains(savedUrl)) candidates.add(savedUrl);
    candidates.addAll(_candidates.where((c) => !candidates.contains(c)));

    final futures = candidates.map((url) async {
      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
        final stopwatch = Stopwatch()..start();
        final request = await client.getUrl(Uri.parse('${url.replaceAll('/v1', '')}/health'));
        request.headers.set('Authorization', 'Bearer $defaultApiKey');
        final response = await request.close().timeout(const Duration(seconds: 3));
        final rtt = stopwatch.elapsedMilliseconds;
        client.close();
        if (response.statusCode == 200 && rtt < 1000) return (url, rtt);
      } catch (_) {}
      return null;
    }).toList();

    // 取第一个成功的（最快）
    for (final f in futures) {
      final result = await f;
      if (result != null) {
        // 更新候选列表—最快通道排第一
        _fastest = result.$1;
        return result.$1;
      }
    }
    return _candidates.isNotEmpty ? (_fastest ?? _candidates.last) : '';
  }

  static String? _fastest;

  String get chatUrl => '$baseUrl/chat/completions';

  String get sessionsUrl {
    final root = baseUrl.replaceAll('/v1', '');
    return '$root/api/sessions';
  }
}
