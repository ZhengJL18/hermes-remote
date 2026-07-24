import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

import '../models/chat_message.dart';
import '../config/api_config.dart';
import '../services/hermes_api.dart';
import '../services/relay_client.dart';
import '../services/connection_manager.dart';
import '../services/chat_database.dart';
import 'package:shared_preferences/shared_preferences.dart';

final relayProvider = Provider<RelayClient>((ref) => RelayClient());
final dbProvider = Provider<ChatDatabase>((ref) => ChatDatabase());

final apiProvider = Provider<HermesApi>((ref) => HermesApi());
final baseUrlProvider = StateProvider<String>((ref) => ApiConfig.defaultUrl);
final connectionStateProvider = StateProvider<GatewayState>((ref) => GatewayState.idle);
final connectionStatsProvider = StateProvider<Map<String, dynamic>>((ref) => {'rtt': 0, 'loss': ''});
final connectionManagerProvider = Provider<ConnectionManager>((ref) => ConnectionManager());
final messagesProvider = StateNotifierProvider<ChatNotifier, List<ChatMessage>>((ref) {
  return ChatNotifier(ref.read(apiProvider));
});
final isGeneratingProvider = StateProvider<bool>((ref) => false);
final sessionIdProvider = StateProvider<String?>((ref) => null);
final hasMoreProvider = StateProvider<bool>((ref) => false);
final pendingCountProvider = StateProvider<int>((ref) => 0);
/// 配置版本号 — Settings保存后递增，通知 chat_screen 重新探测
final configVersionProvider = StateProvider<int>((ref) => 0);
/// 电脑状态（来自 relay）：online, busy, queue_depth
final relayStatusProvider = StateProvider<Map<String, dynamic>>((ref) => {});

class ChatNotifier extends StateNotifier<List<ChatMessage>> {
  final HermesApi _api;
  Timer? _pollTimer;
  String? _pollSessionId;
  int _lastMessageCount = 0;
  String? _currentSessionId;
  bool _hasMore = false;
  int _pageSize = 20;

  /// 离线消息队列 — 发送失败暂存，恢复后自动重发
  final List<Map<String, dynamic>> _pendingQueue = [];
  Timer? _retryTimer;
  Timer? _relayPollTimer;
  final RelayClient _relay = RelayClient();

  ChatNotifier(this._api) : super([]);

  /// 启动 relay 轮询（拉取回复 + 发送心跳）
  void startRelayPoll(WidgetRef ref) {
    _relay.heartbeat();
    _relayPollTimer?.cancel();
    _relayPollTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      _relay.heartbeat();
      // 获取电脑状态
      final st = await _relay.status();
      ref.read(relayStatusProvider.notifier).state = st;
      // 获取回复
      final replies = await _relay.fetch(sessionId: _currentSessionId);
      for (final r in replies) {
        if (r['role'] == 'assistant' && r['content'] != null) {
          // 替换最后一个 assistant 占位或新增
          final lastIdx = state.length - 1;
          if (lastIdx >= 0 && state[lastIdx].role == MessageRole.assistant && state[lastIdx].content.isEmpty) {
            state = [...state.sublist(0, lastIdx), state[lastIdx].copyWith(content: r['content'].toString(), isStreaming: false)];
          } else {
            state = [...state, ChatMessage.assistant(r['content'].toString(), sessionId: _currentSessionId)];
          }
        }
      }
    });
  }

  void stopRelayPoll() {
    _relayPollTimer?.cancel();
  }

  /// 发送消息（优先 relay，回退直连）
  Future<void> sendMessage(String text, {String? sessionId, required WidgetRef ref}) async {
    if (ref.read(isGeneratingProvider)) return;
    if (text.trim().isEmpty) return;

    final userMsg = ChatMessage.user(text, sessionId: sessionId);
    state = [...state, userMsg];
    final assistantMsg = ChatMessage.assistant('☁️ 排队中...', sessionId: sessionId);
    state = [...state, assistantMsg];
    _lastMessageCount = state.length;
    ref.read(isGeneratingProvider.notifier).state = true;

    // 先发到 relay（云端队列）
    final relayOk = await _relay.send(text, sessionId: sessionId);
    if (relayOk) {
      startRelayPoll(ref);
      ref.read(isGeneratingProvider.notifier).state = false;
      return;
    }

    // relay 失败 → 走直连 SSE（回退）
    try {
      final messages = _buildMessages();
      final stream = _api.chatStream(messages: messages, sessionId: sessionId);
      await for (final chunk in stream) {
        final lastIdx = state.length - 1;
        if (chunk.content != null) {
          state = [...state.sublist(0, lastIdx),
            state[lastIdx].copyWith(content: state[lastIdx].content.replaceFirst('☁️ 排队中...', '') + chunk.content!, isStreaming: true)];
        }
        if (chunk.finishReason != null) {
          state = [...state.sublist(0, lastIdx), state[lastIdx].copyWith(isStreaming: false)];
        }
      }
      _lastMessageCount = state.length;
    } catch (e) {
      if (_pendingQueue.length < 50) _pendingQueue.add({'text': text, 'sessionId': sessionId});
      state = [...state.sublist(0, state.length - 1)];
      _startRetryTimer(ref);
    } finally {
      ref.read(isGeneratingProvider.notifier).state = false;
      ref.read(pendingCountProvider.notifier).state = _pendingQueue.length;
    }
  }

  List<Map<String, String>> _buildMessages() {
    final messages = <Map<String, String>>[];
    final src = state.length > 30 ? state.sublist(state.length - 30) : state;
    for (final msg in src) {
      final role = msg.role.name;
      if (msg.content.isEmpty) continue;
      if (role == 'user' && (msg.content.startsWith('[CONTEXT COMPACTION') || msg.content.startsWith('[skill_') || msg.content.startsWith('Conversation started:'))) continue;
      final content = role == 'tool' && msg.content.length > 200 ? '${msg.content.substring(0, 200)}...' : msg.content;
      messages.add({'role': role, 'content': content});
    }
    return messages;
  }

  void _startRetryTimer(WidgetRef ref) {
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_pendingQueue.isNotEmpty) _flushPending(ref);
      else _retryTimer?.cancel();
    });
  }

  Future<void> _flushPending(WidgetRef ref) async {
    if (_pendingQueue.isEmpty) return;
    final batch = List<Map<String, dynamic>>.from(_pendingQueue);
    for (final item in batch) {
      try {
        await sendMessage(item['text'], sessionId: item['sessionId'], ref: ref);
        _pendingQueue.remove(item);
        ref.read(pendingCountProvider.notifier).state = _pendingQueue.length;
      } catch (_) { break; }
    }
  }

  /// 连接恢复时触发重试
  void tryFlushPending(WidgetRef ref) {
    if (_pendingQueue.isNotEmpty) _flushPending(ref);
  }

  /// 加载会话 — 本地数据库优先，再云端同步
  Future<void> loadSession(String sessionId, {WidgetRef? ref}) async {
    _currentSessionId = sessionId;
    final db = ref?.read(dbProvider) ?? ChatDatabase();

    // 1. 先从本地数据库加载（秒开）
    final localMsgs = await db.loadMessages(sessionId);
    if (localMsgs.isNotEmpty) {
      state = localMsgs;
      _lastMessageCount = localMsgs.length;
    }

    // 2. 后台从云端同步最新消息
    try {
      final cloudMsgs = await _api.getSessionMessages(sessionId, limit: 200);
      final parsed = _parseMessages(cloudMsgs, sessionId);
      if (parsed.isNotEmpty) {
        state = parsed;
        _lastMessageCount = cloudMsgs.length;
        _hasMore = cloudMsgs.length >= 200;
        ref?.read(hasMoreProvider.notifier).state = _hasMore;
        // 写入本地数据库
        db.saveMessages(sessionId, parsed);
      }
    } catch (_) {}
  }

  /// 从云端同步会话列表到本地数据库
  Future<List<Map<String, dynamic>>> syncSessions() async {
    final db = ChatDatabase();
    try {
      final sessions = await _api.getSessions();
      for (final s in sessions) {
        await db.saveSession(s);
      }
      return sessions;
    } catch (_) {
      // cloud failed, return local
      return db.getSessions();
    }
  }

  /// 预加载最近会话的消息到本地缓存
  Future<void> preloadRecentSessions(WidgetRef ref) async {
    final db = ref.read(dbProvider);
    final sessions = await db.getSessions();
    // 缓存最近 5 条会话的消息
    for (int i = 0; i < sessions.length && i < 5; i++) {
      final sid = sessions[i]['id'] as String;
      try {
        final cloudMsgs = await _api.getSessionMessages(sid, limit: 200);
        final parsed = _parseMessages(cloudMsgs, sid);
        if (parsed.isNotEmpty) {
          await db.saveMessages(sid, parsed);
        }
      } catch (_) {}
    }
  }

  /// 获取最近使用的会话 ID
  Future<String?> getMostRecentSessionId() async {
    final db = ChatDatabase();
    final sessions = await db.getSessions();
    return sessions.isNotEmpty ? sessions.first['id'] as String? : null;
  }

  Future<void> _saveCache(String sessionId, List<ChatMessage> msgs) async {
    final prefs = await SharedPreferences.getInstance();
    final json = msgs.map((m) => jsonEncode({
      'id': m.id, 'role': m.role.name, 'content': m.content,
      'sessionId': m.sessionId, 'timestamp': m.timestamp.millisecondsSinceEpoch,
    })).toList();
    await prefs.setString('cache_$sessionId', jsonEncode(json));
    await prefs.setString('last_session', sessionId);
  }

  Future<List<ChatMessage>> _loadCache(String sessionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('cache_$sessionId');
      if (raw == null) return [];
      final list = jsonDecode(raw) as List;
      return list.map((j) => ChatMessage(
        id: j['id'] ?? '', role: MessageRole.values.firstWhere((r) => r.name == j['role']),
        content: j['content'] ?? '', sessionId: j['sessionId'],
        timestamp: DateTime.fromMillisecondsSinceEpoch(j['timestamp'] ?? 0),
      )).toList();
    } catch (_) { return []; }
  }

  /// 导出当前会话为 Markdown 文件到 Downloads
  Future<String?> exportSession() async {
    if (_currentSessionId == null || state.isEmpty) return null;
    try {
      final dir = await getDownloadsDirectory();
      if (dir == null) return null;
      final buf = StringBuffer();
      final now = DateTime.now();
      final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final timeStr = '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
      buf.writeln('# Hermes Chat Export');
      buf.writeln('> Session: $_currentSessionId');
      buf.writeln('> Exported: $dateStr $timeStr');
      buf.writeln();

      for (final msg in state) {
        if (msg.role == MessageRole.user) {
          buf.writeln('## You');
          buf.writeln(msg.content);
          buf.writeln();
        } else if (msg.role == MessageRole.assistant) {
          if (msg.content == '☁️ 排队中...') continue;
          buf.writeln('## Hermes');
          buf.writeln(msg.content);
          buf.writeln();
        } else if (msg.role == MessageRole.tool) {
          buf.writeln('### 🔧 ${msg.toolName ?? "Tool"}');
          buf.writeln('```');
          buf.writeln(msg.content.length > 500 ? '${msg.content.substring(0, 500)}...' : msg.content);
          buf.writeln('```');
          buf.writeln();
        }
      }

      final filename = 'hermes_chat_$dateStr-$timeStr.md';
      final file = File('${dir.path}/$filename');
      await file.writeAsString(buf.toString());
      return file.path;
    } catch (_) { return null; }
  }

  Future<void> loadMore(WidgetRef ref) async {
    if (_currentSessionId == null || !_hasMore) return;
    try {
      final allMessages = await _api.getSessionMessages(_currentSessionId!, limit: 200);
      final start = allMessages.length - _lastMessageCount - _pageSize;
      if (start < 0) { _hasMore = false; return; }
      final end = start + _pageSize > allMessages.length - _lastMessageCount
          ? allMessages.length - _lastMessageCount : start + _pageSize;
      final older = allMessages.sublist(start.clamp(0, allMessages.length), end.clamp(0, allMessages.length));
      if (older.isEmpty) { _hasMore = false; ref.read(hasMoreProvider.notifier).state = false; return; }
      final parsed = _parseMessages(older, _currentSessionId!);
      state = [...parsed, ...state];
      _lastMessageCount = allMessages.length;
    } catch (_) {}
  }

  List<ChatMessage> _parseMessages(List<dynamic> raw, String sessionId) {
    return raw.whereType<Map>().map((m) {
      final roleStr = (m['role'] ?? '').toString();
      final role = switch (roleStr) {
        'user' => MessageRole.user,
        'assistant' => MessageRole.assistant,
        'tool' => MessageRole.tool,
        _ => MessageRole.system,
      };
      final content = (m['content'] ?? '').toString();
      if (content.startsWith('[CONTEXT COMPACTION') || content.startsWith('[skill_') || content.startsWith('Conversation started:')) {
        return null;
      }
      return ChatMessage(id: m['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
          content: content, role: role, sessionId: sessionId);
    }).whereType<ChatMessage>().toList();
  }

  /// 同步服务器会话中的新消息
  Future<void> syncFromServer() async {
    if (_currentSessionId == null) return;
    try {
      final allMessages = await _api.getSessionMessages(_currentSessionId!, limit: 50);
      if (allMessages.length > _lastMessageCount) {
        final parsed = _parseMessages(allMessages.sublist(_lastMessageCount), _currentSessionId!);
        state = [...state, ...parsed];
        _lastMessageCount = allMessages.length;
      }
    } catch (_) {}
  }

  /// 清空当前会话消息
  void clear() { state = []; _lastMessageCount = 0; _currentSessionId = null; }

  void startPolling(String sessionId, WidgetRef ref) {
    _pollSessionId = sessionId;
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      try {
        final allMessages = await _api.getSessionMessages(sessionId, limit: 1);
        if (allMessages.length > _lastMessageCount) {
          final newMessages = allMessages.sublist(_lastMessageCount);
          final parsed = _parseMessages(newMessages, sessionId);
          state = [...state, ...parsed];
          _lastMessageCount = allMessages.length;
        }
      } catch (_) {}
    });
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollSessionId = null;
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _retryTimer?.cancel();
    super.dispose();
  }
}
