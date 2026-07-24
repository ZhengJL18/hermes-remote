import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../models/chat_message.dart';

/// 本地 JSON 文件聊天记录数据库 — 类似微信的消息持久化
class ChatDatabase {
  static ChatDatabase? _instance;
  String? _basePath;

  ChatDatabase._();
  factory ChatDatabase() => _instance ??= ChatDatabase._();

  Future<String> get _dir async {
    if (_basePath != null) return _basePath!;
    final dir = await getApplicationDocumentsDirectory();
    _basePath = dir.path;
    return _basePath!;
  }

  String _sessionsFile(String base) => p.join(base, 'hermes_sessions.json');
  String _msgFile(String sessionId, String base) => p.join(base, 'chat_$sessionId.json');

  /// 保存会话元数据
  Future<void> saveSession(Map<String, dynamic> session) async {
    final base = await _dir;
    final file = File(_sessionsFile(base));
    Map<String, dynamic> all = {};
    if (await file.exists()) {
      all = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    }
    all[session['id']] = {
      'title': session['title'] ?? '',
      'source': session['source'] ?? '',
      'message_count': session['message_count'] ?? 0,
      'preview': session['preview'] ?? '',
      'last_active': DateTime.now().millisecondsSinceEpoch,
    };
    await file.writeAsString(jsonEncode(all));
  }

  /// 保存多条消息
  Future<void> saveMessages(String sessionId, List<ChatMessage> messages) async {
    final base = await _dir;
    final file = File(_msgFile(sessionId, base));
    final existing = await _loadMsgJson(file);
    for (final msg in messages) {
      existing[msg.id] = _msgToJson(msg);
    }
    await file.writeAsString(jsonEncode(existing));
  }

  /// 保存单条消息
  Future<void> saveMessage(String sessionId, ChatMessage msg) async {
    await saveMessages(sessionId, [msg]);
  }

  /// 加载会话消息
  Future<List<ChatMessage>> loadMessages(String sessionId, {int limit = 200, int offset = 0}) async {
    final base = await _dir;
    final file = File(_msgFile(sessionId, base));
    final json = await _loadMsgJson(file);
    final entries = json.values.toList()
      ..sort((a, b) => (a['timestamp'] as int).compareTo(b['timestamp'] as int));
    final end = (offset + limit).clamp(0, entries.length);
    return entries.sublist(offset, end).map((j) => ChatMessage(
      id: j['id'] as String,
      role: MessageRole.values.firstWhere((e) => e.name == j['role']),
      content: j['content'] as String? ?? '',
      toolName: j['tool_name'] as String?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(j['timestamp'] as int),
      sessionId: sessionId,
    )).toList();
  }

  /// 获取会话列表
  Future<List<Map<String, dynamic>>> getSessions() async {
    final base = await _dir;
    final file = File(_sessionsFile(base));
    if (!await file.exists()) return [];
    final all = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return all.entries.map((e) => {
      'id': e.key,
      ...(e.value as Map<String, dynamic>),
    }).toList()
      ..sort((a, b) => ((b['last_active'] as int?) ?? 0).compareTo((a['last_active'] as int?) ?? 0));
  }

  /// 删除会话
  Future<void> deleteSession(String sessionId) async {
    final base = await _dir;
    // remove from sessions index
    final sf = File(_sessionsFile(base));
    if (await sf.exists()) {
      final all = jsonDecode(await sf.readAsString()) as Map<String, dynamic>;
      all.remove(sessionId);
      await sf.writeAsString(jsonEncode(all));
    }
    // remove messages file
    final mf = File(_msgFile(sessionId, base));
    if (await mf.exists()) await mf.delete();
  }

  /// 清空所有数据
  Future<void> clearAll() async {
    final base = await _dir;
    // delete all chat JSON files
    final dir = Directory(base);
    for (final f in await dir.list().toList()) {
      if (f.path.contains('chat_') || f.path.contains('hermes_sessions')) {
        await File(f.path).delete();
      }
    }
  }

  // helpers
  Future<Map<String, dynamic>> _loadMsgJson(File file) async {
    if (!await file.exists()) return {};
    try {
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (_) { return {}; }
  }

  Map<String, dynamic> _msgToJson(ChatMessage msg) => {
    'id': msg.id,
    'role': msg.role.name,
    'content': msg.content,
    'tool_name': msg.toolName,
    'timestamp': msg.timestamp.millisecondsSinceEpoch,
  };
}
