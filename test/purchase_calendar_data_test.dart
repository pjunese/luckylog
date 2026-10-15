import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:my_app/db/lotto_database.dart';
import 'package:my_app/data/private_record.dart';
import 'package:my_app/models/draw_result.dart';
import 'package:my_app/models/purchase_calendar.dart';
import 'package:my_app/models/purchase_date.dart';
import 'package:my_app/models/purchase_insights.dart';
import 'package:my_app/models/purchase_record.dart';
import 'package:my_app/models/scanned_ticket.dart';
import 'package:my_app/services/purchase_insights_controller.dart';

final drawDay = DateTime.utc(2026, 9, 5);
final round = drawDay.difference(DateTime.utc(2002, 12, 7)).inDays ~/ 7 + 1;
const games = [
  [1, 2, 3, 40, 41, 42],
];
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory temp;
  late LottoDatabase db;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('calendar-data-');
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
  test('purchases and winnings use separate dates across month boundary', () {
    final record = PurchaseRecord(
      id: 1,
      games: games,
      round: round,
      drawDate: 'ignored',
      source: 'qr',
      createdAt: DateTime.utc(2026, 9, 10),
      purchaseDate: DateTime.utc(2026, 8, 31),
    );
    final data = PurchaseInsights(
      records: [record],
      draws: {
        round: DrawResult(
          round: round,
          winningNumbers: [1, 2, 3, 4, 5, 6],
          bonusNumber: 7,
          drawDate: 'ignored',
        ),
      },
    );
    final august = CalendarMonthSummary(
      insights: data,
      month: DateTime.utc(2026, 8),
    );
    final september = CalendarMonthSummary(insights: data, month: drawDay);
    expect(august.spent, 1000);
    expect(august.winCount, 0);
    expect(september.spent, 0);
    expect(september.winCount, 1);
    expect(september.knownPrize, 5000);
    expect(september.day(drawDay).wins, hasLength(1));
    expect(august.day(DateTime.utc(2026, 8, 31)).purchases, hasLength(1));
  });
  test(
    'legacy registration day uses Korean date and invalid dates are rejected',
    () {
      final record = PurchaseRecord(
        id: 1,
        games: games,
        round: round,
        drawDate: '',
        source: 'manual',
        createdAt: DateTime.utc(2026, 8, 31, 15),
      );
      expect(calendarPurchaseDay(record), DateTime.utc(2026, 9, 1));
      expect(parsePurchaseDate('2026-02-30'), isNull);
      expect(parsePurchaseDate('2026-9-1'), isNull);
      expect(parsePurchaseDate('2024-02-29'), DateTime.utc(2024, 2, 29));
    },
  );
  test(
    'date merge converges and older clients cannot erase explicit dates',
    () {
      const t = '2026-09-20T00:00:00.000Z';
      final a = mergePurchaseDateFields('2026-09-01', t, '2026-09-02', t);
      final b = mergePurchaseDateFields('2026-09-02', t, '2026-09-01', t);
      expect(a, b);
      expect(a['purchase_date'], '2026-09-02');
      expect(mergePurchaseDateFields(null, null, '2026-09-02', t), b);
      expect(
        mergePurchaseDateFields(
          '2026-09-03',
          '2026-09-21T00:00:00Z',
          '2026-09-02',
          t,
        )['purchase_date'],
        '2026-09-03',
      );
    },
  );
  test(
    'v4 migration preserves records and leaves unknown purchase dates empty',
    () async {
      await db.insertPurchaseHistory(
        games: games,
        round: round,
        source: 'manual',
      );
      final before =
          Map<String, dynamic>.of((await db.getAllPurchaseHistory()).single)
            ..remove('purchase_date')
            ..remove('purchase_date_updated_at');
      final raw = await db.db;
      await raw.execute(
        'ALTER TABLE purchase_history DROP COLUMN purchase_date',
      );
      await raw.execute(
        'ALTER TABLE purchase_history DROP COLUMN purchase_date_updated_at',
      );
      await raw.setVersion(4);
      await db.close();
      db = LottoDatabase.forTesting(
        factory: databaseFactoryFfi,
        path: '${temp.path}/db',
      );
      await db.switchAccount('kakao:A');
      final after = Map<String, dynamic>.of(
        (await db.getAllPurchaseHistory()).single,
      );
      expect(after.remove('purchase_date'), isNull);
      expect(after.remove('purchase_date_updated_at'), isNull);
      expect(after, before);
      expect(await (await db.db).getVersion(), 5);
    },
  );
  test(
    'edit increments revision, survives restore, and is isolated by account',
    () async {
      final id = await db.insertPurchaseHistory(
        games: games,
        round: round,
        source: 'manual',
        purchaseDate: DateTime.utc(2026, 9, 1),
      );
      final before = (await db.getAllPurchaseHistory()).single;
      await db.updatePurchaseDate(id, DateTime.utc(2026, 8, 31));
      var row = (await db.getAllPurchaseHistory()).single;
      expect(row['purchase_date'], '2026-08-31');
      expect(row['local_revision'], (before['local_revision'] as int) + 1);
      expect(row['dirty'], 1);
      await expectLater(
        db.updatePurchaseDate(id, DateTime.utc(2026, 9, 6)),
        throwsArgumentError,
      );
      await db.switchAccount('apple:B');
      await expectLater(
        db.updatePurchaseDate(id, DateTime.utc(2026, 9, 2)),
        throwsStateError,
      );
      await db.switchAccount('kakao:A');
      await db.deletePurchaseHistory(id);
      await expectLater(
        db.updatePurchaseDate(id, DateTime.utc(2026, 9, 2)),
        throwsStateError,
      );
      await db.restorePurchaseHistory(id);
      row = (await db.getAllPurchaseHistory()).single;
      expect(row['purchase_date'], '2026-08-31');
    },
  );
  test(
    'remote round trip, dirty merge and legacy pull keep newest purchase date',
    () async {
      await db.insertPurchaseHistory(
        games: games,
        round: round,
        source: 'manual',
        purchaseDate: DateTime.utc(2026, 9, 1),
      );
      final pending = (await db.pendingChanges('kakao:A')).single;
      final wire = privateRecordToRemote(pending);
      final remote = privateRecordFromRemote(
        'purchase_history',
        pending.id,
        wire,
      )!;
      expect(remote.values['purchase_date'], '2026-09-01');
      final newer = {
        ...wire,
        'purchaseDate': '2026-09-02',
        'purchaseDateUpdatedAt': '2099-01-01T00:00:00Z',
      };
      await db.applyRemoteRecords('kakao:A', 'purchase_history', [
        privateRecordFromRemote('purchase_history', pending.id, newer)!,
      ]);
      var row = (await db.getAllPurchaseHistory()).single;
      expect(row['purchase_date'], '2026-09-02');
      expect(row['dirty'], 1);
      final legacy = {...wire}
        ..remove('purchaseDate')
        ..remove('purchaseDateUpdatedAt');
      await db.acknowledgeUpload(
        'kakao:A',
        PendingPrivateRecord('purchase_history', row),
        remoteDeleted: false,
      );
      await db.applyRemoteRecords('kakao:A', 'purchase_history', [
        privateRecordFromRemote('purchase_history', pending.id, legacy)!,
      ]);
      row = (await db.getAllPurchaseHistory()).single;
      expect(row['purchase_date'], '2026-09-02');
      expect(
        privateRecordToRemote(
          PendingPrivateRecord('purchase_history', {
            ...row,
            'purchase_date': null,
            'purchase_date_updated_at': null,
          }),
          existing: newer,
        )['purchaseDate'],
        '2026-09-02',
      );
    },
  );
  test(
    'calendar controller saves manual and QR dates, updates snapshot and sync callback',
    () async {
      var saves = 0;
      final c = PurchaseInsightsController(
        database: db,
        loadDetail: (_) async => null,
        onRecordsChanged: () => saves++,
      );
      try {
        await c.addPurchase(games, round, DateTime.utc(2026, 9, 1));
        expect(c.value.records.single.purchaseDate, DateTime.utc(2026, 9, 1));
        await c.changePurchaseDate(
          c.value.records.single.id,
          DateTime.utc(2026, 9, 2),
        );
        final ticket = ScannedTicket.tryParse(
          '${round}q0102030405060000000001',
        )!;
        final result = await c.addQrPurchases([
          ticket,
        ], DateTime.utc(2026, 9, 3));
        expect(result.insertedCount, 1);
        expect(c.value.records, hasLength(2));
        expect(saves, 3);
        final duplicate = await c.addQrPurchases([
          ticket,
        ], DateTime.utc(2026, 9, 4));
        expect(duplicate.duplicateCount, 1);
        expect(
          c.value.records.where((r) => r.source == 'qr').single.purchaseDate,
          DateTime.utc(2026, 9, 3),
        );
        await db.switchAccount('apple:B');
        await expectLater(
          c.addPurchase(games, round, DateTime.utc(2026, 9, 1)),
          throwsStateError,
        );
        expect(await db.getAllPurchaseHistory(), isEmpty);
      } finally {
        c.dispose();
      }
    },
  );
}
