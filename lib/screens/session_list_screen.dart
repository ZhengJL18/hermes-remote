import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/chat_provider.dart';
import '../providers/session_provider.dart';

class SessionListScreen extends ConsumerWidget {
  const SessionListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionsAsync = ref.watch(sessionsProvider);
    final currentId = ref.watch(sessionIdProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('会话历史'),
      ),
      body: sessionsAsync.when(
        data: (sessions) {
          if (sessions.isEmpty) {
            return const Center(child: Text('暂无历史会话'));
          }

          // 第一行是当前活跃会话（如果有）
          return ListView.builder(
            itemCount: sessions.length,
            itemBuilder: (context, index) {
              final s = sessions[index];
              final id = s['id'] as String? ?? '';
              final title = s['title'] as String? ?? '未命名会话';
              final source = s['source'] as String? ?? '';
              final msgCount = s['message_count'] as int? ?? 0;
              final date = _formatDate(s['started_at']);
              final isActive = id == currentId;

              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: isActive
                      ? Colors.green
                      : _sourceColor(source),
                  child: Icon(
                    isActive ? Icons.sync : _sourceIcon(source),
                    size: 20,
                    color: Colors.white,
                  ),
                ),
                title: Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isActive) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.green.shade100,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '同步中',
                          style: TextStyle(fontSize: 10, color: Colors.green.shade700),
                        ),
                      ),
                    ],
                  ],
                ),
                subtitle: Text('$msgCount 条消息 · $date · $source'),
                trailing: isActive
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.chevron_right),
                onTap: () {
                  ref.read(sessionIdProvider.notifier).state = id;
                  ref.read(messagesProvider.notifier).loadSession(id, ref: ref);
                  ref.read(messagesProvider.notifier).startPolling(id, ref);
                  Navigator.pop(context);
                },
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
    );
  }

  Color _sourceColor(String source) {
    switch (source) {
      case 'api_server': return Colors.orange;
      case 'desktop': return Colors.blue;
      case 'cli': return Colors.green;
      default: return Colors.grey;
    }
  }

  IconData _sourceIcon(String source) {
    switch (source) {
      case 'api_server': return Icons.phone_android;
      case 'desktop': return Icons.desktop_windows;
      case 'cli': return Icons.terminal;
      default: return Icons.chat;
    }
  }

  String _formatDate(dynamic timestamp) {
    if (timestamp == null) return '';
    try {
      final dt = DateTime.parse(timestamp.toString());
      return '${dt.month}/${dt.day} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }
}
