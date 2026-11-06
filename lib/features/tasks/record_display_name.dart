import '../../l10n/app_language.dart';
import '../../l10n/messages_en.dart';

// Legacy records stored generated titles in the language used at creation.
// Match whole known default titles only; never translate arbitrary user text.
const _defaultRecordNames = {
  '个人基线',
  '基线任务',
  '学习任务',
  '学习场景',
  '专注训练任务',
  '专注训练',
  '电竞比赛',
  '围棋对局',
  '射箭训练',
  '竞技／运动训练',
  '主动恢复',
};

String recordDisplayName(Map row) {
  final name = row['name'] as String? ?? '';
  if (name.isEmpty) return tr('未命名任务');
  if (!['task', 'baseline'].contains(row['kind'])) return name;
  final replay = name.startsWith('[Replay] ');
  final title = replay ? name.substring('[Replay] '.length) : name;
  final key = _defaultRecordNames
      .where((key) => title == key || title == englishMessages[key])
      .firstOrNull;
  final displayed = key == null ? title : trSource(key);
  return replay ? '[Replay] $displayed' : displayed;
}
