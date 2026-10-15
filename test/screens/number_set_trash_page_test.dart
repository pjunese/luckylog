import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/models/number_set.dart';
import 'package:my_app/screens/number_set_trash_page.dart';

void main() {
  testWidgets(
    'restore disables repeat taps and removes the restored set from trash',
    (tester) async {
      var sets = [
        NumberSet(
          id: 1,
          games: [
            [1, 11, 21, 31, 41, 45],
          ],
          createdAt: DateTime(2026, 9, 22),
          isPurchased: false,
        ),
      ];
      var count = 0;
      final gate = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: NumberSetTrashPage(
            loadSets: () async => sets,
            restoreSet: (_) async {
              count++;
              await gate.future;
              sets = [];
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('복원'));
      await tester.pump();
      await tester.tap(find.text('복원'));
      expect(count, 1);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('휴지통이 비어 있습니다'), findsOneWidget);
      expect(find.text('번호세트를 보관함으로 복원했습니다.'), findsOneWidget);
    },
  );
  testWidgets('a failed restore leaves the ticket available to retry', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NumberSetTrashPage(
          loadSets: () async => [
            NumberSet(
              id: 1,
              games: [
                [1, 2, 3, 4, 5, 6],
              ],
              createdAt: DateTime(2026),
              isPurchased: false,
            ),
          ],
          restoreSet: (_) async => throw StateError('storage'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('복원'));
    await tester.pumpAndSettle();
    expect(find.text('복원'), findsOneWidget);
    expect(find.text('복원하지 못했어요. 다시 시도해주세요.'), findsOneWidget);
  });
}
