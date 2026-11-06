import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurox/l10n/app_language.dart';
import 'package:neurox/features/tasks/reference_metrics.dart';
import 'package:neurox/features/shell/app_shell.dart';

void main() {
  for (final language in ['zh', 'en']) {
    testWidgets(
      '$language SDK values and reference fit compact large-text layout',
      (tester) async {
        AppLanguage.instance.resetForTest(language);
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      const ReferenceMetrics(
                        features: {'attention': 63, 'relax': 42},
                      ),
                      const ReferenceMetrics(
                        statistics: {
                          'attention': {'mean': 60, 'variance': 9},
                          'relax': {'mean': 40, 'variance': 4},
                        },
                      ),
                      BaselineHistorySummary(
                        row: {
                          'name': 'ORIGINAL USER NAME',
                          'task_json': jsonEncode({'minutes': 5}),
                          'attempts': [
                            {
                              'id': 'LEGACY',
                              'state': 'invalid',
                              'context_json': '{}',
                              'snapshot': jsonEncode({
                                'algorithm': 'neurox-welch-baseline-v1',
                                'statistics': {
                                  'ch1_alphaRelative': {
                                    'mean': .3,
                                    'variance': .01,
                                  },
                                },
                              }),
                            },
                          ],
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(
            language == 'en' ? 'SDK attention: 63.000' : 'SDK专注：63.000',
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            language == 'en'
                ? 'Relaxation baseline: 40.000 ± 2.000'
                : '放松基线：40.000 ± 2.000',
          ),
          findsOneWidget,
        );
        expect(find.text('ORIGINAL USER NAME'), findsOneWidget);
        expect(
          find.textContaining(language == 'en' ? 'Legacy baseline:' : '旧版基线：'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        AppLanguage.instance.resetForTest();
      },
    );
  }
}
