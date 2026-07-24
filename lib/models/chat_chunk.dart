/// SSE chunk 模型 (OpenAI 格式)
class ChatChunk {
  final String? content;
  final String? finishReason;
  final String? toolCallName;
  final String? toolCallArgs;
  final int? promptTokens;
  final int? completionTokens;

  ChatChunk({
    this.content,
    this.finishReason,
    this.toolCallName,
    this.toolCallArgs,
    this.promptTokens,
    this.completionTokens,
  });

  factory ChatChunk.fromJson(Map<String, dynamic> json) {
    final choices = json['choices'] as List?;
    if (choices == null || choices.isEmpty) return ChatChunk();

    final choice = choices[0] as Map<String, dynamic>;
    final delta = choice['delta'] as Map<String, dynamic>? ?? {};

    // 解析 tool_calls
    String? toolName;
    String? toolArgs;
    final toolCalls = delta['tool_calls'] as List?;
    if (toolCalls != null && toolCalls.isNotEmpty) {
      final tc = toolCalls[0] as Map<String, dynamic>;
      final func = tc['function'] as Map<String, dynamic>?;
      toolName = func?['name'] as String?;
      toolArgs = func?['arguments'] as String?;
    }

    // token 用量
    final usage = json['usage'] as Map<String, dynamic>?;

    return ChatChunk(
      content: delta['content'] as String?,
      finishReason: choice['finish_reason'] as String?,
      toolCallName: toolName,
      toolCallArgs: toolArgs,
      promptTokens: usage?['prompt_tokens'] as int?,
      completionTokens: usage?['completion_tokens'] as int?,
    );
  }
}
