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
  final _lanUrlCtrl = TextEditingController();
  final _relayUrlCtrl = TextEditingController();
  final _relayKeyCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    _urlCtrl.text = prefs.getString('api_url') ?? '';
    _keyCtrl.text = prefs.getString('api_key') ?? '';
    _lanUrlCtrl.text = prefs.getString('lan_url') ?? '';
    _relayUrlCtrl.text = prefs.getString('relay_url') ?? '';
    _relayKeyCtrl.text = prefs.getString('relay_key') ?? '';
  }

  Future<void> _saveConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_url', _urlCtrl.text.trim());
    await prefs.setString('api_key', _keyCtrl.text.trim());
    await prefs.setString('lan_url', _lanUrlCtrl.text.trim());
    await prefs.setString('relay_url', _relayUrlCtrl.text.trim());
    await prefs.setString('relay_key', _relayKeyCtrl.text.trim());
    if (mounted) {
      ref.read(baseUrlProvider.notifier).state = _urlCtrl.text.trim();
      ref.read(apiProvider).setBaseUrl(_urlCtrl.text.trim(), apiKey: _keyCtrl.text.trim());
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose(); _keyCtrl.dispose();
    _lanUrlCtrl.dispose();
    _relayUrlCtrl.dispose(); _relayKeyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentThemeMode = ref.watch(themeModeProvider);
    return SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(margin: const EdgeInsets.only(top: 8, bottom: 4), width: 32, height: 4,
          decoration: BoxDecoration(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(2))),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('设置', style: theme.textTheme.titleLarge),
            IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(context)),
          ])),
        Flexible(child: ListView(shrinkWrap: true, children: [
          _section('Hermes 连接'),
          _field('局域网地址', ApiConfig.defaultLanUrl, _lanUrlCtrl),
          const SizedBox(height: 10),
          _field('远程地址', ApiConfig.defaultUrl, _urlCtrl),
          const SizedBox(height: 10),
          _field('API Key', 'hermes-api-key', _keyCtrl, obscure: true),
          const SizedBox(height: 4),
          _section('Relay 中继'),
          _field('Relay 地址', ApiConfig.defaultRelayUrl, _relayUrlCtrl),
          const SizedBox(height: 10),
          _field('Relay Key', 'relay-key', _relayKeyCtrl, obscure: true),
          const SizedBox(height: 4),
          Align(alignment: Alignment.centerRight,
            child: Padding(padding: const EdgeInsets.only(right: 16),
              child: FilledButton.tonalIcon(onPressed: _saveConfig, icon: const Icon(Icons.save, size: 16), label: const Text('保存并应用')))),
          const Divider(),
          _section('外观'),
          RadioListTile<ThemeMode>(title: const Text('跟随系统'), value: ThemeMode.system, groupValue: currentThemeMode, onChanged: (v) => _setTheme(v!)),
          RadioListTile<ThemeMode>(title: const Text('浅色模式'), value: ThemeMode.light, groupValue: currentThemeMode, onChanged: (v) => _setTheme(v!)),
          RadioListTile<ThemeMode>(title: const Text('深色模式'), value: ThemeMode.dark, groupValue: currentThemeMode, onChanged: (v) => _setTheme(v!)),
          const Divider(),
          _section('数据'),
          ListTile(title: const Text('清除缓存'), leading: const Icon(Icons.delete_outline), onTap: () async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.clear();
            if (mounted) Navigator.pop(context);
          }),
        ])),
      ]),
    );
  }

  Widget _section(String title) => Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text(title, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600)));

  Widget _field(String label, String hint, TextEditingController ctrl, {bool obscure = false}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: TextField(controller: ctrl, obscureText: obscure,
      decoration: InputDecoration(labelText: label, hintText: hint, isDense: true),
      style: const TextStyle(fontSize: 13)));

  void _setTheme(ThemeMode mode) => ref.read(themeModeProvider.notifier).state = mode;
}
