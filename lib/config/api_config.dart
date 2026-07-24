import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

/// Hermes API 配置 — 多通道自动切换
class ApiConfig {
  /// ▼ 单点配置（占位符）：首次使用请在 Settings 填写实际值 ▼
  /// 保存后 SharedPreferences 持久化，不再读取此处的占位符
  static const _candidates = [
    'http://YOUR_LAN_IP:8642/v1',     // [0] 局域网直连
    'http://YOUR_SERVER_IP/hermes/v1', // [1] 云端通道（默认）
  ];

  /// 默认 API Key（占位符）— 在 Settings 中设置并保存
  static const String defaultApiKey = 'your-api-key-here';
  static const String defaultModel = 'hermes-agent';
  /// 默认 Relay 地址（占位符）
  static const String defaultRelayUrl = 'http://YOUR_SERVER_IP/relay';
  static const String defaultRelayKey = 'your-relay-key-here';

  final String baseUrl;
  final String apiKey;
  final String model;
  String? _lanUrl;

  ApiConfig({required this.baseUrl, required this.apiKey, required this.model});

  /// 默认远程地址（云端通道）
  static String get defaultUrl => _candidates.last;
  /// 默认局域网地址
  static String get defaultLanUrl => _candidates.first;

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
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
        final stopwatch = Stopwatch()..start();
        final request = await client.getUrl(Uri.parse('${url.replaceAll('/v1', '')}/health'));
        request.headers.set('Authorization', 'Bearer $defaultApiKey');
        final response = await request.close().timeout(const Duration(seconds: 5));
        final rtt = stopwatch.elapsedMilliseconds;
        client.close();
        if (response.statusCode == 200 && rtt < 5000) return (url, rtt);
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
    throw Exception('Hermes: 所有通道均无法连接');
  }

  static String? _fastest;

  String get chatUrl => '$baseUrl/chat/completions';

  String get sessionsUrl {
    final root = baseUrl.replaceAll('/v1', '');
    return '$root/api/sessions';
  }
}
