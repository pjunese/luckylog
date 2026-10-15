import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/db/lotto_database.dart';
import 'package:my_app/models/purchase_record.dart';
import 'package:my_app/models/scanned_ticket.dart';
import 'package:my_app/models/purchase_insights.dart';
import 'package:my_app/screens/home_tab.dart';
import 'package:my_app/screens/purchase_review_page.dart';
import 'package:my_app/widgets/monthly_record_card.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory temporary;
  late LottoDatabase database;
  final now = koreanCalendarDay();
  final monthRound =
      (DateTime.utc(
                now.year,
                now.month,
              ).difference(DateTime.utc(2002, 12, 7)).inDays /
              7)
          .ceil() +
      1;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('lotto-home-feature-');
    database = LottoDatabase.forTesting(
      factory: databaseFactoryFfi,
      path: '${temporary.path}/records.db',
    );
    await database.switchAccount('kakao:feature-test');
    await database.db;
  });

  tearDown(() async {
    await database.close();
    await temporary.delete(recursive: true);
  });

  Future<void> finishReads(WidgetTester tester) async {
    // SQLite performs real asynchronous IO, outside the widget fake clock.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();
  }

  testWidgets(
    'new public draw refreshes mounted summary without reopening app',
    (tester) async {
      final id = await tester.runAsync(
        () => database.insertPurchaseHistory(
          games: [
            [1, 2, 3, 4, 5, 6],
          ],
          round: monthRound,
          source: 'manual',
        ),
      );
      final rows = await tester.runAsync(database.getAllPurchaseHistory);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeTab(
              database: database,
              purchaseHistory: rows!.map(PurchaseRecord.fromDb).toList(),
              onSaveQrBatch: (_) async => const QrBatchSaveResult(
                insertedCount: 0,
                duplicateCount: 0,
                deletedCount: 0,
              ),
              onMarkResultsChecked: (_) async {},
              onNavigateToVault: (_) {},
            ),
          ),
        ),
      );
      await finishReads(tester);
      var card = tester.widget<MonthlyRecordCard>(
        find.byType(MonthlyRecordCard),
      );
      expect(card.summary.pendingGames, 1);
      expect(
        card.summary.games
            .where((g) => g.result != null && !g.record.isResultChecked)
            .length,
        0,
      );
      expect(
        (await tester.runAsync(
          database.getAllPurchaseHistory,
        ))!.single['result_checked_at'],
        isNull,
      );
      await tester.runAsync(
        () => database.insertDrawResult(
          round: monthRound,
          numbers: [1, 2, 3, 4, 5, 6],
          bonus: 7,
        ),
      );
      await finishReads(tester);
      card = tester.widget<MonthlyRecordCard>(find.byType(MonthlyRecordCard));
      expect(
        card.summary.games
            .where((g) => g.result != null && !g.record.isResultChecked)
            .length,
        1,
      );
      expect(card.summary.pendingGames, 0);
      expect(
        card.summary.games
            .where((g) => g.result != null && !g.record.isResultChecked)
            .map((g) => g.record.id)
            .toList(),
        [id],
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'review callback persists confirmation and refreshes home count',
    (tester) async {
      await tester.runAsync(() async {
        await database.insertPurchaseHistory(
          games: [
            [1, 2, 3, 4, 5, 6],
          ],
          round: monthRound,
          source: 'manual',
        );
        await database.insertDrawResult(
          round: monthRound,
          numbers: [1, 2, 3, 4, 5, 6],
          bonus: 7,
        );
      });
      final initial = await tester.runAsync(database.getAllPurchaseHistory);
      final records = ValueNotifier(
        initial!.map(PurchaseRecord.fromDb).toList(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<List<PurchaseRecord>>(
              valueListenable: records,
              builder: (_, current, _) => HomeTab(
                database: database,
                purchaseHistory: current,
                onSaveQrBatch: (_) async => const QrBatchSaveResult(
                  insertedCount: 0,
                  duplicateCount: 0,
                  deletedCount: 0,
                ),
                onMarkResultsChecked: (ids) async {
                  await database.markPurchaseResultsChecked(ids);
                  records.value = (await database.getAllPurchaseHistory())
                      .map(PurchaseRecord.fromDb)
                      .toList();
                },
                onNavigateToVault: (_) {},
              ),
            ),
          ),
        ),
      );
      await finishReads(tester);
      final card = tester.widget<MonthlyRecordCard>(
        find.byType(MonthlyRecordCard),
      );
      expect(
        card.summary.games
            .where((g) => g.result != null && !g.record.isResultChecked)
            .length,
        1,
      );
      // Follow the same route callback used by the visible summary action.
      await tester.ensureVisible(find.text('$monthRound'));
      await tester.tap(find.text('$monthRound'));
      await tester.pumpAndSettle();
      expect(find.byType(PurchaseReviewPage), findsOneWidget);
      final button = find.byKey(const Key('mark-purchase-results-checked'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await finishReads(tester);
      expect(
        (await tester.runAsync(
          database.getAllPurchaseHistory,
        ))!.single['result_checked_at'],
        isNotNull,
      );
      await tester.pageBack();
      await finishReads(tester);
      final refreshed = tester.widget<MonthlyRecordCard>(
        find.byType(MonthlyRecordCard),
      );
      expect(
        refreshed.summary.games.where((g) => g.record.isResultChecked).length,
        1,
      );
      expect(
        refreshed.summary.games
            .where((g) => g.result != null && !g.record.isResultChecked)
            .length,
        0,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      records.dispose();
    },
  );
}
