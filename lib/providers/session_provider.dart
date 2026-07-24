import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/chat_database.dart';
import 'chat_provider.dart';

/// 会话列表 — 优先从本地数据库加载
final sessionsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final db = ref.read(dbProvider);
  // 本地加载
  final local = await db.getSessions();
  if (local.isNotEmpty) return local;
  // 本地为空时从云端同步
  return ref.read(messagesProvider.notifier).syncSessions();
});
