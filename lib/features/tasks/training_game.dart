import 'dart:math' as math;
import '../../l10n/app_language.dart';

enum TrainingKind { obstacles, tracking, rings, hexagons }

extension TrainingDefinition on TrainingKind {
  String get label => trSource(switch (this) {
    TrainingKind.obstacles => '动态障碍舒尔特',
    TrainingKind.tracking => '视觉追踪',
    TrainingKind.rings => '旋转圆盘',
    TrainingKind.hexagons => '六边形舒尔特',
  });
  String get instructions => trSource(switch (this) {
    TrainingKind.obstacles => '按1到30顺序点击移动数字；三个障碍固定，数字碰到障碍和边界会反弹。限时120秒。',
    TrainingKind.tracking => '先记住画圈的目标球；圈消失后跟踪移动轨迹，所有球停下后点击原来的目标。',
    TrainingKind.rings => '四层圆盘相邻反向旋转，按1到36顺序点击随盘移动的数字。限时120秒。',
    TrainingKind.hexagons => '在48个六边形中按1到48顺序点击，下一目标有边框提示。限时180秒。',
  });
  int get count => switch (this) {
    TrainingKind.obstacles => 30,
    TrainingKind.rings => 36,
    TrainingKind.hexagons => 48,
    _ => 0,
  };
  double get limit => this == TrainingKind.hexagons
      ? 180
      : this == TrainingKind.tracking
      ? 0
      : 120;
}

class TrackingLevel {
  const TrackingLevel(
    this.label,
    this.count,
    this.targets,
    this.show,
    this.move,
    this.speed,
  );
  final String label;
  final int count, targets;
  final double show, move, speed;
  static const values = [
    TrackingLevel('简单', 8, 1, 1.2, 30, 180),
    TrackingLevel('普通', 10, 2, 1, 30, 200),
    TrackingLevel('困难', 14, 3, 1, 10, 220),
    TrackingLevel('大师', 18, 4, .9, 10, 250),
  ];
}

class GameToken {
  GameToken(
    this.value,
    this.x,
    this.y, {
    this.radius = 21,
    this.target = false,
  });
  final int value;
  double x, y, radius;
  double vx = 0,
      vy = 0,
      turn = 0,
      flashUntil = -1,
      wrongUntil = -1,
      baseAngle = 0,
      ringRadius = 0;
  int ring = 0;
  bool target, selected = false;
}

class GameObstacle {
  const GameObstacle(this.x, this.y, this.radius);
  final double x, y, radius;
}

/// Original Dart implementation of the public interaction rules, not embedded website code.
class TrainingGame {
  TrainingGame({required this.kind, this.level = 1, required this.seed})
    : _random = math.Random(seed) {
    if (level < 0 || level >= TrackingLevel.values.length) {
      throw ArgumentError('Invalid tracking level');
    }
    _setup();
  }
  final TrainingKind kind;
  final int level, seed;
  final math.Random _random;
  final tokens = <GameToken>[], obstacles = <GameObstacle>[];
  double elapsed = 0;
  int next = 1, mistakes = 0, correct = 0, attempts = 0;
  bool finished = false;
  String outcome = 'running';
  final ringSpeeds = [3.0, -4.5, 6.0, -7.5];
  final ringAngles = <double>[];
  double? firstResponseAt, lastResponseAt;
  TrackingLevel get difficulty => TrackingLevel.values[level];
  String get phase => kind != TrainingKind.tracking
      ? 'select'
      : elapsed < difficulty.show
      ? 'memorize'
      : elapsed < difficulty.show + difficulty.move
      ? 'moving'
      : 'select';
  int get goal =>
      kind == TrainingKind.tracking ? difficulty.targets : kind.count;
  double get remaining => kind.limit == 0
      ? math.max(0, difficulty.show + difficulty.move - elapsed)
      : math.max(0, kind.limit - elapsed);
  void _direction(GameToken token, double speed) {
    final angle = _random.nextDouble() * 2 * math.pi;
    token.vx = math.cos(angle) * speed;
    token.vy = math.sin(angle) * speed;
    token.turn = .3 + _random.nextDouble() * 1.8;
  }

  void _setup() {
    if (kind == TrainingKind.rings) {
      final numbers = List.generate(36, (i) => i + 1)..shuffle(_random);
      final counts = [5, 8, 10, 13], radii = [52.08, 114.0, 174.0, 234.0];
      var index = 0;
      for (var ring = 0; ring < 4; ring++) {
        ringAngles.add(_random.nextDouble() * math.pi * 2);
        for (var i = 0; i < counts[ring]; i++) {
          final token = GameToken(numbers[index++], 0, 0, radius: 22)
            ..ring = ring
            ..baseAngle = i / counts[ring] * math.pi * 2
            ..ringRadius = radii[ring];
          tokens.add(token);
        }
      }
      _rotate(0);
      return;
    }
    if (kind == TrainingKind.hexagons) {
      final cells = <({double x, double y, double distance})>[];
      for (var q = -4; q <= 4; q++) {
        for (var r = -4; r <= 4; r++) {
          if (q.abs() + r.abs() + (-q - r).abs() <= 8) {
            final x = 1.5 * q, y = math.sqrt(3) * (r + q / 2);
            cells.add((x: x, y: y, distance: math.sqrt(x * x + y * y)));
          }
        }
      }
      cells.sort((a, b) => a.distance.compareTo(b.distance));
      final selected = cells.take(48).toList();
      final radius = 572 / (2 * (selected.last.distance + 1));
      final numbers = List.generate(48, (i) => i + 1)..shuffle(_random);
      for (var i = 0; i < 48; i++) {
        tokens.add(
          GameToken(
            numbers[i],
            300 + selected[i].x * radius,
            300 + selected[i].y * radius,
            radius: radius,
          ),
        );
      }
      return;
    }
    if (kind == TrainingKind.obstacles) {
      obstacles.addAll([
        const GameObstacle(155, 170, 30),
        const GameObstacle(435, 200, 30),
        const GameObstacle(295, 435, 30),
      ]);
    }
    final count = kind == TrainingKind.tracking ? difficulty.count : 30;
    final numbers = List.generate(count, (i) => i + 1)..shuffle(_random);
    final targets = List.generate(count, (i) => i)..shuffle(_random);
    for (var i = 0; i < count; i++) {
      final radius = kind == TrainingKind.tracking ? 28.0 : 32.0;
      double x = 0, y = 0;
      var placed = false;
      for (var tries = 0; tries < 10000; tries++) {
        x = radius + _random.nextDouble() * (600 - 2 * radius);
        y = radius + _random.nextDouble() * (600 - 2 * radius);
        if (tokens.any(
          (t) => _distance(x, y, t.x, t.y) < radius + t.radius + 5,
        )) {
          continue;
        }
        if (obstacles.any(
          (o) => _distance(x, y, o.x, o.y) < radius + o.radius + 7,
        )) {
          continue;
        }
        placed = true;
        break;
      }
      if (!placed) throw StateError('Could not place training tokens');
      final token = GameToken(
        numbers[i],
        x,
        y,
        radius: radius,
        target:
            kind == TrainingKind.tracking &&
            targets.take(difficulty.targets).contains(i),
      );
      _direction(
        token,
        kind == TrainingKind.tracking
            ? difficulty.speed * (.6 + _random.nextDouble() * .8)
            : 10 + _random.nextDouble() * 14,
      );
      tokens.add(token);
    }
  }

  static double _distance(double x, double y, double xx, double yy) =>
      math.sqrt((x - xx) * (x - xx) + (y - yy) * (y - yy));
  void _rotate(double dt) {
    for (var i = 0; i < 4; i++) {
      ringAngles[i] += ringSpeeds[i] * math.pi / 180 * dt;
    }
    for (final token in tokens) {
      final angle = ringAngles[token.ring] + token.baseAngle;
      token.x = 300 + math.cos(angle) * token.ringRadius;
      token.y = 300 + math.sin(angle) * token.ringRadius;
    }
  }

  void _move(double dt) {
    for (final t in tokens) {
      t.turn -= dt;
      if (t.turn <= 0) {
        _direction(
          t,
          kind == TrainingKind.tracking
              ? math.sqrt(t.vx * t.vx + t.vy * t.vy)
              : 10 + _random.nextDouble() * 14,
        );
      }
      t.x += t.vx * dt;
      t.y += t.vy * dt;
      for (final o in obstacles) {
        final distance = _distance(t.x, t.y, o.x, o.y),
            minimum = t.radius + o.radius;
        if (distance < minimum && distance > .0001) {
          final nx = (t.x - o.x) / distance, ny = (t.y - o.y) / distance;
          t.x = o.x + nx * minimum;
          t.y = o.y + ny * minimum;
          final dot = t.vx * nx + t.vy * ny;
          t.vx -= 2 * dot * nx;
          t.vy -= 2 * dot * ny;
        }
      }
    }
    for (var i = 0; i < tokens.length; i++) {
      for (var j = i + 1; j < tokens.length; j++) {
        final a = tokens[i],
            b = tokens[j],
            distance = _distance(a.x, a.y, b.x, b.y),
            minimum = a.radius + b.radius + 4;
        if (distance < minimum && distance > .0001) {
          final nx = (b.x - a.x) / distance,
              ny = (b.y - a.y) / distance,
              push = (minimum - distance) / 2;
          a.x -= nx * push;
          a.y -= ny * push;
          b.x += nx * push;
          b.y += ny * push;
        }
      }
    }
    for (final t in tokens) {
      if (t.x < t.radius) {
        t.x = t.radius;
        t.vx = t.vx.abs();
      } else if (t.x > 600 - t.radius) {
        t.x = 600 - t.radius;
        t.vx = -t.vx.abs();
      }
      if (t.y < t.radius) {
        t.y = t.radius;
        t.vy = t.vy.abs();
      } else if (t.y > 600 - t.radius) {
        t.y = 600 - t.radius;
        t.vy = -t.vy.abs();
      }
    }
  }

  void advanceTo(double at) {
    if (finished || !at.isFinite || at < elapsed) return;
    final end = kind.limit > 0 ? math.min(at, kind.limit) : at;
    while (elapsed < end - .000001) {
      var step = math.min(1 / 30, end - elapsed);
      if (kind == TrainingKind.tracking &&
          elapsed < difficulty.show &&
          elapsed + step > difficulty.show) {
        step = difficulty.show - elapsed;
      }
      if (kind == TrainingKind.tracking &&
          elapsed < difficulty.show + difficulty.move &&
          elapsed + step > difficulty.show + difficulty.move) {
        step = difficulty.show + difficulty.move - elapsed;
      }
      final currentPhase = phase;
      if (kind == TrainingKind.rings) _rotate(step);
      if (kind == TrainingKind.obstacles ||
          kind == TrainingKind.tracking && currentPhase == 'moving') {
        _move(step);
      }
      elapsed += step;
    }
    elapsed = end;
    if (kind.limit > 0 && elapsed >= kind.limit) {
      finished = true;
      outcome = 'timeout';
    }
  }

  bool? tap(int value) {
    if (finished || phase != 'select') return null;
    final found = tokens.where((token) => token.value == value);
    if (found.isEmpty) return null;
    final token = found.first;
    if (kind == TrainingKind.tracking && token.selected) return null;
    if ([TrainingKind.rings, TrainingKind.hexagons].contains(kind) &&
        token.flashUntil > elapsed) {
      return null;
    }
    attempts++;
    firstResponseAt ??= elapsed;
    lastResponseAt = elapsed;
    final right = kind == TrainingKind.tracking ? token.target : value == next;
    if (right) {
      correct++;
      next++;
      token.flashUntil = elapsed + 1;
      if (kind == TrainingKind.tracking) token.selected = true;
    } else {
      mistakes++;
      token.wrongUntil = elapsed + .3;
      if (kind == TrainingKind.tracking) token.selected = true;
    }
    if (correct == goal) {
      finished = true;
      outcome = 'completed';
    }
    return right;
  }

  Map<String, dynamic> snapshot() => {
    'version': 'frontal-games-v1',
    'kind': kind.name,
    'level': level,
    'seed': seed,
    'phase': phase,
    'elapsed': elapsed,
    'limit': kind.limit,
    'goal': goal,
    'correct': correct,
    'mistakes': mistakes,
    'attempts': attempts,
    'accuracy': attempts > 0 ? correct / attempts : null,
    'finished': finished,
    'outcome': outcome,
    'responseSeconds':
        kind == TrainingKind.tracking &&
            elapsed >= difficulty.show + difficulty.move
        ? elapsed - difficulty.show - difficulty.move
        : null,
    'feedback':
        'silent; no sound, vibration, notification or EEG warning overlays',
  };
}
