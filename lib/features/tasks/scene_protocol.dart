import '../../l10n/app_language.dart';

/// Versioned engineering presets, not measures of sporting ability.
enum TaskScene { learning, esports, go, archery, recovery, training }

extension SceneProtocol on TaskScene {
  String get label => trSource(switch (this) {
    TaskScene.learning => '学习场景',
    TaskScene.esports => '电竞比赛',
    TaskScene.go => '围棋对局',
    TaskScene.archery => '射箭训练',
    TaskScene.recovery => '主动恢复',
    TaskScene.training => '专注训练任务',
  });
  String get endLabel => trSource(switch (this) {
    TaskScene.esports => '结束比赛',
    TaskScene.go => '结束对局',
    TaskScene.archery => '结束训练',
    _ => '结束并保存',
  });
  String get endQuestion => trSource(switch (this) {
    TaskScene.esports => '确定结束比赛？',
    TaskScene.go => '确定结束对局？',
    TaskScene.archery => '确定结束训练？',
    _ => '结束任务？',
  });
  String get endNotice => tr('结束后将保存本次记录，无法继续本次任务。');
  String get preparationLabel => trSource(
    this == TaskScene.learning
        ? '准备学习'
        : this == TaskScene.recovery
        ? '准备恢复'
        : this == TaskScene.training
        ? '准备专注训练'
        : '准备训练',
  );
  String get prepareButtonLabel => trSource(
    this == TaskScene.learning
        ? '准备学习任务'
        : this == TaskScene.recovery
        ? '准备恢复任务'
        : '准备训练任务',
  );
  String get beginLabel => trSource(
    this == TaskScene.learning
        ? '开始学习'
        : this == TaskScene.recovery
        ? '开始恢复练习'
        : this == TaskScene.training
        ? '开始游戏'
        : '开始训练',
  );
  String get resumeLabel => trSource(
    this == TaskScene.learning
        ? '继续学习'
        : this == TaskScene.recovery
        ? '继续恢复'
        : this == TaskScene.training
        ? '继续游戏'
        : '继续训练',
  );
  String get readyLabel => trSource(
    this == TaskScene.learning
        ? '准备开始学习'
        : this == TaskScene.recovery
        ? '准备开始恢复'
        : this == TaskScene.training
        ? '准备开始游戏'
        : '准备开始训练',
  );
  String get setupGuide => trSource(
    this == TaskScene.learning
        ? '戴好头带，按平时的习惯阅读或学习。下一步检查信号，就绪后由你开始计时。'
        : this == TaskScene.recovery
        ? '选择一种恢复方法，先检查信号，再按示范、跟随练习和自主练习逐步进行。'
        : this == TaskScene.training
        ? '选择小游戏并了解规则，戴好头带。下一步检查信号，准备好后由你开始游戏。'
        : '选择训练项目，戴好头带。下一步检查信号，就绪后按项目阶段记录。',
  );
  String get postStage =>
      this == TaskScene.archery ? 'post_training' : 'post_match';
  bool get competitive =>
      [TaskScene.esports, TaskScene.go, TaskScene.archery].contains(this);
  int get deviationSeconds => competitive ? 10 : 25;
  int get recoverySeconds => competitive ? 15 : 10;
  List<String> get stages => switch (this) {
    TaskScene.learning => ['study'],
    TaskScene.training => ['game'],
    TaskScene.esports => ['preparation', 'match', 'interval', 'post_match'],
    TaskScene.go => ['preparation', 'thinking', 'interval', 'post_match'],
    TaskScene.archery => [
      'preparation',
      'shooting',
      'aiming',
      'release',
      'interval',
      'post_training',
    ],
    TaskScene.recovery => ['demonstration', 'guided', 'independent'],
  };
  Map<String, dynamic> toMap() => {
    'version': 'scene-protocol-v1',
    'scene': name,
    'deviationSeconds': deviationSeconds,
    'recoverySeconds': recoverySeconds,
    'evidence':
        'engineering preset; project-specific effectiveness unvalidated',
    'comparisonCondition':
        'same eyes-open seated reading/observation as reference',
  };
}

String stageLabel(String value) => trSource(switch (value) {
  'study' => '持续学习',
  'game' => '游戏中',
  'preparation' => '静态准备',
  'match' => '比赛中',
  'thinking' => '思考中',
  'shooting' => '射箭动作',
  'aiming' => '瞄准',
  'release' => '释放／随动',
  'interval' => '轮间／间歇',
  'post' => '练后复查',
  'ended' => '结束阶段',
  'post_match' => '赛后阶段',
  'post_training' => '训练后阶段',
  'demonstration' => '方法示范',
  'guided' => '跟随引导',
  'independent' => '自主练习',
  'recheck' => '返回任务复查',
  _ => value,
});

bool isFocusScene(String? scene) =>
    ['learning', 'esports', 'go', 'archery'].contains(scene);

bool hasCompactTaskDetails(String? scene) =>
    isFocusScene(scene) || ['training', 'recovery'].contains(scene);
