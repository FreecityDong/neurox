import 'training_flow_widgets.dart';
import 'competition_guidance.dart';
import 'recovery_flow_widgets.dart';
import 'learning_flow_widgets.dart';
import 'record_display_name.dart';
import 'training_game.dart';
import 'training_widgets.dart';
import 'scene_protocol.dart';
import 'scene_widgets.dart';
import '../shell/feedback_preferences.dart';
import 'monitoring_widgets.dart';
import '../device/device_page.dart';
import 'reference_metrics.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_language.dart';
import '../shell/app_shell.dart' show confirm;
import 'task_controller.dart';

String qualityLabel(String reason) => trSource(switch (reason) {
  'raw_good' => '基础有效性检查通过（未校准伪迹阈值）',
  'raw_range' => '原始值达到编码边界，请检查设备与佩戴',
  'good' => '信号质量合格',
  'metadata' => '采样率、物理单位或质量参数待确认',
  'disconnected' || 'connection' => '设备连接已变化，请重新采集',
  'data' || 'gap' || 'coverage' => '实时数据不足或不连续',
  'sdk_score_invalid' => 'SDK结果无效，已重置计算窗口',
  'feature_schema' => '特征定义不一致，请重新采集',
  'flat' => '信号过平，请检查佩戴',
  'saturation' => '信号饱和，请检查佩戴',
  'amplitude' || 'step' => '信号波动过大，请保持静止',
  'restart' => 'App中断，基线已失效',
  'background' => '进入后台，基线已失效；原始记录继续保存',
  'insufficient' => '180秒内有效数据不足',
  'degenerate' => '基线变化不足，无法形成可靠参考',
  'adapting' => '正在适应，请自然默读短文',
  'collecting' => '正在收集有效比较数据',
  'comparison_warming' => '等待连续5秒有效数据',
  'unstable' => '参考波动较大',
  'drift' => '参考前后变化较大',
  'floor' => '专注参考过低，无法比较下降，请重新采集。',
  'reference_expired' => '基线等待已超过60秒，请重新采集。',
  'storage' => '保存失败，请检查记录',
  'configuration' => '采集配置已变化，请重新采集',
  'processing' ||
  'spectrum' ||
  'non_finite' ||
  'invalid_input' => '信号处理异常，请重新检查',
  'warming' => '正在等待滤波稳定',
  'ended' => '用户结束了基线采集',
  _ => '等待信号质量检查',
});
String baselineLabel(String? state) => trSource(switch (state) {
  'ready' => '基线就绪',
  'failed' => '基线未达标',
  'invalid' => '基线已失效',
  _ => '正在采集个人基线',
});

String baselineCheckLabel(String reason) => trSource(switch (reason) {
  'checking' => '正在检查设备与记录条件…',
  'waiting_data' => '正在等待脑电数据…',
  'stabilizing' => '信号检查正常，正在确认稳定性…',
  'signal_warming' => '数据已收到，正在检查信号…',
  'contact_wait' => '接触状态有变化，请调整头带并保持坐稳…',
  'signal_unstable' => '信号暂不稳定，请保持安静并检查头带佩戴…',
  'passed' => '检查通过，正在开始采集…',
  'disconnected' => '检查已停止：设备未连接，请连接头带后重试。',
  'contact' => '检查未通过：电极接触异常，请调整佩戴后重试。',
  'preview' => '检查已停止：请连接真实设备后重试。',
  'storage' => '检查已停止：无法保存记录，请检查存储后重试。',
  'pending' => '检查已停止：请先结束上次未完成的记录。',
  'configuration' => '检查已停止：设备配置不可用，请重新连接设备。',
  'occupied' => '检查已停止：已有采集正在进行，请先结束。',
  'background' => '检查已停止：请保持页面在前台后重试。',
  'quality_timeout' => '检查未通过：信号尚未稳定，请调整佩戴后重试。',
  'data' => '检查未通过：未持续收到数据，请检查连接后重试。',
  _ => '点击开始后检查设备与信号。',
});

String baselineInterruptionLabel(String reason) => trSource(switch (reason) {
  'contact' => '设备持续报告接触异常，本次基线已中断。请调整佩戴后重新采集。',
  'wearing' || 'waveform' => '信号持续不稳定，本次基线已中断。请保持安静并检查佩戴后重试。',
  'data_loss' || 'data' => '数据接收不足或不连续，本次基线已中断。请检查设备电量和连接后重试。',
  'connection' || 'disconnected' => '设备连接中断，本次基线已放弃。请重新连接后采集。',
  'unstable' || 'drift' => '本次数据波动较大，未建立有效基线。请调整佩戴、安静休息后重新采集。',
  'floor' => '本次数据未能形成可用参考，请调整状态后重新采集。',
  'ended' => '本次基线未完成，记录未保留。',
  'background' => '采集已中断，请保持页面在前台后重新采集。',
  _ => '本次数据未通过检查，未保留无效基线。请检查佩戴后重新采集。',
});

String baselineFailureLabel(String reason) => trSource(switch (reason) {
  'unstable' || 'drift' => '本次数据波动较大，未建立有效基线。请调整佩戴、安静休息后重新采集。',
  'floor' => '本次数据未能形成可用参考，请调整状态后重新采集。',
  _ => '本次有效数据不足，未建立有效基线。请检查佩戴与连接后重新采集。',
});

class TaskPreparation extends StatefulWidget {
  const TaskPreparation({
    super.key,
    required this.task,
    this.baselineOnly = false,
  });
  final bool baselineOnly;
  final TaskController task;
  @override
  State<TaskPreparation> createState() => _TaskPreparationState();
}

class _TaskPreparationState extends State<TaskPreparation>
    with LanguageAware<TaskPreparation> {
  late final TextEditingController name;
  TaskController get task => widget.task;
  @override
  void initState() {
    super.initState();
    if (widget.baselineOnly) task.resetBaselineCheck();
    name = TextEditingController(text: task.name);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.baselineOnly) {
        task.loadFeedbackPreferences();
      } else {
        task.refresh();
      }
    });
  }

  @override
  void dispose() {
    if (widget.baselineOnly) task.cancelBaselineCheck();
    name.dispose();
    super.dispose();
  }

  Future<void> start() async {
    final startedScene = task.scene;
    task.name = name.text;
    if (widget.baselineOnly) {
      await task.checkAndStartBaseline();
    } else {
      await task.startLearning();
    }
    if (!mounted || !task.active) return;
    final id = await Navigator.of(
      context,
    ).push(MaterialPageRoute<String>(builder: (_) => BaselinePage(task: task)));
    if (mounted && task.learningPreparationDiscarded) {
      Navigator.of(context).pop();
      return;
    }
    if (mounted &&
        widget.baselineOnly &&
        task.baselineDiscarded &&
        task.baselineInterruption == null) {
      Navigator.of(context).pop();
    } else if (mounted && id != null) {
      if ((startedScene == TaskScene.learning || startedScene.competitive) &&
          await offerLearningRecovery(context, task, id)) {
        if (!mounted || task.active) return;
        task.clearDraft();
        task.setScene(TaskScene.recovery);
        final recovered = await Navigator.of(context).push<String>(
          MaterialPageRoute(builder: (_) => TaskPreparation(task: task)),
        );
        if (mounted) {
          Navigator.of(context).pop(task.active ? null : recovered ?? id);
        }
        return;
      }
      if (mounted) Navigator.of(context).pop(id);
    } else if (mounted && task.active) {
      Navigator.of(context).pop();
    } else if (mounted) {
      if (widget.baselineOnly) {
        task.baselineCheckReason = 'idle';
        task.baselineCheckProgress = 0;
      }
      await task.refresh(prepareSignal: !widget.baselineOnly);
    }
  }

  Widget _baselinePreparation(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr('基线准备'))),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          tr('安静阅读，建立个人参考'),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        Text(tr('戴好头带，睁眼坐稳，保持自然呼吸。开始后请安静默读，尽量减少说话和动作。')),
        const SizedBox(height: 12),
        Text(tr('约2–3分钟，数据不足时会适当延长。')),
        const SizedBox(height: 24),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(tr('提醒方式')),
          children: [
            FeedbackControls(
              concise: true,
              value: task.feedback,
              onChanged: task.busy || task.baselineChecking
                  ? null
                  : task.setFeedback,
            ),
          ],
        ),
        const SizedBox(height: 24),
        if (task.baselineCheckReason != 'idle') ...[
          Text(tr('佩戴与采集检查'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: task.baselineCheckProgress),
          const SizedBox(height: 12),
          Text(baselineCheckLabel(task.baselineCheckReason)),
          const SizedBox(height: 20),
        ],
        if (task.baselineCheckReason == 'pending')
          for (final row in task.unresolved)
            ListTile(
              title: Text(recordDisplayName(row)),
              trailing: TextButton(
                onPressed: task.busy
                    ? null
                    : () => task.resolve(row['id'] as String),
                child: Text(tr('结束并保存')),
              ),
            ),
        FilledButton(
          onPressed: task.busy || task.active || task.baselineChecking
              ? null
              : start,
          child: Text(tr(task.baselineChecking ? '正在检查…' : '开始采集个人基线')),
        ),
        if (task.baselineChecking)
          TextButton(
            onPressed: task.busy ? null : task.cancelBaselineCheck,
            child: Text(tr('取消检查')),
          ),
        if (!task.baselineChecking &&
            [
              'disconnected',
              'data',
              'quality_timeout',
            ].contains(task.baselineCheckReason))
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DevicePage(
                  controller: task.eeg,
                  ownsController: false,
                  overview: true,
                ),
              ),
            ),
            child: Text(tr('检查或恢复设备连接')),
          ),
      ],
    ),
  );

  Future<void> _openLearningBaseline() async {
    final scene = task.scene,
        minutes = task.targetMinutes,
        method = task.recoveryMethod,
        game = task.trainingKind,
        level = task.trackingLevel;
    final matches = task.conditionMatches, feedback = task.feedback;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => BaselineLibraryPage(task: task)),
    );
    if (mounted && !task.active) {
      task.setScene(scene);
      task.targetMinutes = minutes;
      task.recoveryMethod = method;
      task.trainingKind = game;
      task.trackingLevel = level;
      task.conditionMatches = matches;
      task.setFeedback(feedback);
      task.name = name.text;
      await task.refresh();
    }
  }

  Widget _learningPreparation(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(task.scene.preparationLabel)),
    bottomNavigationBar: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: FilledButton(
          onPressed: task.canStartLearning ? start : null,
          child: Text(task.scene.prepareButtonLabel),
        ),
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      children: [
        LearningStageGuide(stage: 0, scene: task.scene),
        Text(
          tr(
            task.scene == TaskScene.learning
                ? '开始一段专注学习'
                : task.scene == TaskScene.recovery
                ? '准备一次主动恢复'
                : task.scene == TaskScene.training
                ? '开始一次专注训练'
                : '准备竞技／运动训练',
          ),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        Text(task.scene.setupGuide),
        const SizedBox(height: 24),
        if (task.scene == TaskScene.training) ...[
          TrainingSetupOptions(task: task, onChanged: () => setState(() {})),
          const SizedBox(height: 16),
        ],
        if (task.scene.competitive) ...[
          Text(tr('训练项目'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          CompetitionProjectPicker(task: task),
          const SizedBox(height: 16),
        ],
        if (task.scene == TaskScene.recovery) ...[
          Text(tr('恢复方法'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          RecoveryMethodPicker(
            value: task.recoveryMethod,
            enabled: !task.busy,
            onChanged: (value) => setState(() => task.recoveryMethod = value),
          ),
          const SizedBox(height: 16),
          Text(tr('恢复任务时长')),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final minutes in [3, 5])
                ChoiceChip(
                  label: Text(tr('{p0} 分钟', {'p0': minutes})),
                  selected: task.targetMinutes == minutes,
                  onSelected: task.busy
                      ? null
                      : (_) => setState(() => task.targetMinutes = minutes),
                ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        TextField(
          controller: name,
          enabled: !task.busy && !task.active,
          maxLength: 80,
          decoration: InputDecoration(labelText: tr('任务名称（可选）')),
          onChanged: (v) => task.name = v,
        ),
        const SizedBox(height: 16),
        if (task.scene != TaskScene.training)
          LearningFeedbackSettings(task: task),
        const SizedBox(height: 16),
        if (task.hasSavedReference)
          LearningReferencePreview(task: task)
        else
          LearningSection(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(
                    task.scene == TaskScene.learning
                        ? '首次学习前，请先建立个人基线。'
                        : '首次使用前，请先建立个人基线。',
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: task.busy || task.active
                      ? null
                      : _openLearningBaseline,
                  child: Text(tr('前往建立基线')),
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        if (task.scene.competitive) ...[
          CompetitionConditionSettings(task: task),
          const SizedBox(height: 16),
        ],
        if (task.busy)
          const LinearProgressIndicator()
        else if (!task.eeg.connected)
          LearningSection(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('请先连接头带。')),
                TextButton(
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => DevicePage(
                          controller: task.eeg,
                          ownsController: false,
                          overview: true,
                        ),
                      ),
                    );
                    if (mounted) await task.refresh();
                  },
                  child: Text(tr('连接设备')),
                ),
              ],
            ),
          )
        else if (task.hasSavedReference && !task.compatibleSavedReference)
          Text(tr('当前个人基线不可用，请到个人基线页面检查。'))
        else if (!task.eeg.receiving)
          Text(tr('正在等待脑电数据，请保持设备连接。'))
        else if (!task.storageReady)
          Text(tr('记录暂时无法保存，请重试。')),
        for (final row in task.unresolved)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('有未结束的任务，请先处理。')),
            trailing: TextButton(
              onPressed: task.busy
                  ? null
                  : () => task.resolve(row['id'] as String),
              child: Text(tr('结束并保存')),
            ),
          ),
        if (task.error != null)
          Text(
            trSource(task.error!),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (!task.canStartLearning && !task.busy)
          TextButton(onPressed: task.refresh, child: Text(tr('重新检查'))),
        const SizedBox(height: 20),
        Text(
          tr(
            task.scene == TaskScene.learning
                ? '不预设学习时长。返回首页会继续记录，结束时请点击结束并保存。'
                : task.scene == TaskScene.recovery
                ? '到达预设时长会自动保存，也可以手动结束。'
                : task.scene == TaskScene.training
                ? '游戏期间无打扰；完成后自动保存并展示专注曲线与训练表现，提前结束记为未完成。'
                : '不预设训练时长。返回首页会继续记录，结束时请点击结束并保存。',
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: task,
    builder: (context, _) => widget.baselineOnly
        ? _baselinePreparation(context)
        : _learningPreparation(context),
  );
}

class BaselinePage extends StatefulWidget {
  const BaselinePage({super.key, required this.task});
  final TaskController task;
  @override
  State<BaselinePage> createState() => _BaselinePageState();
}

class _BaselinePageState extends State<BaselinePage>
    with LanguageAware<BaselinePage> {
  bool leaving = false;
  @override
  void initState() {
    super.initState();
    widget.task.addListener(_completed);
  }

  @override
  void dispose() {
    widget.task.removeListener(_completed);
    super.dispose();
  }

  void _completed() {
    if (!widget.task.active && widget.task.completedSession != null) {
      if (widget.task.completedBaseline != null &&
          widget.task.completedBaseline!['state'] != 'ready') {
        return;
      }
      _leave(widget.task.completedSession!);
    }
  }

  void _leave(String id) {
    if (leaving || !mounted) return;
    final route = ModalRoute.of(context);
    setState(() => leaving = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Navigator.of(context).popUntil((r) => r == route);
        Navigator.of(context).pop(id);
      }
    });
  }

  bool _exitingInitialCheck = false;
  Future<void> exitInitialCheck() async {
    final task = widget.task;
    if (_exitingInitialCheck || task.busy || !task.unstartedLearning) return;
    _exitingInitialCheck = true;
    final discarded = await task.discardUnstartedLearning();
    if (!mounted) return;
    _exitingInitialCheck = false;
    if (discarded) Navigator.of(context).pop();
  }

  Future<void> end() async {
    final t = widget.task;
    if (t.busy ||
        !await confirm(
          context,
          t.baselineCancellable
              ? tr('取消本次基线采集？')
              : t.monitor == null
              ? tr('结束基线采集？')
              : tr('结束任务？'),
          t.baselineCancellable
              ? tr('本次尚未完成的基线不会保存，之前的有效基线不受影响。')
              : t.monitor != null && t.scene.competitive
              ? t.scene.endNotice
              : (t.monitor == null && t.baseline?.state != 'ready') ||
                    (t.scene == TaskScene.training &&
                        t.trainingGame?.finished != true) ||
                    (t.monitor != null &&
                        !t.monitor!.openEnded &&
                        !t.monitor!.finished)
              ? tr('提前结束会保存到未完成任务，已采集的数据保留。')
              : t.scene == TaskScene.learning
              ? tr('结束后保存本次学习曲线和分析。')
              : tr('保存本次采集、任务状态和已记录的事件。'),
        )) {
      return;
    }
    if (!t.active) return;
    if (t.baselineCancellable) {
      final cancelled = await t.cancelBaseline();
      if (mounted && cancelled) Navigator.of(context).pop();
      return;
    }
    final id = await t.finish();
    if (!mounted || id == null) return;
    _leave(id);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.task,
    builder: (context, _) {
      final t = widget.task, b = t.baseline;
      return PopScope(
        canPop: !t.initialLearningCheck,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && t.initialLearningCheck) exitInitialCheck();
        },
        child: Scaffold(
          appBar: AppBar(
            leading: t.initialLearningCheck
                ? BackButton(onPressed: exitInitialCheck)
                : null,
            actions: [
              IconButton(
                onPressed: t.initialLearningCheck
                    ? (t.busy ? null : exitInitialCheck)
                    : () => Navigator.of(context).pop(),
                icon: const Icon(Icons.home_outlined),
                tooltip: tr(t.initialLearningCheck ? '退出' : '返回首页，继续采集'),
              ),
            ],
            title: Text(
              t.usingSavedReference
                  ? t.learningPreparing
                        ? tr(t.scene == TaskScene.learning ? '学习任务准备' : '信号检查')
                        : tr(t.scene == TaskScene.recovery ? '主动恢复' : '实时监测')
                  : tr('个人基线'),
            ),
          ),
          bottomNavigationBar:
              t.active &&
                  t.baselineInterruption == null &&
                  !(t.usingSavedReference && t.learningPreparing) &&
                  (t.monitor == null || t.monitor!.phase == 'rebuilding')
              ? SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                    child: OutlinedButton(
                      onPressed: t.busy ? null : end,
                      child: Text(tr('结束采集')),
                    ),
                  ),
                )
              : null,
          body: t.usingSavedReference && t.learningPreparing
              ? LearningReadyPanel(
                  task: t,
                  onEnd: end,
                  onExit: exitInitialCheck,
                )
              : t.monitor != null &&
                    t.scene == TaskScene.training &&
                    t.trainingGame != null
              ? TrainingPanel(task: t, onEnd: end)
              : t.monitor != null &&
                    (t.recoveryChoosing ||
                        t.recoveryFlow != null ||
                        t.scene == TaskScene.recovery)
              ? t.scene == TaskScene.recovery
                    ? RecoveryLivePanel(task: t, onEnd: end)
                    : RecoveryPanel(task: t, onEnd: end)
              : t.monitor != null && t.monitor!.phase != 'rebuilding'
              ? MonitoringPanel(
                  task: t,
                  onEnd: end,
                  qualityText: qualityLabel(t.qualityReason),
                )
              : t.baselineInterruption != null
              ? ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    Text(
                      tr('需要重新采集'),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 16),
                    Text(baselineInterruptionLabel(t.baselineInterruption!)),
                    const SizedBox(height: 12),
                    if (!t.active) Text(tr('本次无效基线未保存，之前的有效基线不受影响。')),
                    if (t.active && t.busy) ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 12),
                      Text(tr('正在停止并清理本次记录…')),
                    ],
                    if (t.active && t.error != null)
                      Text(
                        trSource(t.error!),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: t.active
                          ? (t.busy ? null : t.cancelBaseline)
                          : () => Navigator.of(context).pop(),
                      child: Text(tr(t.active ? '重试清理本次记录' : '重新采集基线')),
                    ),
                  ],
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  children: [
                    Text(
                      b?.adapting == true ? tr('准备适应') : tr('正在采集个人基线'),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 16),
                    LinearProgressIndicator(value: b?.progress ?? 0),
                    const SizedBox(height: 12),
                    Text(
                      tr('已记录 {p0}', {'p0': taskTime(b?.attemptElapsed ?? 0)}),
                    ),
                    const SizedBox(height: 24),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              tr('默读内容'),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 12),
                            Text(tr('自然默读，读完后从头再读。')),
                            const SizedBox(height: 16),
                            Text(
                              tr(
                                '窗边放着一盆绿色植物，桌上有一本书、一支笔和一杯水。阳光慢慢照进房间，树叶随风轻轻摆动。翻开书页，文字沿着行间整齐排列。书架上摆着几本厚薄不同的书，浅色窗帘安静地垂在一旁。午后的光线移到桌角，杯壁映出一点柔和的亮光。有人沿着窗外的小路慢慢走过，几片新叶藏在较大的叶片下面。房间保持着平常的安静，桌面上的物品仍在原来的位置。请按照平常的节奏自然默读，不必记住每个细节。读完后可以从头再读，保持舒适坐姿和正常呼吸。',
                              ),
                              style: Theme.of(context).textTheme.bodyLarge
                                  ?.copyWith(fontSize: 18, height: 1.8),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (!t.eeg.connected ||
                        t.baselineAnomaly != null ||
                        b?.state == 'invalid') ...[
                      const SizedBox(height: 20),
                      Text(
                        !t.eeg.connected
                            ? tr('设备已断开，请检查连接。')
                            : t.baselineAnomaly != null
                            ? tr('信号持续异常，请检查头带与电极接触。')
                            : tr('采集已中断，请重新检查后采集。'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    if (b?.state == 'invalid')
                      OutlinedButton(
                        onPressed:
                            !t.busy && t.eeg.receiving && t.profile.usable
                            ? t.retry
                            : null,
                        child: Text(tr('重新采集基线')),
                      ),
                    if (t.error != null)
                      Text(
                        trSource(t.error!),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                ),
        ),
      );
    },
  );
}

class BaselineLibraryPage extends StatefulWidget {
  const BaselineLibraryPage({super.key, required this.task});
  final TaskController task;
  @override
  State<BaselineLibraryPage> createState() => _BaselineLibraryPageState();
}

class _BaselineLibraryPageState extends State<BaselineLibraryPage>
    with LanguageAware<BaselineLibraryPage> {
  TaskController get task => widget.task;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) task.refresh(prepareSignal: false);
    });
  }

  Future<void> record() async {
    if (task.active) return;
    task.clearDraft();
    task.name = tr('个人基线');
    await Navigator.of(context).push(
      MaterialPageRoute<String>(
        builder: (_) => TaskPreparation(task: task, baselineOnly: true),
      ),
    );
    if (mounted) await task.refresh(prepareSignal: false);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: task,
    builder: (context, _) {
      final saved = task.savedReference, snapshot = saved['snapshot'] as Map?;
      final stamp = saved['started'] as num?;
      return Scaffold(
        appBar: AppBar(title: Text(tr('个人基线'))),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(tr('首次使用前建立个人参考，之后可按需重新记录。')),
            const SizedBox(height: 16),
            if (task.hasSavedReference && snapshot != null) ...[
              Text(tr('当前个人参考'), style: Theme.of(context).textTheme.titleLarge),
              if (stamp != null)
                Text(
                  tr('建立于 {p0}', {
                    'p0': DateTime.fromMillisecondsSinceEpoch(
                      (stamp * 1000).round(),
                    ).toLocal().toString().substring(0, 19),
                  }),
                ),
              ExpansionTile(
                title: Text(tr('参考数据')),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  ReferenceMetrics(
                    showTechnicalDetails: false,
                    statistics: Map<String, dynamic>.from(
                      snapshot['statistics'] as Map? ?? {},
                    ),
                  ),
                ],
              ),
            ] else
              Text(tr('尚未建立个人基线')),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: task.busy || task.active ? null : record,
              child: Text(task.hasSavedReference ? tr('重新记录基线') : tr('建立个人基线')),
            ),
            if (task.active) Text(tr('请先结束当前记录，再重新记录个人基线。')),
            if (task.referenceLibrary.isNotEmpty) const SizedBox(height: 28),
            for (final item in task.referenceLibrary)
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  title: Text(
                    '${tr('已保存基线')} ${DateTime.fromMillisecondsSinceEpoch(((item['started'] as num? ?? 0) * 1000).round()).toLocal().toString().substring(0, 19)}',
                  ),
                  subtitle: Text(item['device'] as String? ?? ''),
                  trailing: item['id'] == task.savedReference['id']
                      ? Text(tr('当前生效'))
                      : TextButton(
                          onPressed: task.busy || task.active
                              ? null
                              : () =>
                                    task.selectReference(item['id'] as String),
                          child: Text(tr('设为当前')),
                        ),
                ),
              ),
            if (task.error != null)
              Text(
                trSource(task.error!),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      );
    },
  );
}

class LearningReadyPanel extends StatelessWidget {
  const LearningReadyPanel({
    super.key,
    required this.task,
    required this.onEnd,
    this.onExit,
  });
  final TaskController task;
  final VoidCallback onEnd;
  final VoidCallback? onExit;
  @override
  Widget build(BuildContext context) {
    if (task.usingSavedReference) {
      return Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              children: [
                LearningStageGuide(stage: 1, scene: task.scene),
                Text(
                  task.learningResuming ? tr('重新检查信号') : task.scene.readyLabel,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text(
                  tr(
                    task.learningResuming
                        ? '请重新确认头带佩戴，信号稳定后继续原任务。'
                        : task.scene == TaskScene.learning
                        ? '坐稳并保持自然呼吸。信号就绪后，点击开始学习。'
                        : task.scene == TaskScene.recovery
                        ? '坐稳并保持自然呼吸，信号就绪后开始恢复练习。'
                        : task.scene == TaskScene.training
                        ? '信号就绪后点击开始游戏，按规则完成目标；游戏期间保持静默。'
                        : '保持头带稳定，信号就绪后开始记录训练。',
                  ),
                ),
                const SizedBox(height: 24),
                LearningSignalCheck(task: task),
                if (task.scene == TaskScene.training) ...[
                  const SizedBox(height: 16),
                  LearningSection(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task.trainingKind.label,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(task.trainingKind.instructions),
                      ],
                    ),
                  ),
                ],

                if (task.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      trSource(task.error!),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (!task.canMonitor) ...[
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: task.busy ? null : task.prepareLearning,
                    child: Text(tr('重新检查信号')),
                  ),
                  if (!task.eeg.connected || !task.eeg.receiving)
                    TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => DevicePage(
                            controller: task.eeg,
                            ownsController: false,
                            overview: true,
                          ),
                        ),
                      ),
                      child: Text(tr('检查设备连接')),
                    ),
                ],
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton(
                    onPressed: task.canMonitor ? task.startMonitoring : null,
                    child: Text(
                      task.learningResuming
                          ? task.competitionPostStage
                                ? tr('继续监测')
                                : task.scene.resumeLabel
                          : task.scene.beginLabel,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: task.busy
                        ? null
                        : task.initialLearningCheck
                        ? onExit ??
                              () {
                                task.discardUnstartedLearning();
                              }
                        : onEnd,
                    child: Text(
                      task.initialLearningCheck ? tr('退出') : tr('结束并保存'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    final snapshot = task.baseline?.snapshot() ?? {},
        origin = snapshot['referenceOrigin'] as Map? ?? {};
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          task.name.isEmpty ? task.scene.label : task.name,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        Text(
          task.scene == TaskScene.training
              ? tr('准备脑波采集，信号就绪后开始游戏；游戏结束后展示曲线与简报。')
              : tr('使用已保存的个人基线，正在准备实时信号；无需重复默读采集。'),
        ),
        Text(tr('自动使用当前生效的个人参考；重新准备数据不会重算参考。')),
        if (task.scene.competitive) SceneControls(task: task),
        if (origin['collectedAt'] is num)
          Text(
            tr('基线建立于 {p0}', {
              'p0': DateTime.fromMillisecondsSinceEpoch(
                ((origin['collectedAt'] as num) * 1000).round(),
              ).toLocal().toString().substring(0, 19),
            }),
          ),
        Text(qualityLabel(task.qualityReason)),
        const SizedBox(height: 16),
        ReferenceMetrics(
          statistics: Map<String, dynamic>.from(
            snapshot['statistics'] as Map? ?? {},
          ),
        ),
        if (task.error != null)
          Text(
            trSource(task.error!),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        FilledButton(
          onPressed: task.canMonitor ? task.startMonitoring : null,
          child: Text(
            task.scene == TaskScene.training ? tr('开始游戏') : tr('开始监测'),
          ),
        ),
        TextButton(
          onPressed: task.busy ? null : task.prepareLearning,
          child: Text(tr('重新准备数据')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => DevicePage(
                controller: task.eeg,
                ownsController: false,
                overview: true,
              ),
            ),
          ),
          child: Text(tr('检查或恢复设备连接')),
        ),
        TextButton(
          onPressed: task.busy ? null : onEnd,
          child: Text(tr('结束并保存')),
        ),
      ],
    );
  }
}
