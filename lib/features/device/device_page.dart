import 'package:neurox/l10n/app_language.dart';
import 'package:flutter/material.dart';
import 'device_quality_assessment.dart';
import 'acquisition_dashboard.dart';
import 'eeg_controller.dart';

class DevicePage extends StatefulWidget {
  const DevicePage({
    super.key,
    required this.controller,
    this.ownsController = true,
    this.overview = false,
    this.diagnostic = false,
    this.assessment,
  });
  final EegController controller;
  final bool ownsController;
  final bool overview;
  final bool diagnostic;
  final DeviceQualityAssessment? assessment;
  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage>
    with WidgetsBindingObserver, LanguageAware<DevicePage> {
  EegController get c => widget.controller;
  late final DeviceQualityAssessment quality;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    quality = widget.assessment ?? DeviceQualityAssessment(c);
    c.initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) c.refreshAccess();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.assessment == null) quality.dispose();
    if (widget.ownsController) c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([c, quality]),
    builder: (context, _) {
      return Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              Icon(Icons.graphic_eq_rounded, size: 27),
              SizedBox(width: 10),
              Flexible(
                child: Text(
                  widget.overview
                      ? tr("设备")
                      : widget.diagnostic
                      ? tr("采集诊断")
                      : 'NeuroX',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.8,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            if (c.previewMode)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: _Badge(label: tr('模拟预览'), color: Colors.deepOrange),
              ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: 1100),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!widget.diagnostic) ...[
                        Text(
                          tr('连接你的脑电设备'),
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 20),
                        if (c.canPreview || c.pythonBridge) ...[
                          _browserMode(context),
                          const SizedBox(height: 16),
                        ],
                        _connection(context),
                        const SizedBox(height: 20),
                        if (!c.connected && !c.connecting) ...[
                          _devices(context),
                          const SizedBox(height: 20),
                        ],
                      ],
                      if (c.error != null) ...[
                        _error(context),
                        const SizedBox(height: 16),
                      ],
                      if (widget.overview)
                        OutlinedButton.icon(
                          onPressed: c.connected
                              ? () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => DevicePage(
                                      controller: c,
                                      ownsController: false,
                                      diagnostic: true,
                                      assessment: quality,
                                    ),
                                  ),
                                )
                              : null,
                          icon: const Icon(Icons.fact_check_outlined),
                          label: Text(tr('采集诊断')),
                        ),
                      if (!widget.overview) ...[
                        AcquisitionDashboard(controller: c),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _browserMode(BuildContext context) {
    final color = c.previewMode
        ? Colors.deepOrange
        : Theme.of(context).colorScheme.primary;
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        border: Border.all(color: color.withValues(alpha: .25)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            c.pythonBridge
                ? tr("Python 蓝牙桥接 · 真实设备数据")
                : c.previewMode
                ? tr("模拟预览 · 非真实设备数据")
                : tr("电脑蓝牙 · 真实设备连接"),
            style: TextStyle(color: color, fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 8),
          if (!c.pythonBridge)
            TextButton.icon(
              key: Key('switchPreview'),
              onPressed: c.busy ? null : c.switchPreview,
              icon: Icon(
                c.previewMode
                    ? Icons.bluetooth_connected
                    : Icons.play_circle_outline,
                size: 18,
              ),
              label: Text(c.previewMode ? tr("切换真实设备") : tr("查看模拟效果")),
            ),
        ],
      ),
    );
  }

  Widget _connection(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final active =
        c.receiving &&
        quality.state == DeviceQualityState.passed &&
        c.notificationHealth('raw') == NotificationHealth.normal;
    final title = c.connecting
        ? tr('正在建立连接')
        : !c.connected
        ? (c.supported ? tr('准备连接') : tr('蓝牙暂不可用'))
        : c.notificationHealth('raw') == NotificationHealth.invalid
        ? tr('数据解析异常')
        : c.stale || c.waitingTimedOut
        ? tr('数据更新中断')
        : quality.state == DeviceQualityState.passed && c.receiving
        ? tr('数据正常')
        : quality.state == DeviceQualityState.unavailable
        ? tr('暂无法完成数据检查')
        : tr('正在检查数据质量');
    return Container(
      padding: EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.surface.withValues(alpha: .7),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  c.connected ? Icons.sensors_rounded : Icons.bluetooth_rounded,
                  color: colors.primary,
                  size: 26,
                ),
              ),
              SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 5),
                    Text(
                      c.selected?.label ?? tr("打开设备电源，靠近手机"),
                      style: TextStyle(
                        color: colors.onPrimaryContainer.withValues(alpha: .8),
                      ),
                    ),
                  ],
                ),
              ),
              if (c.connecting ||
                  c.connected &&
                      quality.state == DeviceQualityState.checking &&
                      !c.stale)
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  active ? Icons.check_circle_rounded : Icons.circle_outlined,
                  color: active ? colors.primary : colors.onSurfaceVariant,
                  size: 22,
                ),
            ],
          ),
          SizedBox(height: 18),
          if (c.connected && quality.state != DeviceQualityState.passed)
            Text(tr('请保持佩戴，等待数据稳定。')),
          if (!c.connected) ...[
            SizedBox(height: 15),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Badge(
                  label: c.browserPicker
                      ? c.previewMode
                            ? tr("模拟设备")
                            : c.permissionsGranted
                            ? tr("设备已授权")
                            : tr("选择设备时授权")
                      : c.pythonBridge
                      ? tr("授权由 Python 管理")
                      : c.permissionsGranted
                      ? tr("权限已允许")
                      : tr("等待蓝牙授权"),
                  color: c.permissionsGranted
                      ? colors.primary
                      : colors.onSurfaceVariant,
                ),
                _Badge(
                  label: c.browserPicker
                      ? tr("蓝牙由浏览器管理")
                      : c.pythonBridge
                      ? tr("蓝牙由 Python 管理")
                      : c.enabled
                      ? tr("蓝牙已开启")
                      : tr("蓝牙未开启"),
                  color: c.enabled ? colors.primary : colors.onSurfaceVariant,
                ),
              ],
            ),
          ],
          SizedBox(height: 20),
          if (!c.supported)
            Text(
              c.canPreview
                  ? tr("请用本机 Chrome 打开此页面，并在电脑系统中允许 Chrome 使用蓝牙。也可以先查看模拟效果。")
                  : tr("当前设备蓝牙不可用，请检查系统蓝牙权限和开关。"),
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (c.connected || c.connecting)
                  OutlinedButton.icon(
                    key: Key('disconnect'),
                    onPressed: c.busy ? null : c.disconnect,
                    icon: Icon(Icons.link_off_rounded),
                    label: Text(tr("断开连接")),
                  )
                else
                  FilledButton.icon(
                    key: Key('scan'),
                    onPressed: c.busy
                        ? null
                        : c.scanning
                        ? c.stopScan
                        : c.scan,
                    icon: Icon(
                      c.scanning ? Icons.stop_rounded : Icons.radar_rounded,
                    ),
                    label: Text(
                      c.browserPicker
                          ? c.scanning
                                ? tr("正在选择设备…")
                                : c.previewMode
                                ? tr("搜索模拟设备")
                                : tr("选择蓝牙设备")
                          : c.scanning
                          ? tr("停止搜索")
                          : c.permissionsGranted
                          ? tr("搜索设备")
                          : tr("授权并搜索"),
                    ),
                  ),
                if (!c.connected && !c.connecting && c.selected != null)
                  OutlinedButton.icon(
                    key: Key('reconnect'),
                    onPressed: c.busy || c.scanning
                        ? null
                        : () => c.connect(c.selected!),
                    icon: Icon(Icons.refresh_rounded),
                    label: Text(tr("重新连接")),
                  ),
                if (c.connected &&
                    quality.state == DeviceQualityState.unavailable)
                  TextButton(onPressed: quality.retry, child: Text(tr('重新检查'))),
                if (c.permanentlyDenied)
                  TextButton(
                    onPressed: () => c.settings(),
                    child: Text(tr("打开权限设置")),
                  ),
                if (c.locationRequired && !c.locationEnabled)
                  TextButton(
                    onPressed: () => c.settings(location: true),
                    child: Text(tr("开启定位服务")),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _error(BuildContext context) => Container(
    padding: EdgeInsets.fromLTRB(16, 12, 8, 12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: [
        Icon(Icons.info_outline, size: 20),
        SizedBox(width: 10),
        Expanded(child: Text(c.error!, style: TextStyle(height: 1.5))),
        IconButton(
          onPressed: c.clearError,
          tooltip: tr("收起提示"),
          icon: Icon(Icons.close, size: 18),
        ),
      ],
    ),
  );
  Widget _devices(BuildContext context) => _Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                tr("附近设备"),
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            if (c.scanning)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Text(
                tr("{p0} 个", {'p0': c.devices.length}),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        SizedBox(height: 12),
        if (c.devices.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 22),
            child: Center(
              child: Column(
                children: [
                  Icon(
                    Icons.bluetooth_searching_rounded,
                    size: 34,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  SizedBox(height: 10),
                  Text(
                    c.scanning
                        ? tr("正在查找设备…")
                        : c.browserPicker
                        ? tr("点击“选择蓝牙设备”授权")
                        : tr("点击“搜索设备”开始"),
                  ),
                ],
              ),
            ),
          )
        else
          ...c.devices.map(
            (device) => Padding(
              padding: EdgeInsets.symmetric(vertical: 5),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  device.likelyEeg
                      ? Icons.sensors_rounded
                      : Icons.bluetooth_rounded,
                  color: Theme.of(context).colorScheme.primary,
                ),
                title: Text(
                  device.label,
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                trailing: OutlinedButton(
                  onPressed: c.busy ? null : () => c.connect(device),
                  child: Text(tr("连接")),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(padding: EdgeInsets.all(20), child: child),
  );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .1),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: color,
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: .2,
      ),
    ),
  );
}
