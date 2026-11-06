import 'package:flutter/material.dart';
import '../../l10n/app_language.dart';

class ReportInsights extends StatelessWidget {
  const ReportInsights({super.key, required this.lines, required this.notes});
  final List<String> lines, notes;
  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: Text(tr('趋势与统计说明')),
    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    children: [
      for (final line in lines)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Align(alignment: Alignment.centerLeft, child: Text(line)),
        ),
      ExpansionTile(
        title: Text(tr('统计口径')),
        tilePadding: EdgeInsets.zero,
        children: [
          for (final note in notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Align(alignment: Alignment.centerLeft, child: Text(note)),
            ),
        ],
      ),
    ],
  );
}
