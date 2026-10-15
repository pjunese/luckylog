import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/models/purchase_record.dart';
import 'package:my_app/screens/purchase_history_trash_page.dart';

void main() {
  testWidgets(
    'restore disables repeat taps and removes the restored set from trash',
    (tester) async {
      var sets = [
        PurchaseRecord(
          id: 1,
          games: [
            [1, 11, 21, 31, 41, 45],
          ],
          createdAt: DateTime(2026, 9, 22),
          round: 1230,
          drawDate: '2026-09-26',
          source: 'qr',
        ),
      ];
      var count = 0;
      final gate = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: PurchaseHistoryTrashPage(
            loadRecords: () async => sets,
            restoreRecord: (_) async {
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
      expect(find.text('구매내역을 복원했습니다.'), findsOneWidget);
    },
  );
  testWidgets('a failed restore leaves the ticket available to retry', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PurchaseHistoryTrashPage(
          loadRecords: () async => [
            PurchaseRecord(
              id: 1,
              games: [
                [1, 2, 3, 4, 5, 6],
              ],
              createdAt: DateTime(2026),
              round: 1230,
              drawDate: '2026-09-26',
              source: 'qr',
            ),
          ],
          restoreRecord: (_) async => throw StateError('storage'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('복원'));
    await tester.pumpAndSettle();
    expect(find.text('복원'), findsOneWidget);
    expect(find.text('1230회 · 1게임 · QR'), findsOneWidget);
    expect(find.text('복원하지 못했어요. 다시 시도해주세요.'), findsOneWidget);
  });
  testWidgets('empty trash stays accessible and load failures can be retried', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PurchaseHistoryTrashPage(
          loadRecords: () async {
            if (++attempts == 1) throw StateError('storage');
            return [];
          },
          restoreRecord: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('다시 불러오기'));
    await tester.pumpAndSettle();
    expect(find.text('휴지통이 비어 있습니다'), findsOneWidget);
  });
}
