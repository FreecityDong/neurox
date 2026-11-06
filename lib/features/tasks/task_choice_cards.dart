import 'package:flutter/material.dart';
import '../../l10n/app_language.dart';

class TaskChoiceCards<T> extends StatelessWidget {
  const TaskChoiceCards({
    super.key,
    required this.value,
    required this.onChanged,
    required this.options,
    required this.keyPrefix,
    required this.optionKey,
    this.enabled = true,
    this.maxColumns = 3,
  });
  final T value;
  final ValueChanged<T> onChanged;
  final List<(T, String, IconData)> options;
  final String keyPrefix;
  final String Function(T) optionKey;
  final bool enabled;
  final int maxColumns;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final scale = MediaQuery.textScalerOf(context).scale(1);
      final preferredColumns = box.maxWidth >= 340 && scale < 1.25
          ? 3
          : box.maxWidth >= 280
          ? 2
          : 1;
      final columns = preferredColumns > maxColumns
          ? maxColumns
          : preferredColumns;
      final colors = Theme.of(context).colorScheme;
      final width = (box.maxWidth - 12 * (columns - 1)) / columns;
      var height = 146.0;
      for (final method in options) {
        final text = TextPainter(
          text: TextSpan(
            text: trSource(method.$2),
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: width - 24);
        final requiredHeight = text.height + 28 + 12 + 24 + 12;
        if (requiredHeight > height) height = requiredHeight;
        text.dispose();
      }
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final item in options)
            SizedBox(
              width: width,
              height: height,
              child: Semantics(
                button: true,
                selected: value == item.$1,
                enabled: enabled,
                child: Material(
                  color: value == item.$1
                      ? colors.primaryContainer
                      : colors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                    side: BorderSide(
                      color: value == item.$1
                          ? colors.primary
                          : colors.outlineVariant,
                      width: value == item.$1 ? 2 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: ValueKey('$keyPrefix-${optionKey(item.$1)}'),
                    onTap: enabled ? () => onChanged(item.$1) : null,
                    child: Stack(
                      children: [
                        if (value == item.$1)
                          Positioned(
                            top: 8,
                            right: 8,
                            child: Icon(
                              Icons.check_circle,
                              color: colors.primary,
                              size: 18,
                            ),
                          ),
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(item.$3, size: 28, color: colors.primary),
                                const SizedBox(height: 12),
                                Text(
                                  trSource(item.$2),
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(
                                        fontWeight: value == item.$1
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}
