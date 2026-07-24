import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../services/connection_manager.dart';
import '../config/api_config.dart';
import '../models/chat_message.dart';
import '../providers/chat_provider.dart';
import '../providers/session_provider.dart';
import 'session_list_screen.dart';
import 'settings_screen.dart';
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  bool _initialSyncDone = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _probeChannel();
    _rttTimer = Timer.periodic(const Duration(seconds: 120), (_) => _refreshRtt());
  }

  Timer? _rttTimer;

  Future<void> _probeChannel() async {
    // 先加载本地保存的配置
    final saved = await ApiConfig.load();
    ref.read(apiProvider).setBaseUrl(saved.baseUrl);

    final mgr = ref.read(connectionManagerProvider);
    mgr.setState(GatewayState.connecting);
    ref.read(connectionStateProvider.notifier).state = GatewayState.connecting;
    mgr.setOnReconnect(() => _probeChannel());

    try {
      final stopwatch = Stopwatch()..start();
      final best = await ApiConfig.probe(preferUrl: saved.baseUrl);
      final rtt = stopwatch.elapsedMilliseconds;
      _lastProbeTime = DateTime.now();

      if (mounted) {
        final root = best.replaceAll('/v1', '');
        ref.read(baseUrlProvider.notifier).state = root;
        ref.read(apiProvider).setBaseUrl(best, apiKey: saved.apiKey);
        ref.read(connectionStatsProvider.notifier).state = {'rtt': rtt, 'loss': ''};
      }

      mgr.setState(GatewayState.open);
      ref.read(connectionStateProvider.notifier).state = GatewayState.open;

      ref.read(messagesProvider.notifier).tryFlushPending(ref);
      final lastSid = ref.read(sessionIdProvider);
      final msgs = ref.read(messagesProvider);
      if (lastSid != null && msgs.isEmpty) {
        await ref.read(messagesProvider.notifier).loadSession(lastSid, ref: ref);
        _scrollToBottom();
      }

      _measureLoss(best);
    } catch (_) {
      mgr.setState(GatewayState.error);
      ref.read(connectionStateProvider.notifier).state = GatewayState.error;
    }
  }

  DateTime _lastProbeTime = DateTime.now();

  void _maybeRefreshRtt() {
    if (DateTime.now().difference(_lastProbeTime).inSeconds > 30) {
      _refreshRtt();
    }
  }

  Future<void> _refreshRtt() async {
    final baseUrl = ref.read(baseUrlProvider);
    if (baseUrl.isEmpty) return;
    final stopwatch = Stopwatch()..start();
    int ok = 0;
    final healthUrl = baseUrl.replaceAll('/v1', '') + '/health';
    final futures = List.generate(3, (_) async {
      try {
        final c = HttpClient()..connectionTimeout = const Duration(seconds: 2);
        final r = await c.getUrl(Uri.parse(healthUrl));
        r.headers.set('Authorization', 'Bearer ${ref.read(apiProvider).config.apiKey}');
        final resp = await r.close().timeout(const Duration(seconds: 2));
        c.close();
        return resp.statusCode == 200;
      } catch (_) { return false; }
    });
    for (final f in futures) { if (await f) ok++; }
    if (mounted) {
      final rtt = stopwatch.elapsedMilliseconds ~/ 3;
      final loss = ok < 3 ? '${((3 - ok) / 3 * 100).round()}' : '';
      ref.read(connectionStatsProvider.notifier).state = {'rtt': rtt, 'loss': loss};
      _lastProbeTime = DateTime.now();
    }
  }

  Future<void> _measureLoss(String url) async {
    final root = url.replaceAll('/v1', '');
    int ok = 0;
    // 串行测试，避免移动网络并发连接冲突
    for (int i = 0; i < 3; i++) {
      try {
        final c = HttpClient()..connectionTimeout = const Duration(seconds: 3);
        final req = await c.getUrl(Uri.parse('$root/health'));
        final resp = await req.close().timeout(const Duration(seconds: 3));
        c.close();
        if (resp.statusCode == 200) ok++;
      } catch (_) {}
    }
    if (mounted) {
      final loss = ok < 3 ? '${((3 - ok) / 3 * 100).round()}' : '';
      final prev = ref.read(connectionStatsProvider);
      ref.read(connectionStatsProvider.notifier).state = {'rtt': prev['rtt'], 'loss': loss};
    }
  }

  Widget _buildTitleWithStatus() {
    final baseUrl = ref.watch(baseUrlProvider);
    final connState = ref.watch(connectionStateProvider);
    final stats = ref.watch(connectionStatsProvider);
    final rtt = stats['rtt'] as int? ?? 0;
    String label; Color color;
    switch (connState) {
      case GatewayState.connecting: label = '连接中...'; color = const Color(0xFFFF9800);
      case GatewayState.open:
        if (baseUrl.contains('192.168')) { label = 'LAN ${rtt}ms'; color = const Color(0xFF2196F3); }
        else { label = '☁${rtt}ms'; color = const Color(0xFF9E9E9E); }
        break;
      case GatewayState.closed:
      case GatewayState.error: label = '已断线'; color = const Color(0xFFFF3333); break;
      case GatewayState.idle: label = '待连接'; color = const Color(0xFF9E9E9E); break;
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      const Text('Hermes', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
      const SizedBox(width: 8),
      Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 4),
      Text(label, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
    ]);
  }

  void _onScroll() {
    if (_scrollController.hasClients && _scrollController.position.pixels <= 50) {
      if (ref.read(hasMoreProvider)) {
        ref.read(messagesProvider.notifier).loadMore(ref);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _rttTimer?.cancel();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    final sessionId = ref.read(sessionIdProvider);
    ref.read(messagesProvider.notifier).sendMessage(
      text,
      sessionId: sessionId,
      ref: ref,
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// 手动刷新
  Future<void> _refresh() async {
    final sessionId = ref.read(sessionIdProvider);
    if (sessionId != null) {
      await ref.read(messagesProvider.notifier).syncFromServer();
      _scrollToBottom();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 监听配置变更（Settings保存后递增版本号，触发重新探测）
    ref.listen(configVersionProvider, (prev, next) {
      if (prev != null && next > prev) {
        _probeChannel();
      }
    });

    final messages = ref.watch(messagesProvider);
    final isGenerating = ref.watch(isGeneratingProvider);
    final sessionId = ref.watch(sessionIdProvider);
    final theme = Theme.of(context);

    // 不自动加载 —— 用户自行点击历史选择会话
    if (!_initialSyncDone) {
      _initialSyncDone = true;
      // 仅同步最新消息计数，不加载内容
    }

    // 最后一条消息变化 = 新消息到达 → 滚到底部
    ref.listen(messagesProvider, (prev, next) {
      if (next.isNotEmpty && (prev == null || prev.isEmpty || prev.last.id != next.last.id)) {
        _scrollToBottom();
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hermes', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        actions: [
          _buildMenu(),
        ],
      ),
      floatingActionButton: FloatingActionButton.small(
        onPressed: _newSession,
        tooltip: '新对话',
        child: const Icon(Icons.edit_note),
      ),
      body: Column(
        children: [
          // 主消息区 — 支持下拉刷新
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: messages.isEmpty
                  ? ListView(
                      children: [
                        SizedBox(height: MediaQuery.of(context).size.height * 0.3),
                        _buildEmptyState(theme),
                      ],
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        return _SlideInMessage(
                          key: ValueKey(messages[index].id),
                          index: index,
                          child: ChatBubble(message: messages[index]),
                        );
                      },
                    ),
            ),
          ),

          // 生成中 — 工具调用状态 + 停止按钮
          if (isGenerating)
            _GeneratingBar(
              onStop: () {
                // 停止生成：关闭流 + 标记完成
                final msgs = ref.read(messagesProvider);
                if (msgs.isNotEmpty) {
                  final lastIdx = msgs.length - 1;
                  ref.read(messagesProvider.notifier).state = [
                    ...msgs.sublist(0, lastIdx),
                    msgs[lastIdx].copyWith(isStreaming: false),
                  ];
                }
                ref.read(isGeneratingProvider.notifier).state = false;
              },
            ),

          // 输入框
          _buildInputBar(theme),
        ],
      ),
      backgroundColor: theme.colorScheme.surface,
    );
  }

  void _newSession() {
    ref.read(sessionIdProvider.notifier).state = null;
    ref.read(messagesProvider.notifier).clear();
  }

  Widget _buildMenu() {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      tooltip: '菜单',
      onSelected: (v) {
        switch (v) {
          case 'questions': _showSessionQuestions();
          case 'refresh': _refresh();
          case 'history': Navigator.push(context, MaterialPageRoute(builder: (_) => const SessionListScreen()));
          case 'settings': showModalBottomSheet(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => const SettingsScreen());
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem<String>(enabled: false, child: Consumer(builder: (_, ref, __) {
          ref.watch(connectionStatsProvider);
          ref.watch(connectionStateProvider);
          final stats = ref.read(connectionStatsProvider);
          final rtt = stats['rtt'] as int? ?? 0;
          final loss = stats['loss'] as String? ?? '';
          final connState = ref.read(connectionStateProvider);
          final dot = connState == GatewayState.open ? '🟢' : connState == GatewayState.connecting ? '🟠' : '🔴';
          final stateText = connState == GatewayState.open ? '在线' : connState == GatewayState.connecting ? '连接中' : '离线';
          return Container(
            width: 200,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$dot $stateText', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              if (rtt > 0) Text('延迟 ${rtt}ms', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6))),
              if (loss.isNotEmpty) Text('丢包 ${loss}%', style: const TextStyle(fontSize: 12, color: Color(0xFFFF3333))),
              const Divider(height: 12),
            ]),
          );
        })),
        const PopupMenuItem(value: 'questions', child: ListTile(leading: Icon(Icons.list_alt, size: 20), title: Text('当前会话'), dense: true)),
        const PopupMenuItem(value: 'refresh',  child: ListTile(leading: Icon(Icons.refresh, size: 20), title: Text('同步'), dense: true)),
        const PopupMenuItem(value: 'history',  child: ListTile(leading: Icon(Icons.history, size: 20), title: Text('会话历史'), dense: true)),
        const PopupMenuItem(value: 'settings', child: ListTile(leading: Icon(Icons.settings, size: 20), title: Text('设置'), dense: true)),
      ],
    );
  }

  void _showSessionQuestions() {
    final messages = ref.read(messagesProvider);
    final questions = <Map<String, dynamic>>[];
    for (int i = 0; i < messages.length; i++) {
      if (messages[i].role == MessageRole.user) {
        questions.add({'index': i, 'content': messages[i].content});
      }
    }
    if (questions.isEmpty) return;
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.all(16), child: Row(children: [
            Text('当前会话 (${questions.length}个问题)', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(context)),
          ])),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: questions.length,
              itemBuilder: (_, i) => ListTile(
                dense: true,
                leading: Text('${i + 1}', style: TextStyle(color: Theme.of(context).colorScheme.primary)),
                title: Text(questions[i]['content'], maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                onTap: () {
                  Navigator.pop(context);
                  final idx = questions[i]['index'] as int;
                  _scrollController.animateTo(idx * 80.0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
                },
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.auto_awesome, size: 48, color: theme.colorScheme.primary.withValues(alpha: 0.3)),
          const SizedBox(height: 12),
          Text('下拉同步电脑端会话', style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }

  Widget _buildInputBar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(hintText: '输入消息...'),
              ),
            ),
            const SizedBox(width: 8),
            _AnimatedSendButton(onSend: _send),
          ],
        ),
      ),
    );
  }

  void _showSessionPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: const SessionListScreen(),
      ),
    );
  }
}

/// 聊天气泡 — 用户方框，AI 无框透明，工具自动折叠
class ChatBubble extends StatelessWidget {
  final ChatMessage message;
  const ChatBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == MessageRole.user;
    final isTool = message.role == MessageRole.tool;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: _bubbleContent(theme, isUser, isTool),
          ),
        ],
      ),
    );
  }

  Widget _bubbleContent(ThemeData theme, bool isUser, bool isTool) {
    if (isTool) return _ToolBubble(theme: theme, content: message.content, toolName: message.toolName ?? '', isStreaming: message.isStreaming);

    if (isUser) return _UserBubble(theme: theme, content: message.content);

    // AI 消息：无框透明
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: message.isStreaming
          ? SelectableText(message.content, style: TextStyle(fontSize: 15, height: 1.6, color: theme.colorScheme.onSurface))
          : MarkdownBody(
              data: message.content,
              selectable: true,
              styleSheet: MarkdownStyleSheet(
                p: TextStyle(fontSize: 15, height: 1.6, color: theme.colorScheme.onSurface),
                code: TextStyle(fontSize: 13, fontFamily: 'monospace', backgroundColor: theme.colorScheme.surfaceContainerHighest, color: theme.colorScheme.primary),
                codeblockDecoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
                h1: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface),
                h2: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface),
                h3: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface),
              ),
            ),
    );
  }
}

/// 用户消息 — 方框，灰色边框
class _UserBubble extends StatelessWidget {
  final ThemeData theme;
  final String content;
  const _UserBubble({required this.theme, required this.content});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: SelectableText(content, style: TextStyle(fontSize: 15, height: 1.5, color: theme.colorScheme.onSurface)),
    );
  }
}

/// 工具调用 — 透明底，仅一条细线分隔，默认折叠
class _ToolBubble extends StatefulWidget {
  final ThemeData theme;
  final String content;
  final String toolName;
  final bool isStreaming;
  const _ToolBubble({required this.theme, required this.content, required this.toolName, required this.isStreaming});

  @override
  State<_ToolBubble> createState() => _ToolBubbleState();
}

class _ToolBubbleState extends State<_ToolBubble> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final show = widget.isStreaming || _expanded;
    final text = widget.content;
    final short = text.length > 60 ? '${text.substring(0, 60)}...' : text;

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: t.colorScheme.outline.withValues(alpha: 0.2), width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: widget.isStreaming ? null : () => setState(() => _expanded = !_expanded),
            child: Row(
              children: [
                Icon(Icons.terminal, size: 12, color: t.colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(widget.toolName, style: TextStyle(fontSize: 12, color: t.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w500)),
                if (!widget.isStreaming) ...[
                  const Spacer(),
                  Icon(_expanded ? Icons.unfold_less : Icons.unfold_more, size: 14, color: t.colorScheme.onSurfaceVariant),
                ],
              ],
            ),
          ),
          if (show)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 18),
              child: SelectableText(show && !widget.isStreaming ? text : short, style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: t.colorScheme.onSurfaceVariant, height: 1.4)),
            ),
        ],
      ),
    );
  }
}

/// 消息滑入动画
class _SlideInMessage extends StatefulWidget {
  final Widget child;
  final int index;
  const _SlideInMessage({super.key, required this.child, required this.index});

  @override
  State<_SlideInMessage> createState() => _SlideInMessageState();
}

class _SlideInMessageState extends State<_SlideInMessage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _slide;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _slide = Tween<double>(begin: 30, end: 0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic),
    );
    _fade = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) => Opacity(
        opacity: _fade.value,
        child: Transform.translate(
          offset: Offset(0, _slide.value),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

/// 发送按钮 — 点击缩放反馈
class _AnimatedSendButton extends StatefulWidget {
  final VoidCallback onSend;
  const _AnimatedSendButton({required this.onSend});

  @override
  State<_AnimatedSendButton> createState() => _AnimatedSendButtonState();
}

class _AnimatedSendButtonState extends State<_AnimatedSendButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _scale = Tween<double>(begin: 1, end: 0.85).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onTap() {
    _ctrl.forward().then((_) => _ctrl.reverse());
    widget.onSend();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ScaleTransition(
      scale: _scale,
      child: Material(
        color: theme.colorScheme.primary,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: _onTap,
          customBorder: const CircleBorder(),
          child: const Padding(
            padding: EdgeInsets.all(10),
            child: Icon(Icons.send_rounded, color: Colors.white, size: 20),
          ),
        ),
      ),
    );
  }
}

/// 同步图标 — 持续旋转
class _RotatingSyncIcon extends StatefulWidget {
  const _RotatingSyncIcon();

  @override
  State<_RotatingSyncIcon> createState() => _RotatingSyncIconState();
}

class _RotatingSyncIconState extends State<_RotatingSyncIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _ctrl,
      child: const Icon(Icons.sync, size: 12, color: Color(0xFF00BB7F)),
    );
  }
}


/// 生成中状态栏 — 波浪动画 + 停止按钮
class _GeneratingBar extends StatefulWidget {
  final VoidCallback onStop;
  const _GeneratingBar({required this.onStop});

  @override
  State<_GeneratingBar> createState() => _GeneratingBarState();
}

class _GeneratingBarState extends State<_GeneratingBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.primary.withValues(alpha: 0.08),
            theme.colorScheme.primary.withValues(alpha: 0.03),
          ],
        ),
      ),
      child: Row(
        children: [
          _WaveDot(controller: _pulse, delay: 0, color: theme.colorScheme.primary),
          const SizedBox(width: 4),
          _WaveDot(controller: _pulse, delay: 0.2, color: theme.colorScheme.primary),
          const SizedBox(width: 4),
          _WaveDot(controller: _pulse, delay: 0.4, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Text(
            'Hermes 正在工作中...',
            style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
          ),
          const Spacer(),
          SizedBox(
            height: 28,
            child: OutlinedButton.icon(
              onPressed: widget.onStop,
              icon: const Icon(Icons.stop, size: 14),
              label: const Text('停止', style: TextStyle(fontSize: 11)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                side: BorderSide(color: theme.colorScheme.error.withValues(alpha: 0.5)),
                foregroundColor: theme.colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 波浪小圆点
class _WaveDot extends StatelessWidget {
  final AnimationController controller;
  final double delay;
  final Color color;

  const _WaveDot({
    required this.controller,
    required this.delay,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final t = (controller.value + delay) % 1.0;
        final scale = 0.5 + 0.5 * (t < 0.5 ? t * 2 : (1 - t) * 2);
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 6, height: 6,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.3 + scale * 0.5),
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }
}


/// 工具调用卡片 — 默认折叠，点击展开，橙色系配黑色字
