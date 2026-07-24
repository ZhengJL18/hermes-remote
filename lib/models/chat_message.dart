/// 聊天消息模型
enum MessageRole { user, assistant, tool, system }

class ChatMessage {
  final String id;
  final MessageRole role;
  final String content;
  final DateTime timestamp;
  final String? toolName;   // tool call 时的工具名
  final bool isStreaming;   // 是否正在流式输出中
  final String? sessionId;

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.toolName,
    this.isStreaming = false,
    this.sessionId,
  }) : timestamp = timestamp ?? DateTime.now();

  ChatMessage copyWith({
    String? content,
    bool? isStreaming,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      content: content ?? this.content,
      timestamp: timestamp,
      toolName: toolName,
      isStreaming: isStreaming ?? this.isStreaming,
      sessionId: sessionId,
    );
  }

  factory ChatMessage.user(String text, {String? sessionId}) {
    return ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: MessageRole.user,
      content: text,
      sessionId: sessionId,
    );
  }

  factory ChatMessage.assistant(String text, {String? sessionId}) {
    return ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: MessageRole.assistant,
      content: text,
      isStreaming: true,
      sessionId: sessionId,
    );
  }

  factory ChatMessage.tool(String name, String content, {String? sessionId}) {
    return ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: MessageRole.tool,
      content: content,
      toolName: name,
      sessionId: sessionId,
    );
  }
}
