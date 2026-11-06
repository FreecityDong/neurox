import '../../l10n/app_language.dart';

/// Teaching progress is explicit; never inferred from a high relaxation score.
class RecoveryFlow {
  RecoveryFlow({
    required this.method,
    required this.linked,
    required this.startedAt,
  });
  final String method;
  final bool linked;
  final double startedAt;
  int step = 0;
  double stepStartedAt = 0;
  bool paused = false;
  int? readinessBefore, readinessAfter;
  static const stages = ['demonstration', 'guided', 'independent', 'recheck'];
  List<String> get steps => linked ? stages : stages.sublist(0, 3);
  String get stage => steps[step];
  String get instruction => trSource(switch ((method, step)) {
    ('breathing', 0) => '保持自然呼吸，轻松吸气和呼气，不屏息；不舒服时停止引导。',
    ('breathing', 1) => '轻松吸气约4秒、呼气约6秒；以舒适为准，可以按自己的节奏。',
    ('breathing', 2) => '减少对文字的依赖，按舒适节奏自行呼吸，把注意带回当前动作。',
    ('attention', 0) => '选一个眼前的固定目标，自然观察；察觉注意偏移后，再轻轻带回来。',
    ('attention', 1) => '观察目标的形状与细节。走神时不评判自己，把注意带回目标。',
    ('attention', 2) => '自行完成观察与注意返回，练习不依赖提示。',
    (_, 0) => '放松肩颈与下颌，调整舒适坐姿；准备好后开始练习。',
    (_, 1) => '依次留意肩膀、手臂和下颌，轻轻放松，保持自然呼吸。',
    (_, 2) => '减少引导，自行检查身体姿势与紧绷部位，按需要放松。',
    _ => '恢复原来的睁眼坐姿与观察条件，再查看指标是否持续回到个人参考附近。',
  });
  bool next(double at) {
    if (step >= steps.length - 1) return false;
    step++;
    stepStartedAt = at;
    return true;
  }

  Map<String, dynamic> toMap() => {
    'version': linked ? 'recovery-teaching-v1' : 'recovery-teaching-v2',
    'steps': steps,
    'method': method,
    'linked': linked,
    'stage': stage,
    'readinessBefore': readinessBefore,
    'readinessAfter': readinessAfter,
  };
}
