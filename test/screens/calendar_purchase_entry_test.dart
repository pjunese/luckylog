import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:my_app/db/lotto_database.dart';
import 'package:my_app/screens/calendar_purchase_entry_page.dart';
import 'package:my_app/services/purchase_insights_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory temp;
  late LottoDatabase db;
  late PurchaseInsightsController controller;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('calendar-entry-');
    db = LottoDatabase.forTesting(
      factory: databaseFactoryFfi,
      path: '${temp.path}/db',
    );
    await db.switchAccount('kakao:A');
    controller = PurchaseInsightsController(
      database: db,
      loadDetail: (_) async => null,
    );
    await controller.refresh();
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });
  testWidgets('pick numbers and save purchase with selected calendar day', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => CalendarPurchaseEntryPage(
                    day: DateTime.utc(2026, 9, 2),
                    controller: controller,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.tap(find.text('번호 선택'));
    await tester.pumpAndSettle();
    for (final n in [1, 2, 3, 4, 5, 6]) {
      await tester.tap(find.text('$n'));
      await tester.pump();
    }
    await tester.tap(find.text('적용'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1게임 구매 등록'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
    final rows = await tester.runAsync(db.getAllPurchaseHistory);
    expect(rows, hasLength(1));
    expect(rows!.single['purchase_date'], '2026-09-02');
    expect(rows.single['games'], '[[1,2,3,4,5,6]]');
    expect(tester.takeException(), isNull);
  });
}
