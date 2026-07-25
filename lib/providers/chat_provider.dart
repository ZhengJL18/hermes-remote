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

  /// 轮询最大次数（10s*30=5分钟超时）
  static const _maxPollAttempts = 30;
  /// 重试最大次数
  static const _maxRetryAttempts = 5;
  int _pollAttempts = 0;
  int _retryAttempts = 0;
  bool _isPolling = false;
  int _pollGeneration = 0;             // [FIX-12] 每次开始/停止poll都自增；
                                        //   回调里比对代次，代次不符说明是"过期回调"，直接丢弃，
                                        //   防止 Timer.cancel() 无法打断的"已在执行中"的异步调用
                                        //   在会话切换后污染新会话的最后一条消息。

  ChatNotifier(this._api) : super([]);

  void _updatePlaceholder(String newContent, {bool isStreaming = false, String? messageId}) {
    // [FIX-12] 优先按 id 精确匹配；没传 id 时才退化为"最后一条"（保留旧调用点兼容）
    final idx = messageId != null
        ? state.indexWhere((m) => m.id == messageId)
        : state.length - 1;
    if (idx >= 0 && state[idx].role == MessageRole.assistant) {
      state = [...state.sublist(0, idx),
        state[idx].copyWith(content: newContent, isStreaming: isStreaming),
        ...state.sublist(idx + 1)];
    }
  }

  /// 启动 relay 轮询（拉取回复 + 心跳）
  void startRelayPoll(WidgetRef ref, {String? messageId}) {
    _relayPollTimer?.cancel();  // 取消旧定时器防止重叠
    _pollAttempts = 0;
    _isPolling = true;
    ref.read(isGeneratingProvider.notifier).state = true; // [FIX-10] 每次开poll都显式上锁,
                                                            //   不依赖调用方记得设置
    final myGeneration = ++_pollGeneration;  // [FIX-12] 记录本轮poll的代次

    _relayPollTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      // 代次已变(被stopRelayPoll或新一轮poll取代) → 这是过期回调,直接丢弃结果
      if (myGeneration != _pollGeneration) return;

      _pollAttempts++;
      final sid = _currentSessionId;
      if (sid == null) return;

      _relay.heartbeat();
      final statusResult = await _relay.status();
      if (myGeneration != _pollGeneration) return; // await期间可能已经过期,再check一次
      // [集成说明] relay_client.dart 修复版把 status()/fetch() 的返回类型
      // 改成了 RelayResult<T>，以区分"没有数据"和"请求失败/401"，这里同步适配。
      if (statusResult.ok && statusResult.data != null) {
        ref.read(relayStatusProvider.notifier).state = statusResult.data!;
      }

      final fetchResult = await _relay.fetch(sessionId: sid);
      if (myGeneration != _pollGeneration) return; // await期间可能已经过期,再check一次
      if (!fetchResult.ok) return; // 这一轮请求失败，等下一次tick再试，不当成"没有回复"处理
      final replies = fetchResult.data ?? [];
      for (final r in replies) {
        if (r['role'] == 'assistant' && r['content'] != null) {
          _updatePlaceholder(r['content'].toString(), messageId: messageId);
          _relayPollTimer?.cancel();
          _isPolling = false;
          ref.read(isGeneratingProvider.notifier).state = false;
          return;
        }
      }

      if (_pollAttempts >= _maxPollAttempts) {
        _updatePlaceholder('⚠️ 电脑长时间未响应', messageId: messageId);
        _relayPollTimer?.cancel();
        _isPolling = false;
        ref.read(isGeneratingProvider.notifier).state = false;
      }
    });
  }

  // [FIX-11] 必须传 ref 才能真正释放发送锁；_isPolling 也要重置，
  // 否则切会话后 sendMessage 的 finally 逻辑会永远判断"还在poll中"而拒绝释放锁，
  // 造成发送功能永久锁死。同时代次自增，让任何还没跑完的旧poll回调自动失效。
  void stopRelayPoll(WidgetRef ref) {
    _relayPollTimer?.cancel();
    _pollGeneration++;
    if (_isPolling) {
      _isPolling = false;
      ref.read(isGeneratingProvider.notifier).state = false;
    }
  }

  /// 发送消息（优先 relay，回退直连）
  Future<void> sendMessage(String text, {String? sessionId, required WidgetRef ref}) async {
    if (ref.read(isGeneratingProvider)) return;
    if (text.trim().isEmpty) return;

    _currentSessionId = sessionId;
    final userMsg = ChatMessage.user(text, sessionId: sessionId);
    state = [...state, userMsg];
    _lastMessageCount = state.length;

    // [FIX-2] 先构建不含占位符的上下文
    final ctxMessages = _buildContext();

    final assistantMsg = ChatMessage.assistant('☁️ 排队中...', sessionId: sessionId);
    state = [...state, assistantMsg];
    ref.read(isGeneratingProvider.notifier).state = true;

    try {
      // [FIX-7] _relay.send 包 try/catch
      bool relayOk = false;
      try {
        relayOk = await _relay.send(text, sessionId: sessionId);
      } catch (_) {
        relayOk = false;
      }

      if (relayOk) {
        // [FIX-3] relay 成功→开 poll 等回复
        //    关键：不在这里释放 isGenerating!
        //    等 poll 拿到真正的 AI 回复后才释放
        //    _isPolling/isGeneratingProvider 现在统一由 startRelayPoll 自己设置
        startRelayPoll(ref, messageId: assistantMsg.id);
        return;
      }

      // relay 失败 → SSE 直连
      final stream = _api.chatStream(messages: ctxMessages, sessionId: sessionId);
      await for (final chunk in stream) {
        if (chunk.content != null) {
          final idx = state.length - 1;
          if (idx >= 0 && state[idx].role == MessageRole.assistant) {
            state = [...state.sublist(0, idx),
              state[idx].copyWith(content: state[idx].content + chunk.content!, isStreaming: true),
              ...state.sublist(idx + 1)];
          }
        }
        if (chunk.finishReason != null) {
          final idx = state.length - 1;
          if (idx >= 0 && state[idx].role == MessageRole.assistant) {
            state = [...state.sublist(0, idx), state[idx].copyWith(isStreaming: false), ...state.sublist(idx + 1)];
          }
        }
      }
    } catch (e) {
      _updatePlaceholder('⚠️ 发送失败，稍后重试');
      // [FIX-8] 去重
      final dup = _pendingQueue.any((m) => m['text'] == text && m['sessionId'] == sessionId);
      if (!dup && _pendingQueue.length < 50) {
        _pendingQueue.add({'text': text, 'sessionId': sessionId, 'messageId': assistantMsg.id});
      }
      _startRetryTimer(ref);
    } finally {
      // [FIX-1] finally 兜底释放 isGenerating
      if (!_isPolling) {
        ref.read(isGeneratingProvider.notifier).state = false;
      }
      ref.read(pendingCountProvider.notifier).state = _pendingQueue.length;
    }
  }

  List<Map<String, String>> _buildContext() {
    final messages = <Map<String, String>>[];
    final src = state.length > 30 ? state.sublist(state.length - 30) : state;
    for (final msg in src) {
      final role = msg.role.name;
      if (msg.content.isEmpty) continue;
      if (msg.content.startsWith('☁️')) continue;  // 跳过占位符
      if (role == 'user' && (msg.content.startsWith('[CONTEXT COMPACTION') || msg.content.startsWith('[skill_') || msg.content.startsWith('Conversation started:'))) continue;
      messages.add({'role': role, 'content': msg.content});
    }
    return messages;
  }

  void _startRetryTimer(WidgetRef ref) {
    _retryTimer?.cancel();
    _retryAttempts = 0;
    _retryTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
      _retryAttempts++;
      if (_pendingQueue.isEmpty || _retryAttempts > _maxRetryAttempts) {
        timer.cancel();
        _retryTimer = null;
        for (final item in _pendingQueue) {
          _updatePlaceholder('❌ 重试失败，请手动重发');
        }
        _pendingQueue.clear();
        ref.read(pendingCountProvider.notifier).state = 0;
        ref.read(isGeneratingProvider.notifier).state = false;
        return;
      }
      _flushPending(ref);
    });
  }

  /// [FIX-6] flush 不再调 sendMessage，直接重发 relay + 重启 poll
  Future<void> _flushPending(WidgetRef ref) async {
    final items = List<Map<String, dynamic>>.from(_pendingQueue);
    for (final item in items) {
      final text = item['text'] as String;
      final sessionId = item['sessionId'] as String?;
      final messageId = item['messageId'] as String?;
      bool ok = false;
      try { ok = await _relay.send(text, sessionId: sessionId); } catch (_) { ok = false; }
      if (ok) {
        _pendingQueue.remove(item);
        ref.read(pendingCountProvider.notifier).state = _pendingQueue.length;
        // [FIX-10] 重发对应的是它自己排队时的 sessionId，不是当前全局 _currentSessionId
        _currentSessionId = sessionId;
        _updatePlaceholder('已重发，等待回复...', messageId: messageId);
        startRelayPoll(ref, messageId: messageId);  // 会自动把 isGenerating 重新上锁
        return;               // 一次只发一条
      }
    }
  }

  /// 连接恢复时触发重试
  void tryFlushPending(WidgetRef ref) {
    if (_pendingQueue.isNotEmpty) _flushPending(ref);
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _relayPollTimer?.cancel();
    _pollTimer?.cancel();
    super.dispose();
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
}
