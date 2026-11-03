import 'dart:async';

import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _ch = MethodChannel('tw.eddie/adbwifi');
const _grantCmd = 'adb shell pm grant tw.eddie.wireless_debug_toggle android.permission.WRITE_SECURE_SETTINGS';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    const sub = FlexSubThemesData(
      cardRadius: 20,
      switchThumbSchemeColor: SchemeColor.onPrimary,
      snackBarBackgroundSchemeColor: SchemeColor.inverseSurface,
    );
    return MaterialApp(
      title: '無線偵錯',
      debugShowCheckedModeBanner: false,
      theme: FlexThemeData.light(scheme: FlexScheme.tealM3, subThemesData: sub),
      darkTheme: FlexThemeData.dark(scheme: FlexScheme.tealM3, subThemesData: sub, darkIsTrueBlack: false),
      themeMode: ThemeMode.system,
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  Map<Object?, Object?> _s = const {};
  Timer? _timer;
  bool _busy = false;
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();

  bool? get _enabled => _s['enabled'] as bool?;
  bool? get _devEnabled => _s['devEnabled'] as bool?;
  bool? get _usbEnabled => _s['usbEnabled'] as bool?;
  String? get _ssid => _s['ssid'] as String?;
  String? get _ip => _s['ip'] as String?;
  int? get _port => _s['port'] as int?;
  bool get _canWrite => _s['canWrite'] == true;
  bool get _hasLocation => _s['hasLocation'] == true;
  bool get _locationOn => _s['locationOn'] == true;
  bool get _notifyOn => _s['notifyOn'] == true;
  bool get _notifyAllowed => _s['notifyAllowed'] == true;
  String? get _version => _s['version'] as String?;
  int? get _updateProgress => _s['updateProgress'] as int?;

  // 雲端更新：有新版時為 {version, notes}
  Map<Object?, Object?>? _update;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
    // 第一次開啟時順便要位置權限（讀 SSID 用）
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _refresh();
      if (!_hasLocation) await _ch.invokeMethod('requestLocation');
      _checkUpdate(silent: true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _start();
    } else if (state == AppLifecycleState.paused) {
      _timer?.cancel();
    }
  }

  void _start() {
    _timer?.cancel();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final s = await _ch.invokeMethod<Map<Object?, Object?>>('getStatus');
    if (mounted && s != null) setState(() => _s = s);
  }

  Future<void> _set(String method, bool on) async {
    HapticFeedback.mediumImpact();
    setState(() => _busy = true);
    try {
      await _ch.invokeMethod(method, {'on': on});
    } on PlatformException catch (e) {
      _toast(e.code == 'NO_PERMISSION' ? '尚未授權，請先用電腦執行授權指令' : '失敗：${e.message}');
    } finally {
      await _refresh();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkUpdate({bool silent = false}) async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>('checkUpdate');
      if (!mounted) return;
      if (r != null && r['error'] != null) {
        if (!silent) _toast('檢查更新失敗：${r['error']}');
      } else {
        setState(() => _update = r);
        if (!silent && r == null) _toast('已是最新版本');
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _startUpdate() async {
    final r = await _ch.invokeMethod<String>('startUpdate');
    switch (r) {
      case 'need_permission':
        _toast('請允許「安裝未知應用程式」，返回後再按一次更新');
      case 'no_update':
        _toast('目前沒有可用的更新');
    }
    await _refresh();
  }

  void _copy(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.selectionClick();
    _toast('已複製$label');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  @override
  Widget build(BuildContext context) {
    final on = _enabled == true;
    final addr = (on && _ip != null && _port != null) ? '$_ip:$_port' : null;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            _header(),
            if (_update != null) _updateCard(),
            if (_s.isNotEmpty && !_canWrite) _permissionCard(),
            const SizedBox(height: 12),
            Center(child: _powerButton(on)),
            const SizedBox(height: 16),
            _stateLabel(on),
            const SizedBox(height: 28),
            _infoCard(on),
            if (addr != null) ...[
              const SizedBox(height: 12),
              _commandCard(addr),
            ],
            const SizedBox(height: 12),
            _devCard(),
            const SizedBox(height: 12),
            _shortcutCard(),
            const SizedBox(height: 16),
            _versionFooter(),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final t = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('無線偵錯', style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
              Text('Wireless Debugging', style: t.bodySmall?.copyWith(letterSpacing: 1.2)),
            ],
          ),
        ),
        IconButton.filledTonal(
          tooltip: '重新掃描 Port',
          icon: const Icon(Icons.refresh_rounded),
          onPressed: () {
            HapticFeedback.selectionClick();
            _ch.invokeMethod('restartScan');
          },
        ),
      ],
    );
  }

  Widget _powerButton(bool on) {
    final cs = Theme.of(context).colorScheme;
    final enabled = _canWrite && !_busy && _enabled != null;
    const size = 168.0;

    return SizedBox(
      width: size * 1.45,
      height: size * 1.45,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 開啟時的擴散光圈
          if (on)
            AnimatedBuilder(
              animation: _pulse,
              builder: (_, _) {
                final v = Curves.easeOut.transform(_pulse.value);
                return Container(
                  width: size * (1 + 0.45 * v),
                  height: size * (1 + 0.45 * v),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: cs.primary.withValues(alpha: 0.35 * (1 - v)),
                  ),
                );
              },
            ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: on
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [cs.primary, Color.lerp(cs.primary, Colors.black, 0.35)!],
                    )
                  : null,
              color: on ? null : cs.surfaceContainerHighest,
              boxShadow: [
                BoxShadow(
                  color: (on ? cs.primary : Colors.black).withValues(alpha: on ? 0.45 : 0.15),
                  blurRadius: on ? 32 : 12,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Material(
              type: MaterialType.transparency,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: enabled ? () => _set('setEnabled', !on) : null,
                child: Center(
                  child: _busy
                      ? SizedBox(
                          width: 48,
                          height: 48,
                          child: CircularProgressIndicator(
                            strokeWidth: 4,
                            color: on ? cs.onPrimary : cs.primary,
                          ),
                        )
                      : Icon(
                          on ? Icons.wifi_tethering_rounded : Icons.wifi_tethering_off_rounded,
                          size: 72,
                          color: on ? cs.onPrimary : cs.onSurfaceVariant,
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stateLabel(bool on) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final text = switch (_enabled) {
      true => '已開啟',
      false => '已關閉',
      null => '讀取中…',
    };
    return Column(
      children: [
        AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 250),
          style: t.headlineSmall!.copyWith(
            fontWeight: FontWeight.w700,
            color: on ? cs.primary : cs.onSurfaceVariant,
          ),
          child: Text(text),
        ),
        const SizedBox(height: 4),
        Text(_canWrite ? '點一下圓形按鈕切換' : '授權後即可切換', style: t.bodySmall),
      ],
    );
  }

  Widget _infoCard(bool on) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            _InfoRow(icon: Icons.wifi_rounded, label: 'Wi-Fi', value: _ssidText()),
            _InfoRow(icon: Icons.lan_rounded, label: 'IP 位址', value: _ip ?? '未連線 Wi-Fi'),
            _InfoRow(
              icon: Icons.tag_rounded,
              label: 'Port',
              value: !on ? '—' : (_port?.toString() ?? '搜尋中…'),
              mono: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _commandCard(String addr) {
    final cs = Theme.of(context).colorScheme;
    final cmd = 'adb connect $addr';
    return Card(
      color: cs.primaryContainer,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _copy(cmd, '連線指令'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('電腦連線指令',
                        style: TextStyle(color: cs.onPrimaryContainer, fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text(
                      cmd,
                      style: TextStyle(
                        color: cs.onPrimaryContainer,
                        fontFamily: 'monospace',
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.content_copy_rounded, color: cs.onPrimaryContainer),
            ],
          ),
        ),
      ),
    );
  }

  Widget _devCard() {
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            secondary: const Icon(Icons.developer_mode_rounded),
            title: const Text('開發者模式', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(switch (_devEnabled) {
              true => '已開啟',
              false => '已關閉（無線偵錯會一併關閉）',
              null => '讀取中…',
            }),
            value: _devEnabled == true,
            onChanged: _busy || !_canWrite ? null : (v) => _set('setDevEnabled', v),
          ),
          const Divider(height: 1, indent: 20, endIndent: 20),
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            secondary: const Icon(Icons.wifi_tethering_rounded),
            title: const Text('無線偵錯', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(switch (_enabled) {
              true => '已開啟',
              false => '已關閉',
              null => '讀取中…',
            }),
            value: _enabled == true,
            onChanged: _busy || !_canWrite ? null : (v) => _set('setEnabled', v),
          ),
          const Divider(height: 1, indent: 20, endIndent: 20),
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            secondary: const Icon(Icons.usb_rounded),
            title: const Text('USB 偵錯', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(switch (_usbEnabled) {
              true => '已開啟',
              false => '已關閉',
              null => '讀取中…',
            }),
            value: _usbEnabled == true,
            onChanged: _busy || !_canWrite ? null : (v) => _set('setUsbEnabled', v),
          ),
        ],
      ),
    );
  }

  Widget _updateCard() {
    final cs = Theme.of(context).colorScheme;
    final progress = _updateProgress;
    final notes = (_update!['notes'] as String? ?? '').trim();
    return Card(
      color: cs.tertiaryContainer,
      margin: const EdgeInsets.only(top: 16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.system_update_rounded, color: cs.onTertiaryContainer),
                const SizedBox(width: 8),
                Text('有新版本 v${_update!['version']}',
                    style: TextStyle(color: cs.onTertiaryContainer, fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(notes, maxLines: 6, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onTertiaryContainer)),
            ],
            const SizedBox(height: 12),
            if (progress != null) ...[
              LinearProgressIndicator(value: progress / 100, borderRadius: BorderRadius.circular(4)),
              const SizedBox(height: 6),
              Text('下載中 $progress%', style: TextStyle(color: cs.onTertiaryContainer)),
            ] else
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('下載並更新'),
                  onPressed: _startUpdate,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _versionFooter() {
    final t = Theme.of(context).textTheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('版本 v${_version ?? '…'}', style: t.bodySmall),
        const SizedBox(width: 4),
        TextButton(
          onPressed: _checking ? null : () => _checkUpdate(),
          child: Text(_checking ? '檢查中…' : '檢查更新'),
        ),
      ],
    );
  }

  Widget _shortcutCard() {
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            secondary: const Icon(Icons.notifications_active_rounded),
            title: const Text('常駐通知', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              _notifyOn && !_notifyAllowed ? '通知權限未開啟，請到系統設定允許' : '狀態列顯示圖示與 IP:Port，可直接開關',
            ),
            value: _notifyOn,
            onChanged: (v) async {
              HapticFeedback.selectionClick();
              await _ch.invokeMethod('setNotify', {'on': v});
              await _refresh();
            },
          ),
          const Divider(height: 1, indent: 20, endIndent: 20),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            leading: const Icon(Icons.dashboard_customize_rounded),
            title: const Text('加入控制中心快捷磚', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('下拉控制中心一鍵開關，長按開啟本 App'),
            trailing: const Icon(Icons.add_circle_outline_rounded),
            onTap: () async {
              final r = await _ch.invokeMethod<String>('addTile');
              _toast(switch (r) {
                'added' => '已加入控制中心',
                'already' => '已經在控制中心裡了',
                'declined' => '已取消',
                _ => '此系統不支援自動加入，請下拉控制中心 → 編輯，手動加入「無線偵錯」',
              });
            },
          ),
        ],
      ),
    );
  }

  String _ssidText() {
    if (_ip == null) return '未連線 Wi-Fi';
    if (_ssid != null) return _ssid!;
    if (!_hasLocation) return '需要位置權限';
    if (!_locationOn) return '請開啟定位';
    return '讀取中…';
  }

  Widget _permissionCard() {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.errorContainer,
      margin: const EdgeInsets.only(top: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lock_outline_rounded, color: cs.onErrorContainer),
                const SizedBox(width: 8),
                Text('尚未授權切換開關',
                    style: TextStyle(color: cs.onErrorContainer, fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
            const SizedBox(height: 8),
            Text('請在電腦上執行一次（需先開啟「USB 偵錯（安全設定）」）：', style: TextStyle(color: cs.onErrorContainer)),
            const SizedBox(height: 8),
            SelectableText(_grantCmd,
                style: TextStyle(color: cs.onErrorContainer, fontFamily: 'monospace', fontSize: 12)),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.content_copy_rounded),
                label: const Text('複製指令'),
                onPressed: () => _copy(_grantCmd, '授權指令'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.label, required this.value, this.mono = false});

  final IconData icon;
  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(14)),
            child: Icon(icon, color: cs.onSecondaryContainer),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: t.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: t.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFamily: mono ? 'monospace' : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
