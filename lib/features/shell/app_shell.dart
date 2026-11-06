import '../tasks/report_insights.dart';
import '../tasks/report_insight_widgets.dart';
import 'saved_task_card.dart';
import '../tasks/learning_flow_widgets.dart';
import '../tasks/record_display_name.dart';
import '../tasks/learning_report.dart';
import '../tasks/detail_widgets.dart';
import 'history_models.dart';
import 'history_widgets.dart';
import 'dart:async';
import '../../ui/neurox_brand.dart';
import '../device/device_quality_assessment.dart';
import '../tasks/scene_protocol.dart';
import '../tasks/scene_widgets.dart';
import 'feedback_preferences.dart';
import '../tasks/monitoring_widgets.dart';
import '../tasks/baseline_features.dart';
import '../tasks/task_controller.dart';
import '../tasks/task_pages.dart';
import 'package:neurox/l10n/app_language.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../account/local_account.dart';
import '../account/password_confirmation_field.dart';
import 'notification_settings.dart';
import 'language_settings.dart';
import '../device/device_page.dart';
import '../device/eeg_controller.dart';

String recordState(Object? state) => switch (state) {
  'saved' => tr("已保存"),
  'recording' => tr("记录中"),
  'creating' => tr("正在建立"),
  'interrupted' => tr("异常中断"),
  'save_failed' => tr("记录未完整保存"),
  'deleting' => tr("清理未完成，可重试删除"),
  'imported' => tr("旧版记录 · 已确认归属"),
  _ => tr("未知状态"),
};
String localDate(Object? value) => value is num
    ? DateTime.fromMillisecondsSinceEpoch(
        (value * 1000).round(),
      ).toLocal().toString().substring(0, 19)
    : tr("未记录");

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.account, required this.controller});
  final LocalAccount account;
  final EegController controller;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with LanguageAware<AppShell> {
  int tab = 0;
  late final TaskController task;
  late final DeviceQualityAssessment deviceQuality;
  int? _shownReminder;
  @override
  void initState() {
    super.initState();
    task = TaskController(widget.controller)..addListener(_taskFeedback);
    deviceQuality = DeviceQualityAssessment(widget.controller);
    unawaited(task.loadFeedbackPreferences());
    widget.controller.initialize();
  }

  @override
  void dispose() {
    deviceQuality.dispose();
    task.removeListener(_taskFeedback);
    task.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: switch (tab) {
      1 => AnimatedBuilder(
        animation: task,
        builder: (context, _) => DevicePage(
          assessment: deviceQuality,
          controller: widget.controller,
          ownsController: false,
          overview: true,
        ),
      ),
      2 => HistoryPage(
        account: widget.account,
        controller: widget.controller,
        task: task,
      ),
      3 => ProfilePage(
        account: widget.account,
        controller: widget.controller,
        openHistory: () => setState(() => tab = 2),
        onFeedbackChanged: task.applyFeedbackDefaults,
      ),
      _ => _home(),
    },
    bottomNavigationBar: NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (value) => setState(() {
        tab = value;
      }),
      destinations: [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: tr("首页"),
        ),
        NavigationDestination(icon: Icon(Icons.bluetooth), label: tr("设备")),
        NavigationDestination(icon: Icon(Icons.history), label: tr("历史")),
        NavigationDestination(
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person),
          label: tr("我的"),
        ),
      ],
    ),
  );

  void _taskFeedback() {
    if (!task.active) {
      _shownReminder = null;
      return;
    }
    final seq = task.latestReminderSequence;
    if (seq == null || seq == _shownReminder) return;
    _shownReminder = seq;
    if (!task.feedback.muted &&
        task.feedback.notice &&
        task.monitor?.state == 'deviation') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !task.feedback.muted && task.feedback.notice) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr('提示：专注指标持续偏离个人参考，可选择调整或恢复练习。'))),
          );
        }
      });
    }
  }

  Future<void> endActiveTask() async {
    if (task.busy || !task.active) return;
    if (!await confirm(
      context,
      task.baselineCancellable ? tr('取消本次基线采集？') : tr('结束任务？'),
      task.baselineCancellable
          ? tr('本次尚未完成的基线不会保存，之前的有效基线不受影响。')
          : task.monitor != null && task.scene.competitive
          ? task.scene.endNotice
          : task.scene == TaskScene.training ||
                task.monitor != null && !task.monitor!.openEnded
          ? tr('提前结束会保存到未完成任务，已采集的数据保留。')
          : tr('保存本次采集、任务状态和已记录的事件。'),
    )) {
      return;
    }
    if (task.baselineCancellable) {
      await task.cancelBaseline();
    } else {
      final id = await task.finish();
      if (mounted &&
          id != null &&
          await offerLearningRecovery(context, task, id) &&
          mounted) {
        await openScene(TaskScene.recovery);
      }
    }
  }

  Widget activeTaskCard() => AnimatedBuilder(
    animation: task,
    builder: (context, _) {
      if (!task.active) {
        if (task.baselineInterruption != null && task.baselineDiscarded) {
          return Card(
            margin: const EdgeInsets.only(bottom: 16),
            child: ListTile(
              leading: Icon(
                Icons.error_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(tr('基线采集已中断')),
              subtitle: Text(
                baselineInterruptionLabel(task.baselineInterruption!),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => BaselineLibraryPage(task: task),
                ),
              ),
            ),
          );
        }
        if (task.completedSession == null) return const SizedBox.shrink();
        return SavedTaskCard(
          task: task,
          onOpen: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => RecordDetail(
                account: widget.account,
                controller: widget.controller,
                id: task.completedSession!,
                task: task,
              ),
            ),
          ),
        );
      }
      final title = task.usingSavedReference ? task.scene.label : tr('基线任务');
      return Card(
        margin: const EdgeInsets.only(bottom: 16),
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('进行中的任务'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(title),
              Text(
                task.monitor == null
                    ? baselineLabel(task.baseline?.state)
                    : monitorPhaseLabel(task.monitor?.phase),
              ),
              if (task.monitor != null)
                Text(tr('已记录 {p0}', {'p0': taskTime(task.monitor!.elapsed)})),
              Text(task.eeg.recording ? tr('原始记录保存中') : tr('当前未在保存原始记录')),
              Text(tr('同一时间只运行一个任务；返回首页不会结束采集。')),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: task.busy ? null : () => openScene(task.scene),
                    child: Text(tr('继续任务')),
                  ),
                  OutlinedButton(
                    onPressed: task.busy ? null : endActiveTask,
                    child: Text(
                      task.baselineCancellable ? tr('结束采集') : tr('结束并保存'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
  bool _openingTaskModule = false;
  Future<void> openTaskModule(TaskScene? scene) async {
    if (_openingTaskModule) return;
    _openingTaskModule = true;
    try {
      if (task.active) {
        final id = task.sessionId;
        final resume = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(tr('当前有任务未结束')),
            content: Text(tr('是否继续当前任务？')),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(tr('取消')),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(tr('继续任务')),
              ),
            ],
          ),
        );
        if (!mounted || resume != true) return;
        if (!task.active || task.sessionId != id) return;
        await openScene(task.scene);
        return;
      }
      if (task.busy || task.baselineChecking) {
        showMessage(context, tr('正在准备任务，请稍候。'));
        return;
      }
      if (scene != null) {
        await openScene(scene);
      } else {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(builder: (_) => BaselineLibraryPage(task: task)),
        );
      }
    } finally {
      _openingTaskModule = false;
    }
  }

  Future<void> openScene(TaskScene scene) async {
    if ((task.busy || task.baselineChecking) && !task.active) {
      showMessage(context, tr('正在准备任务，请稍候。'));
      return;
    }
    if (!task.active) {
      task.clearDraft();
      task.setScene(scene);
    }
    final id = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => task.active
            ? BaselinePage(task: task)
            : TaskPreparation(task: task),
      ),
    );
    if (!mounted) return;
    if (id != null) {
      if (await offerLearningRecovery(context, task, id)) {
        if (mounted) await openScene(TaskScene.recovery);
        return;
      }
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => RecordDetail(
            account: widget.account,
            controller: widget.controller,
            id: id,
            task: task,
          ),
        ),
      );
    }
  }

  Widget moduleCard(
    HistoryTaskType type,
    String label,
    String detail,
    VoidCallback open, {
    bool fullWidth = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = dark
        ? Color.lerp(type.accent, Colors.white, .35)!
        : type.accent;
    final icon = Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: type.accent.withValues(alpha: dark ? .24 : .12),
        borderRadius: BorderRadius.circular(15),
      ),
      child: Icon(type.icon, color: accent),
    );
    final title = Text(
      trSource(label),
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    );
    final description = Text(
      trSource(detail),
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: colors.onSurfaceVariant,
        height: 1.5,
      ),
    );
    return Material(
      key: ValueKey('home-module-${type.name}'),
      color: dark
          ? Color.alphaBlend(type.accent.withValues(alpha: .16), colors.surface)
          : type.tint,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: type.accent.withValues(alpha: .22)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: open,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: fullWidth
              ? Row(
                  children: [
                    icon,
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          title,
                          const SizedBox(height: 8),
                          description,
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.chevron_right, color: accent),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        icon,
                        const Spacer(),
                        Icon(
                          Icons.arrow_forward_rounded,
                          size: 19,
                          color: accent,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    title,
                    const SizedBox(height: 8),
                    description,
                  ],
                ),
        ),
      ),
    );
  }

  Widget homeModules() => LayoutBuilder(
    builder: (context, box) {
      final entries = [
        (
          HistoryTaskType.training,
          '专注训练任务',
          '四款小游戏：顺序搜索与视觉追踪，结束后查看脑波报告。',
          TaskScene.training,
        ),
        (
          HistoryTaskType.learning,
          '学习场景',
          '自习、阅读与做题：观察持续投入、偏离与恢复。',
          TaskScene.learning,
        ),
        (
          HistoryTaskType.competition,
          '竞技／运动训练',
          '电竞比赛、围棋对局与射箭训练，按项目阶段记录。',
          TaskScene.esports,
        ),
        (
          HistoryTaskType.recovery,
          '主动恢复',
          '方法示范、跟随引导与自主练习，逐步学会放松。',
          TaskScene.recovery,
        ),
      ];
      final twoColumns =
          box.maxWidth >= 270 &&
          (MediaQuery.textScalerOf(context).scale(1) < 1.4 ||
              box.maxWidth >= 600);
      Widget entry(int i) {
        final e = entries[i];
        return moduleCard(e.$1, e.$2, e.$3, () => openTaskModule(e.$4));
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          moduleCard(
            HistoryTaskType.baseline,
            '基线任务',
            '首次使用前建立参考；后续可重新记录、选择并设为当前。',
            () => openTaskModule(null),
            fullWidth: true,
          ),
          const SizedBox(height: 14),
          if (twoColumns)
            for (var i = 0; i < entries.length; i += 2) ...[
              if (i > 0) const SizedBox(height: 14),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: entry(i)),
                    const SizedBox(width: 14),
                    Expanded(child: entry(i + 1)),
                  ],
                ),
              ),
            ]
          else
            for (var i = 0; i < entries.length; i++) ...[
              if (i > 0) const SizedBox(height: 14),
              entry(i),
            ],
        ],
      );
    },
  );

  Widget _home() => Scaffold(
    appBar: AppBar(title: Text(tr("首页"))),
    body: ListView(
      padding: EdgeInsets.all(20),
      children: [
        NeuroxWelcome(
          title: tr("你好，{p0}", {
            'p0': widget.account.profile?['nickname'] ?? '',
          }),
          subtitle: tr("从一次真实采集开始，了解设备与数据。"),
        ),
        SizedBox(height: 24),
        activeTaskCard(),
        AnimatedBuilder(
          animation: widget.controller,
          builder: (context, _) {
            final c = widget.controller;
            return Card(
              child: ListTile(
                leading: Icon(Icons.sensors),
                title: Text(c.selected?.label ?? tr("尚未连接设备")),
                subtitle: Text(
                  '${c.connected
                      ? tr("已连接")
                      : c.connecting
                      ? tr("连接中")
                      : tr("未连接")} · ${c.dataStatus}',
                ),
                trailing: Icon(Icons.chevron_right),
                onTap: () => setState(() => tab = 1),
              ),
            );
          },
        ),
        SizedBox(height: 16),
        homeModules(),
        SizedBox(height: 16),
      ],
    ),
  );
}

class HistoryPage extends StatefulWidget {
  const HistoryPage({
    super.key,
    required this.account,
    required this.controller,
    this.task,
    this.clock,
  });
  final LocalAccount account;
  final EegController controller;
  final TaskController? task;
  final DateTime Function()? clock;
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage>
    with LanguageAware<HistoryPage> {
  List<HistoryEntry>? records;
  List<String> legacy = [];
  String? error;
  HistoryTaskStatus? status;
  HistoryTaskType? kind;
  HistoryPeriod period = HistoryPeriod.all;
  bool busy = false, selecting = false;
  final Set<String> selected = {};
  int _loadGeneration = 0;
  String? _observedTask;
  @override
  void initState() {
    super.initState();
    _observedTask = widget.task?.sessionId;
    widget.task?.addListener(_taskChanged);
    load();
  }

  void _taskChanged() {
    if (!mounted || _observedTask == widget.task?.sessionId) return;
    _observedTask = widget.task?.sessionId;
    if (!busy) unawaited(load());
  }

  @override
  void didUpdateWidget(covariant HistoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task != widget.task) {
      oldWidget.task?.removeListener(_taskChanged);
      _observedTask = widget.task?.sessionId;
      widget.task?.addListener(_taskChanged);
    }
  }

  @override
  void dispose() {
    widget.task?.removeListener(_taskChanged);
    super.dispose();
  }

  Future<void> load() async {
    final generation = ++_loadGeneration;
    if (mounted) {
      setState(() {
        error = null;
        records = null;
      });
    }
    try {
      final rows = await widget.account.call<List>('sessions');
      final old = await widget.account.call<List>('legacy');
      if (mounted && generation == _loadGeneration) {
        setState(() {
          records = (rows ?? [])
              .map((e) => HistoryEntry(Map<String, dynamic>.from(e as Map)))
              .toList();
          legacy = (old ?? []).cast<String>();
          selected.retainAll(records!.where(_selectable).map((e) => e.id));
        });
      }
    } catch (e) {
      if (mounted && generation == _loadGeneration) {
        setState(() => error = LocalAccount.describe(e));
      }
    }
  }

  bool _selectable(HistoryEntry entry) =>
      entry.id.isNotEmpty &&
      entry.data['task_state'] != 'active' &&
      !['recording', 'creating'].contains(entry.data['state']) &&
      widget.task?.sessionId != entry.id;
  bool get _captureActive =>
      widget.controller.recording || widget.task?.active == true;
  void _choose(HistoryEntry entry) {
    if (busy || !_selectable(entry)) return;
    setState(() {
      if (!selected.add(entry.id)) selected.remove(entry.id);
    });
  }

  void _startSelection() {
    if (selecting) {
      setState(() {
        selecting = false;
        selected.clear();
      });
      return;
    }
    if (_captureActive) {
      showMessage(context, tr('请先结束当前采集，再批量删除记录。'));
      return;
    }
    setState(() {
      selecting = !selecting;
      selected.clear();
    });
  }

  Future<void> _deleteSelected() async {
    if (busy || selected.isEmpty) return;
    if (_captureActive) {
      showMessage(context, tr('请先结束当前采集，再批量删除记录。'));
      return;
    }
    final now = widget.clock?.call() ?? DateTime.now();
    final targets = (records ?? [])
        .where(
          (e) =>
              selected.contains(e.id) &&
              _selectable(e) &&
              e.matches(state: status, kind: kind, period: period, now: now),
        )
        .toList();
    if (targets.isEmpty) return;
    final includesBaseline = targets.any(
      (e) => e.type == HistoryTaskType.baseline,
    );
    final confirmed = await confirm(
      context,
      tr('删除所选记录？'),
      tr('将删除 {p0} 条记录及对应文件，删除后无法恢复。', {'p0': targets.length}) +
          (includesBaseline ? ' ${tr('所选基线也会删除，后续任务可能需要重新选择或建立基线。')}' : ''),
    );
    if (!mounted || !confirmed) return;
    if (_captureActive) {
      showMessage(context, tr('采集已开始，本次未删除记录。'));
      return;
    }
    setState(() => busy = true);
    final succeeded = <String>{}, failed = <String>{};
    String? failure;
    for (final entry in targets) {
      if (_captureActive) {
        failed.add(entry.id);
        failure = tr('采集已开始，剩余记录未删除。');
        continue;
      }
      try {
        await widget.account.call<void>('deleteSession', {'id': entry.id});
        succeeded.add(entry.id);
      } catch (e) {
        failed.add(entry.id);
        failure ??= LocalAccount.describe(e);
      }
    }
    if (!mounted) return;
    selected
      ..clear()
      ..addAll(failed);
    final task = widget.task;
    if (task != null && succeeded.contains(task.completedSession)) {
      task.completedSession = null;
      task.completedTaskScene = null;
      task.completedBaseline = null;
    }
    if (task != null && !task.active && !task.busy) {
      await task.refresh(prepareSignal: false);
    }
    await load();
    if (!mounted) return;
    setState(() {
      busy = false;
      if (failed.isEmpty) selecting = false;
    });
    showMessage(
      context,
      failed.isEmpty
          ? tr('已删除 {p0} 条记录。', {'p0': succeeded.length})
          : tr('已删除 {p0} 条，{p1} 条未删除。', {
                  'p0': succeeded.length,
                  'p1': failed.length,
                }) +
                (failure == null ? '' : ' $failure'),
    );
  }

  Future<void> claim(String path) async {
    final ok = await confirm(
      context,
      tr("确认旧文件归属"),
      tr("将 {p0} 归入当前本机账号。请确认这是你的数据；旧版文件未验证点数与采集跨度。", {'p0': path}),
    );
    if (!ok) return;
    setState(() => busy = true);
    try {
      await widget.account.call<void>('claimLegacy', {'path': path});
      await load();
    } catch (e) {
      if (mounted) showMessage(context, LocalAccount.describe(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => widget.task?.active != true
      ? _content(context)
      : AnimatedBuilder(
          animation: widget.task!,
          builder: (context, _) => _content(context),
        );

  Widget _content(BuildContext context) {
    final now = widget.clock?.call() ?? DateTime.now();
    final shown = records
        ?.map((entry) {
          final task = widget.task, monitor = widget.task?.monitor;
          if (task?.active == true &&
              task?.sessionId == entry.id &&
              monitor != null) {
            return HistoryEntry({
              ...entry.data,
              'task_state': 'active',
              'monitor_json': {
                ...entry.monitor,
                'phase': monitor.phase,
                'elapsed': monitor.elapsed,
              },
            });
          }
          return entry;
        })
        .where(
          (entry) => entry.matches(
            state: status,
            kind: kind,
            period: period,
            now: now,
          ),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(tr("历史")),
        actions: [
          IconButton(
            key: const ValueKey('history-batch-delete'),
            onPressed: busy || records == null ? null : _startSelection,
            tooltip: tr(selecting ? '取消选择' : '批量删除'),
            icon: Icon(selecting ? Icons.close : Icons.playlist_remove_rounded),
          ),
          IconButton(
            onPressed: busy ? null : load,
            tooltip: tr("刷新"),
            icon: Icon(Icons.refresh),
          ),
        ],
      ),
      bottomNavigationBar: !selecting
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TextButton(
                      onPressed: busy
                          ? null
                          : () {
                              final ids = (shown ?? [])
                                  .where(_selectable)
                                  .map((e) => e.id)
                                  .toSet();
                              setState(() {
                                if (ids.isNotEmpty &&
                                    selected.containsAll(ids)) {
                                  selected.removeAll(ids);
                                } else {
                                  selected.addAll(ids);
                                }
                              });
                            },
                      child: Text(
                        tr(
                          (shown ?? []).where(_selectable).isNotEmpty &&
                                  selected.containsAll(
                                    (shown ?? [])
                                        .where(_selectable)
                                        .map((e) => e.id),
                                  )
                              ? '取消全选'
                              : '全选当前结果',
                        ),
                      ),
                    ),
                    FilledButton.icon(
                      key: const ValueKey('history-delete-selected'),
                      onPressed: busy || selected.isEmpty
                          ? null
                          : _deleteSelected,
                      icon: const Icon(Icons.delete_outline),
                      label: Text(
                        tr(busy ? '正在删除…' : '删除 {p0} 条', {
                          'p0': selected.length,
                        }),
                      ),
                    ),
                  ],
                ),
              ),
            ),
      body: ListView(
        padding: EdgeInsets.all(20),
        children: [
          if (busy) const LinearProgressIndicator(),
          if (selecting) ...[
            Text(tr('已选择 {p0} 条记录', {'p0': selected.length})),
            const SizedBox(height: 12),
          ],
          LayoutBuilder(
            builder: (context, box) {
              final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
              final columns = box.maxWidth >= 330 && scale <= 1.25
                  ? 3
                  : box.maxWidth >= 260 && scale < 1.4
                  ? 2
                  : 1;
              final fieldWidth = (box.maxWidth - 10 * (columns - 1)) / columns;
              return Wrap(
                spacing: 10,
                runSpacing: 14,
                children: [
                  SizedBox(
                    width: fieldWidth,
                    child: _historyDropdown<HistoryTaskStatus?>(
                      identity: 'history-status',
                      label: tr('任务状态'),
                      value: status,
                      items: [
                        DropdownMenuItem(value: null, child: Text(tr('全部'))),
                        for (final state in [
                          HistoryTaskStatus.completed,
                          HistoryTaskStatus.incomplete,
                          HistoryTaskStatus.running,
                          HistoryTaskStatus.paused,
                          HistoryTaskStatus.interrupted,
                          HistoryTaskStatus.saveFailed,
                        ])
                          DropdownMenuItem(
                            value: state,
                            child: Text(
                              state.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      changed: (v) => setState(() {
                        status = v;
                        selected.clear();
                      }),
                    ),
                  ),
                  SizedBox(
                    width: fieldWidth,
                    child: _historyDropdown<HistoryTaskType?>(
                      identity: 'history-type',
                      label: tr('类型'),
                      value: kind,
                      items: [
                        DropdownMenuItem(value: null, child: Text(tr('全部'))),
                        for (final type in HistoryTaskType.values.where(
                          (t) => t != HistoryTaskType.other,
                        ))
                          DropdownMenuItem(
                            value: type,
                            child: Text(
                              type.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      changed: (v) => setState(() {
                        kind = v;
                        selected.clear();
                      }),
                    ),
                  ),
                  SizedBox(
                    width: columns == 2 ? box.maxWidth : fieldWidth,
                    child: _historyDropdown<HistoryPeriod>(
                      identity: 'history-period',
                      label: tr('时间'),
                      value: period,
                      items: [
                        for (final (value, label) in [
                          (HistoryPeriod.all, '全部时间'),
                          (HistoryPeriod.today, '今天'),
                          (HistoryPeriod.week, '最近7天'),
                          (HistoryPeriod.month, '最近30天'),
                        ])
                          DropdownMenuItem(
                            value: value,
                            child: Text(
                              trSource(label),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      changed: (v) => setState(() {
                        period = v ?? HistoryPeriod.all;
                        selected.clear();
                      }),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          if (shown != null)
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  tr('共 {p0} 条记录', {'p0': shown.length}),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                if (status != null ||
                    kind != null ||
                    period != HistoryPeriod.all)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            selected.clear();
                            status = null;
                            kind = null;
                            period = HistoryPeriod.all;
                          }),
                    child: Text(tr('清除筛选')),
                  ),
              ],
            ),
          const SizedBox(height: 12),
          if (error != null) ...[
            Text(
              trSource(error!),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            TextButton(onPressed: load, child: Text(tr("重试"))),
          ] else if (shown == null)
            Center(child: CircularProgressIndicator())
          else if (shown.isEmpty) ...[
            Text(records!.isEmpty ? tr("还没有记录") : tr("当前条件下没有记录")),
          ] else
            for (final entry in shown)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: HistoryTaskCard(
                  entry: entry,
                  selecting: selecting,
                  selected: selected.contains(entry.id),
                  selectionEnabled: !busy && _selectable(entry),
                  liveSeconds: widget.task?.sessionId == entry.id
                      ? entry.type == HistoryTaskType.baseline
                            ? widget.task?.baseline?.attemptElapsed
                            : widget.task?.monitor?.elapsed
                      : null,
                  onTap: () async {
                    if (selecting) {
                      _choose(entry);
                      return;
                    }
                    if (busy) return;
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => RecordDetail(
                          account: widget.account,
                          controller: widget.controller,
                          id: entry.id,
                          task: widget.task,
                        ),
                      ),
                    );
                    if (mounted) await load();
                  },
                ),
              ),
          if (legacy.isNotEmpty) ...[
            SizedBox(height: 24),
            Text(
              tr("旧版文件 · 待确认归属"),
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(tr("这些文件未纳入当前账号。确认属于你后才可加入历史。删除账号不会清理尚未归属的文件。")),
            for (final path in legacy)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(path),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: busy || selecting ? null : () => claim(path),
                        child: Text(tr("确认归属")),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _historyDropdown<T>({
    required String identity,
    required String label,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> changed,
  }) => Container(
    key: ValueKey(identity),
    child: DropdownButtonFormField<T>(
      key: ValueKey('$identity-$value'),
      initialValue: value,
      isExpanded: true,
      iconSize: 18,
      style: Theme.of(context).textTheme.bodyMedium,
      decoration: InputDecoration(
        labelText: label,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 14,
        ),
      ),
      items: items,
      onChanged: busy ? null : changed,
    ),
  );
}

class RecordDetail extends StatefulWidget {
  const RecordDetail({
    super.key,
    required this.account,
    required this.controller,
    required this.id,
    this.task,
  });
  final LocalAccount account;
  final EegController controller;
  final String id;
  final TaskController? task;
  @override
  State<RecordDetail> createState() => _RecordDetailState();
}

class _RecordDetailState extends State<RecordDetail>
    with LanguageAware<RecordDetail> {
  Map<String, dynamic>? row;
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final value = await widget.account.call<Map>('detail', {'id': widget.id});
      if (value?['kind'] == 'baseline') {
        try {
          final reference = await widget.account.call<Map>('baselineSelection');
          if (reference != null) {
            value!['selected_reference'] = reference['id'] == widget.id;
          }
        } catch (_) {
          // Selection availability is optional; preserve the saved record.
        }
      }
      if (mounted) {
        setState(() {
          row = Map<String, dynamic>.from(value!);
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = LocalAccount.describe(e));
    }
  }

  Future<void> action(bool delete, {bool summary = false}) async {
    final reportFont = Theme.of(context).textTheme.bodyMedium?.fontFamily;
    if (delete &&
        !await confirm(
          context,
          tr('删除这条记录？'),
          row?['selected_reference'] == true
              ? tr('删除记录及原始文件。此基线正在选用，删除后需重新选择或建立基线。已导出的副本保留。')
              : tr("删除本机索引及其原始JSONL文件。已导出到App外的副本不会被删除。"),
        )) {
      return;
    }
    setState(() => busy = true);
    try {
      if (delete) {
        await widget.account.call<void>('deleteSession', {'id': widget.id});
        if (mounted) Navigator.of(context).pop();
      } else {
        final learningReport =
            summary && row != null && isFocusScene(HistoryEntry(row!).scene);
        final bytes = learningReport
            ? await renderLearningReport(row!, fontFamily: reportFont)
            : null;
        final completed = await MethodChannel('neurox/eeg/methods')
            .invokeMethod<bool>(
              learningReport
                  ? 'exportLearningReport'
                  : summary
                  ? 'exportTaskSummary'
                  : 'exportRecording',
              {'id': widget.id, 'png': ?bytes},
            );
        if (mounted) {
          showMessage(
            context,
            completed == true ? tr("已完成分享") : tr("分享已取消，本机文件保留"),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        showMessage(context, LocalAccount.describe(e));
        await load();
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = row;
    final active = r != null && ['recording', 'creating'].contains(r['state']);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          r?['kind'] == 'task'
              ? tr('任务复盘')
              : r?['kind'] == 'baseline'
              ? tr('基线记录详情')
              : tr('诊断记录详情'),
        ),
      ),
      body: ListView(
        padding: EdgeInsets.all(24),
        children: [
          if (error != null) ...[
            Text(trSource(error!)),
            TextButton(onPressed: load, child: Text(tr("重试"))),
          ] else if (r == null)
            Center(child: CircularProgressIndicator())
          else ...[
            Text(
              recordDisplayName(r),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            if (detailMap(r['task_json'])['isReplay'] == true &&
                HistoryEntry(r).scene == 'archery')
              Text(tr('射箭回放仅含静态准备，不含瞄准／释放数据。')),
            if (detailMap(r['task_json'])['isReplay'] == true)
              Chip(label: Text(tr('测试回放 · 学习记录数据'))),
            const SizedBox(height: 16),
            if (hasCompactTaskDetails(HistoryEntry(r).scene))
              DetailSection(
                title: tr('记录概况'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 16,
                      runSpacing: 8,
                      children: [
                        Text(HistoryEntry(r).status.label),
                        if (HistoryEntry(r).scene != 'learning')
                          Text(
                            TaskScene.values
                                .firstWhere(
                                  (s) => s.name == HistoryEntry(r).scene,
                                )
                                .label,
                          ),
                        Text(
                          tr('记录时长 {p0}', {
                            'p0': detailTime(HistoryEntry(r).durationSeconds),
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(tr('开始时间：{p0}', {'p0': localDate(r['started'])})),
                  ],
                ),
              )
            else
              DetailSection(
                title: tr('记录概况'),
                child: DetailFacts(
                  values: [
                    (tr('任务状态'), HistoryEntry(r).status.label),
                    (
                      tr('任务类型'),
                      switch (HistoryEntry(r).scene) {
                        'esports' => tr('电竞比赛'),
                        'go' => tr('围棋对局'),
                        'archery' => tr('射箭训练'),
                        _ => HistoryEntry(r).type.label,
                      },
                    ),
                    (tr('开始时间'), localDate(r['started'])),
                    (tr('实际时长'), detailTime(HistoryEntry(r).durationSeconds)),
                    (tr('设备'), r['device'] as String? ?? '—'),
                    if ((detailMap(r['monitor_json'])['targetSeconds']
                                as num? ??
                            0) >
                        0)
                      (
                        tr('目标时长'),
                        detailTime(
                          detailMap(r['monitor_json'])['targetSeconds'],
                        ),
                      ),
                  ],
                ),
              ),
            if (r['kind'] == 'task')
              TaskReview(row: r, account: widget.account, showName: false)
            else if (r['kind'] == 'baseline')
              BaselineHistorySummary(row: r, showName: false)
            else
              Text(
                tr(
                  "未形成任务判断。未开始监测，不计算有效比例、基线或专注结论。中断记录的点数可能仅覆盖最后落盘检查点；缺失区间不补造。",
                ),
              ),
            if (hasCompactTaskDetails(HistoryEntry(r).scene))
              const SizedBox(height: 24),
            ExpansionTile(
              title: Text(tr('技术详情')),
              children: [
                DetailFacts(
                  values: [
                    (tr('保存状态'), recordState(r['state'])),
                    if (hasCompactTaskDetails(HistoryEntry(r).scene))
                      (tr('设备'), r['device'] as String? ?? '—'),
                    (tr('结束时间'), localDate(r['ended'])),
                    (
                      tr('通知数'),
                      r['state'] == 'imported'
                          ? '—'
                          : detailNumber(r['packets'], decimals: 0),
                    ),
                    (
                      tr('原始点数/通道'),
                      r['state'] == 'imported'
                          ? '—'
                          : detailNumber(r['samples'], decimals: 0),
                    ),
                    (tr('文件大小'), r['bytes'] is num ? '${r['bytes']} B' : '—'),
                  ],
                ),
                Text(
                  r['exists'] == true
                      ? tr('原始文件可用')
                      : tr('原始文件缺失；已保存摘要仍可查看，不能导出原始数据。'),
                ),
                if (r['kind'] != 'baseline' &&
                    !hasCompactTaskDetails(HistoryEntry(r).scene))
                  Text(trSource(r['reason'] as String? ?? '')),
                if (r['kind'] != 'baseline' &&
                    !hasCompactTaskDetails(HistoryEntry(r).scene))
                  Text(
                    tr('数据来源与限制\n{p0}\n主机接收时间不等于设备采样时间；算法含参考实现假设。', {
                      'p0': trSource(r['source'] as String? ?? ''),
                    }),
                  ),
              ],
            ),
            SizedBox(height: 24),
            if (active) Text(tr("记录尚未结束，请返回进行中的任务结束并保存。")),
            if (r['kind'] == 'task')
              FilledButton(
                onPressed:
                    busy ||
                        active ||
                        [
                          'active',
                          'interrupted_pending',
                        ].contains(r['task_state'])
                    ? null
                    : () => action(false, summary: true),
                child: Text(
                  isFocusScene(HistoryEntry(r).scene)
                      ? tr(
                          HistoryEntry(r).scene == 'learning'
                              ? '导出学习报告图片'
                              : '导出训练报告图片',
                        )
                      : tr('导出任务摘要与事件'),
                ),
              ),
            if (['active', 'interrupted_pending'].contains(r['task_state']) &&
                !active &&
                !widget.controller.recording)
              TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        setState(() => busy = true);
                        try {
                          await const MethodChannel(
                            'neurox/eeg/methods',
                          ).invokeMethod('baselineFinish', {'id': widget.id});
                          await load();
                        } catch (e) {
                          if (context.mounted) {
                            showMessage(context, LocalAccount.describe(e));
                          }
                        } finally {
                          if (mounted) setState(() => busy = false);
                        }
                      },
                child: Text(tr('结束中断任务并保存')),
              ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed:
                  busy ||
                      active ||
                      r['exists'] != true ||
                      r['state'] == 'deleting'
                  ? null
                  : () => action(false),
              child: Text(
                detailMap(r['task_json'])['isReplay'] == true
                    ? tr('导出回放 JSONL')
                    : tr("导出原始 JSONL"),
              ),
            ),
            SizedBox(height: 10),
            OutlinedButton(
              onPressed:
                  busy ||
                      active ||
                      r['task_state'] == 'active' ||
                      widget.controller.recording
                  ? null
                  : () => action(true),
              child: Text(tr("删除记录")),
            ),
            if (active ||
                r['task_state'] == 'interrupted_pending' ||
                ['save_failed', 'deleting'].contains(r['state']))
              TextButton(
                onPressed: busy ? null : load,
                child: Text(tr("刷新记录状态")),
              ),
          ],
        ],
      ),
    );
  }
}

class BaselineHistorySummary extends StatelessWidget {
  const BaselineHistorySummary({
    super.key,
    required this.row,
    this.showName = true,
  });
  final Map<String, dynamic> row;
  final bool showName;
  Map<String, dynamic> decode(Object? value) => detailMap(value);

  @override
  Widget build(BuildContext context) {
    final attempts = row['attempts'] as List? ?? [];
    final snapshot = detailMap(row['baseline_json']);
    final latest = attempts.isEmpty
        ? <String, dynamic>{}
        : detailMap((attempts.last as Map)['snapshot']);
    final result = snapshot.isNotEmpty ? snapshot : latest;
    final stats = detailMap(result['statistics']);
    final windows = (row['windows'] as List? ?? [])
        .where(
          (raw) =>
              attempts.length <= 1 ||
              (raw as Map)['attempt_id'] == result['attemptId'],
        )
        .toList();
    final ready =
        row['task_state'] == 'baseline_ready' && result['state'] == 'ready';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showName)
          Text(
            recordDisplayName(row),
            style: Theme.of(context).textTheme.titleLarge,
          ),
        const SizedBox(height: 12),
        if (row['selected_reference'] == true) Chip(label: Text(tr('当前选用基线'))),
        DetailSection(
          title: tr('采集质量'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DetailFacts(
                values: [
                  (tr('有效数据时长'), detailTime(result['validSeconds'])),
                  (
                    tr('有效覆盖率'),
                    detailRatio(result['validSeconds'], result['elapsed']),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                ready
                    ? tr('基线已建立')
                    : qualityLabel(result['reason'] as String? ?? 'waiting'),
              ),
              Text(tr('覆盖率按统计时段计算，不包含开始适应时间。')),
            ],
          ),
        ),
        if (ready && result['algorithm'] == baselineAlgorithmVersion)
          DetailSection(
            title: tr('个人参考结果'),
            child: DetailFacts(
              values: [
                for (final (key, title) in [
                  ('attention', '专注基线'),
                  ('relax', '放松基线'),
                ])
                  (
                    trSource(title),
                    '${detailNumber(detailMap(stats[key])['mean'])} ± ${detailNumber(detailMap(stats[key])['standardDeviation'])}',
                  ),
              ],
            ),
          ),
        if (stats.isNotEmpty && result['algorithm'] != baselineAlgorithmVersion)
          Text(tr('旧版基线：保留原始统计，不换算成当前SDK算法的个人基线。')),
        DetailSection(
          title: tr('过程曲线'),
          child: Column(
            children: [
              if (windows.isNotEmpty)
                SceneCurve(
                  title: tr('历史指标曲线'),
                  interactive: true,
                  observationOnly: true,
                  observationHint: tr('曲线显示每秒观测，开始时需等待滤波稳定；基线统计仍使用连续5秒比较值。'),
                  eventLogTitle: tr('采集状态记录'),
                  eventLabel: (event) =>
                      qualityLabel(event['reason'] as String? ?? 'waiting'),
                  events: baselineDetailEvents(windows),
                ),
            ],
          ),
        ),
        ReportInsights(lines: baselineInsights(result), notes: baselineNotes()),
      ],
    );
  }
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({
    super.key,
    required this.account,
    required this.controller,
    required this.openHistory,
    this.onFeedbackChanged,
  });
  final LocalAccount account;
  final EegController controller;
  final VoidCallback openHistory;
  final ValueChanged<FeedbackOptions>? onFeedbackChanged;
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage>
    with LanguageAware<ProfilePage> {
  bool busy = false;
  String? storage;
  @override
  void initState() {
    super.initState();
    readStorage();
  }

  Future<void> readStorage() async {
    try {
      final rows = await widget.account.call<List>('sessions') ?? [];
      final bytes = rows.fold<int>(
        0,
        (sum, e) => sum + ((e as Map)['bytes'] as num).toInt(),
      );
      if (mounted) {
        setState(
          () => storage = tr('{p0} 条记录 · {p1} MB', {
            'p0': rows.length,
            'p1': (bytes / (1024 * 1024)).toStringAsFixed(1),
          }),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => storage = tr("存储读取失败：{p0}", {'p0': LocalAccount.describe(e)}),
        );
      }
    }
  }

  Future<void> edit(String mode) async {
    if (widget.controller.recording && mode != 'profile') {
      showMessage(context, tr("请先停止并保存诊断记录。"));
      return;
    }
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AccountEdit(account: widget.account, mode: mode),
      ),
    );
    if (result == true && mounted) {
      if (mode == 'profile') {
        setState(() {});
      } else {
        widget.account.lock();
        await widget.account.check();
      }
    }
  }

  Future<void> logout() async {
    if (!await confirm(
      context,
      tr("退出登录？"),
      widget.controller.recording
          ? tr("将先停止并保存诊断记录，再断开设备。已保存数据保留。")
          : tr("断开设备并返回登录页，保留本机资料和记录。"),
    )) {
      return;
    }
    setState(() => busy = true);
    try {
      if (widget.controller.recording) {
        await widget.controller.toggleRecording();
        if (widget.controller.error != null) {
          throw StateError(widget.controller.error!);
        }
      }
      await widget.account.logout();
    } catch (e) {
      if (mounted) showMessage(context, LocalAccount.describe(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> settings(String title, Widget child) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => _ProfileSettingsPage(title: title, child: child),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tiles = <Widget>[
      _ProfileTile(
        icon: Icons.lock_outline,
        label: tr('修改密码'),
        onTap: busy ? null : () => edit('password'),
      ),
      _ProfileTile(
        icon: Icons.folder_open_outlined,
        label: tr('本机存储'),
        detail: storage == null ? tr('正在读取…') : trSource(storage!),
        onTap: widget.openHistory,
      ),
      _ProfileTile(
        icon: Icons.language,
        label: tr('语言设置'),
        detail: AppLanguage.instance.english ? 'English' : '简体中文',
        onTap: () => settings('语言设置', const LanguageSettings(concise: true)),
      ),
      _ProfileTile(
        icon: Icons.tune_rounded,
        label: tr('提醒方式'),
        onTap: () => settings(
          '提醒方式',
          FeedbackDefaults(concise: true, onSaved: widget.onFeedbackChanged),
        ),
      ),
      _ProfileTile(
        icon: Icons.notifications_none_rounded,
        label: tr('系统通知权限'),
        onTap: () =>
            settings('系统通知权限', const NotificationSettings(concise: true)),
        wide: true,
      ),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(tr('我的'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: NeuroxBrand.wash(context),
              borderRadius: BorderRadius.circular(26),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(26),
              onTap: busy ? null : () => edit('profile'),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    const NeuroxMark(size: 64),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.account.profile?['nickname'] as String? ??
                                '',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w600),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            widget.account.profile?['name'] as String? ?? '',
                            style: TextStyle(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.edit_outlined, color: colors.primary, size: 20),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          LayoutBuilder(
            builder: (context, box) {
              final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
              final columns = box.maxWidth >= 850
                  ? 3
                  : box.maxWidth >= 260 &&
                        (scale <= 1.35 || box.maxWidth >= 550)
                  ? 2
                  : 1;
              return Column(
                children: [
                  for (var start = 0; start < tiles.length; start += columns)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (
                              var offset = 0;
                              offset <
                                  (tiles.length - start < columns
                                      ? tiles.length - start
                                      : columns);
                              offset++
                            ) ...[
                              if (offset > 0) const SizedBox(width: 14),
                              Expanded(
                                child: start + offset < tiles.length
                                    ? tiles[start + offset]
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: busy ? null : () => logout(),
            child: Text(tr('退出登录')),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: busy ? null : () => edit('delete'),
            child: Text(tr('删除本机账号'), style: TextStyle(color: colors.error)),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.detail,
    this.wide = false,
  });
  final IconData icon;
  final String label;
  final String? detail;
  final VoidCallback? onTap;
  final bool wide;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final symbol = Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(icon, color: colors.primary, size: 26),
    );
    final caption = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          label,
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (detail != null) ...[
          const SizedBox(height: 6),
          Text(
            detail!,
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ],
    );
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: wide ? 100 : 150),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Center(
              child: wide
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        symbol,
                        const SizedBox(width: 18),
                        Flexible(child: caption),
                      ],
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [symbol, const SizedBox(height: 14), caption],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileSettingsPage extends StatefulWidget {
  const _ProfileSettingsPage({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  State<_ProfileSettingsPage> createState() => _ProfileSettingsPageState();
}

class _ProfileSettingsPageState extends State<_ProfileSettingsPage>
    with LanguageAware<_ProfileSettingsPage> {
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        trSource(widget.title),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        widget.child,
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('完成')),
        ),
      ],
    ),
  );
}

class AccountEdit extends StatefulWidget {
  const AccountEdit({super.key, required this.account, required this.mode});
  final LocalAccount account;
  final String mode;
  @override
  State<AccountEdit> createState() => _AccountEditState();
}

class _AccountEditState extends State<AccountEdit>
    with LanguageAware<AccountEdit> {
  final old = TextEditingController();
  final next = TextEditingController();
  final again = TextEditingController();
  final passwordFocus = FocusNode();
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    if (widget.mode == 'profile') {
      next.text = widget.account.profile?['nickname'] as String? ?? '';
    }
  }

  @override
  void dispose() {
    passwordFocus.dispose();
    old.dispose();
    next.dispose();
    again.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (widget.mode == 'password' &&
        (next.text != again.text ||
            next.text.runes.length < 6 ||
            next.text.runes.length > 128)) {
      setState(() => error = tr("新密码须为6–128个字符，且两次输入一致。"));
      return;
    }
    if (widget.mode == 'delete' &&
        !await confirm(
          context,
          tr("确认删除本机账号与所属记录？"),
          tr("清理账号资料、钥匙串凭据和本账号诊断文件。未确认归属的旧文件及App外导出副本保留。此操作不可撤销。"),
        )) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (widget.mode == 'profile') {
        final p = await widget.account.call<Map>('updateProfile', {
          'nickname': next.text,
          'reminders': widget.account.profile?['reminders'] ?? 0,
        });
        widget.account.profile = Map<String, dynamic>.from(p!);
      } else {
        await widget.account.call<void>(
          widget.mode == 'password' ? 'changePassword' : 'deleteAccount',
          {'password': old.text, 'newPassword': next.text},
        );
      }
      old.clear();
      next.clear();
      again.clear();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (e is PlatformException && e.code == 'cleanup_incomplete') {
        widget.account.lock();
        await widget.account.check();
      } else if (mounted) {
        setState(() => error = LocalAccount.describe(e));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.mode == 'profile';
    final delete = widget.mode == 'delete';
    return Scaffold(
      appBar: AppBar(
        title: Text(
          profile
              ? tr("账号资料")
              : delete
              ? tr("删除本机账号")
              : tr("修改密码"),
        ),
      ),
      body: ListView(
        padding: EdgeInsets.all(24),
        children: [
          if (profile)
            Text(tr("账号：{p0}（只读）", {'p0': widget.account.profile?['name']}))
          else
            Text(
              delete
                  ? tr("再次验证密码。完成清理后返回注册；清理失败保留状态并可重试。")
                  : tr("成功后将重新登录。账号及已有记录归属保留。"),
            ),
          SizedBox(height: 20),
          if (!profile)
            TextField(
              controller: old,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: delete ? tr("当前密码") : tr("旧密码"),
              ),
            ),
          if (!delete)
            TextField(
              controller: next,
              focusNode: passwordFocus,
              obscureText: !profile,
              enableSuggestions: profile,
              autocorrect: profile,
              decoration: InputDecoration(
                labelText: profile ? tr("昵称（最多32个字符）") : tr("新密码（6–128个字符）"),
              ),
            ),
          if (!profile && !delete)
            PasswordConfirmationField(
              key: Key('confirmNewPassword'),
              password: next,
              controller: again,
              passwordFocus: passwordFocus,
              label: tr("确认新密码"),
            ),
          SizedBox(height: 24),
          FilledButton(
            onPressed: busy ? null : submit,
            child: Text(
              busy
                  ? tr("处理中…")
                  : delete
                  ? tr("验证并删除")
                  : tr("保存"),
            ),
          ),
          if (error != null)
            Text(
              trSource(error!),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (delete && error != null)
            TextButton(
              onPressed: busy
                  ? null
                  : () {
                      widget.account.lock();
                      widget.account.check();
                    },
              child: Text(tr("返回启动检查并重试清理")),
            ),
        ],
      ),
    );
  }
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String message,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr("取消")),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr("确认")),
          ),
        ],
      ),
    ) ??
    false;
void showMessage(BuildContext context, String message) => ScaffoldMessenger.of(
  context,
).showSnackBar(SnackBar(content: Text(message)));
