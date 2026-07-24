import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app.dart';
import '../config/api_config.dart';
import '../providers/chat_provider.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _urlCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    _urlCtrl.text = prefs.getString('api_url') ?? 'http://YOUR_SERVER_IP/hermes/v1';
    _keyCtrl.text = prefs.getString('api_key') ?? 'YOUR_API_KEY';
  }

  Future<void> _saveConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_url', _urlCtrl.text.trim());
    await prefs.setString('api_key', _keyCtrl.text.trim());
    if (mounted) {
      ref.read(baseUrlProvider.notifier).state = _urlCtrl.text.trim();
      ref.read(apiProvider).setBaseUrl(_urlCtrl.text.trim());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('配置已保存，下次启动生效')),
      );
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentThemeMode = ref.watch(themeModeProvider);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              width: 32, height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('设置', style: theme.textTheme.titleLarge),
                IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(context)),
              ],
            ),
          ),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              _section('连接配置'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _urlCtrl,
                  decoration: const InputDecoration(labelText: 'API 地址', hintText: 'http://host:port/hermes/v1', isDense: true),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _keyCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'API Key', isDense: true),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: FilledButton.tonalIcon(
                    onPressed: _saveConfig,
                    icon: const Icon(Icons.save, size: 16),
                    label: const Text('保存并应用'),
                  ),
                ),
              ),
              const Divider(),
              _section('外观'),
              RadioListTile<ThemeMode>(title: const Text('跟随系统'), value: ThemeMode.system, groupValue: currentThemeMode, onChanged: (v) => _setTheme(v!)),
              RadioListTile<ThemeMode>(title: const Text('浅色模式'), value: ThemeMode.light, groupValue: currentThemeMode, onChanged: (v) => _setTheme(v!)),
              RadioListTile<ThemeMode>(title: const Text('深色模式'), value: ThemeMode.dark, groupValue: currentThemeMode, onChanged: (v) => _setTheme(v!)),
              const Divider(),
              _section('数据'),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('清除当前对话'),
                subtitle: const Text('不删除服务器上的会话'),
                onTap: () {
                  ref.read(messagesProvider.notifier).clear();
                  ref.read(sessionIdProvider.notifier).state = null;
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已清除')));
                },
              ),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.primary, letterSpacing: 0.5)),
    );
  }

  Future<void> _setTheme(ThemeMode mode) async {
    ref.read(themeModeProvider.notifier).state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', mode.name);
  }
}
