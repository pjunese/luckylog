import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:my_app/db/lotto_database.dart';
import 'package:my_app/services/purchase_insights_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory temp;
  late LottoDatabase db;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('insights-test-');
    db = LottoDatabase.forTesting(
      factory: databaseFactoryFfi,
      path: '${temp.path}/db',
    );
    await db.switchAccount('kakao:A');
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });
  test(
    'fixed prizes need no network; restore refreshes active records',
    () async {
      final id = await db.insertPurchaseHistory(
        games: [
          [1, 2, 3, 40, 41, 42],
        ],
        round: 1230,
        source: 'manual',
      );
      await db.insertDrawResult(
        round: 1230,
        numbers: [1, 2, 3, 4, 5, 6],
        bonus: 7,
      );
      var requests = 0;
      final c = PurchaseInsightsController(
        database: db,
        loadDetail: (_) async {
          requests++;
          return null;
        },
      );
      try {
        await c.refresh();
        expect(c.value.games.single.amount, 5000);
        expect(requests, 0);
        await db.deletePurchaseHistory(id);
        await c.refresh();
        expect(c.value.records, isEmpty);
        await db.restorePurchaseHistory(id);
        await c.refresh();
        expect(c.value.records, hasLength(1));
        expect(c.value.games.single.amount, 5000);
      } finally {
        c.dispose();
      }
    },
  );
  test(
    'late remote prize does not leak records after account change',
    () async {
      await db.insertPurchaseHistory(
        games: [
          [1, 2, 3, 4, 5, 6],
        ],
        round: 1230,
        source: 'manual',
      );
      await db.insertDrawResult(
        round: 1230,
        numbers: [1, 2, 3, 4, 5, 6],
        bonus: 7,
      );
      final started = Completer<void>();
      final gate = Completer<Map<String, dynamic>?>();
      var calls = 0;
      final c = PurchaseInsightsController(
        database: db,
        loadDetail: (_) {
          calls++;
          if (!started.isCompleted) started.complete();
          return gate.future;
        },
      );
      try {
        await started.future;
        expect(c.value.games.single.amount, isNull);
        await db.switchAccount('apple:B');
        expect(c.value.records, isEmpty);
        gate.complete({
          'prizes': {
            '1': {'perPrize': 2000000000},
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(c.value.records, isEmpty);
        expect(calls, 1);
      } finally {
        c.dispose();
      }
    },
  );
  test(
    'failed variable-prize reads are explicit and user retry can resolve them',
    () async {
      await db.insertPurchaseHistory(
        games: [
          [1, 2, 3, 4, 5, 6],
        ],
        round: 1230,
        source: 'qr',
      );
      await db.insertDrawResult(
        round: 1230,
        numbers: [1, 2, 3, 4, 5, 6],
        bonus: 7,
      );
      var available = false;
      final c = PurchaseInsightsController(
        database: db,
        loadDetail: (_) async => available
            ? {
                'prizes': {
                  '1': {'perPrize': 2000000},
                },
              }
            : null,
      );
      try {
        await c.refresh();
        expect(c.value.games.single.amount, isNull);
        available = true;
        await c.refresh(retryPrizes: true);
        expect(c.value.games.single.amount, 2000000);
      } finally {
        c.dispose();
      }
    },
  );
}
