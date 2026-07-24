import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/hermes_api.dart';
import 'chat_provider.dart';

/// 会话列表状态
final sessionsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final api = ref.read(apiProvider);
  final sessions = await api.getSessions();
  return sessions;
});
