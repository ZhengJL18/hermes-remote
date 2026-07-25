// ═══════════════════════════════════════════════════════════════════
//  [C] api_config.dart — 配置中心 (Dart) 修复版
// ═══════════════════════════════════════════════════════════════════
import 'dart:async';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

class ApiConfig {
  static const _candidates = [
    'http://192.168.1.1:8642/v1',              // [FIX-23] 仍是占位符 —
                                                 //   真正要生效必须在 Settings 里填真实局域网IP,
                                                 //   否则这一条每次都会白白等5秒超时。
    'http://43.139.179.58/hermes/v1',
  ];

  static const String defaultApiKey = 'your-api-key-here';
  static const String defaultModel = 'hermes-agent';

  static const String defaultRelayUrl = 'http://43.139.179.58/relay';
  static const String defaultRelayKey = 'a86060ffec03405d';

  final String baseUrl;
  final String apiKey;
  final String model;
  String? _lanUrl;

  ApiConfig({required this.baseUrl, required this.apiKey, required this.model});

  static String get defaultUrl => _candidates.last;
  static String get defaultLanUrl => _candidates.first;

  static Future<ApiConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('api_url') ?? _candidates.last;
    final key = prefs.getString('api_key') ?? defaultApiKey;
    final lanUrl = prefs.getString('lan_url');
    final config = ApiConfig(baseUrl: url, apiKey: key, model: defaultModel);
    config._lanUrl = lanUrl;
    return config;
  }

  factory ApiConfig.defaults() {
    return ApiConfig(baseUrl: _candidates.last, apiKey: defaultApiKey, model: defaultModel);
  }

  static String? _fastest;

  /// [FIX-20] 真正的"谁先完成用谁" — 用 Completer 做一次竞速，
  /// 而不是 for-loop 顺序 await，不再被排在前面但很慢/不通的地址拖慢整体探测。
  /// [FIX-21] apiKey 现在必须由调用方传入(用户真实保存的key)，不再悄悄用占位符探测。
  static Future<String> probe({String? preferUrl, required String apiKey}) async {
    // [FIX-24] 如果之前探测成功过且还没失效，直接复用，省掉一整轮网络请求
    if (_fastest != null) return _fastest!;

    final candidates = <String>[];
    if (preferUrl != null) candidates.add(preferUrl);

    final prefs = await SharedPreferences.getInstance();
    final savedUrl = prefs.getString('api_url');
    final savedLan = prefs.getString('lan_url');
    if (savedLan != null && savedLan.isNotEmpty) candidates.add(savedLan);
    if (savedUrl != null && !candidates.contains(savedUrl)) candidates.add(savedUrl);
    candidates.addAll(_candidates.where((c) => !candidates.contains(c)));

    final completer = Completer<String>();
    int remaining = candidates.length;

    for (final url in candidates) {
      _probeOne(url, apiKey).then((rtt) {
        remaining--;
        if (rtt != null) {
          if (!completer.isCompleted) {
            _fastest = url;
            completer.complete(url);
          }
        } else if (remaining == 0 && !completer.isCompleted) {
          completer.completeError(Exception('Hermes: 所有通道均无法连接'));
        }
      });
    }
    return completer.future;
  }

  /// 探测单个地址，返回 rtt(ms)，失败返回 null。
  static Future<int?> _probeOne(String url, String apiKey) async {
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final stopwatch = Stopwatch()..start();
      final request =
          await client.getUrl(Uri.parse('${url.replaceAll('/v1', '')}/health'));
      request.headers.set('Authorization', 'Bearer $apiKey'); // [FIX-21]
      final response = await request.close().timeout(const Duration(seconds: 5));
      await response.drain(); // 必须把body读完，防止连接挂起
      final rtt = stopwatch.elapsedMilliseconds;
      client.close();
      if (response.statusCode == 200) return rtt;
    } catch (_) {}
    return null;
  }

  /// 手动使某次探测缓存失效（比如网络切换、探测失败后想强制重探）
  static void invalidateProbeCache() => _fastest = null;

  String get chatUrl => '$baseUrl/chat/completions';
  String get sessionsUrl {
    final root = baseUrl.replaceAll('/v1', ''); // [FIX-25] 已知局限：字符串替换比较脆弱，
                                                  //   仅在域名/路径不会出现"/v1"子串时安全。
    return '$root/api/sessions';
  }
}
