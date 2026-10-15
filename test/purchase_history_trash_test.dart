import 'dart:io';
import 'package:my_app/models/scanned_ticket.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/db/lotto_database.dart';
import 'package:my_app/data/private_record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory temp;
  late LottoDatabase db;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lotto-trash-');
    db = LottoDatabase.forTesting(
      factory: databaseFactoryFfi,
      path: '${temp.path}/a.db',
    );
    await db.switchAccount('kakao:A');
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });
  Future<int> save() => db.insertPurchaseHistory(
    games: [
      [1, 2, 3, 4, 5, 6],
    ],
    round: 1230,
    source: 'manual',
  );

  test(
    'delete, restart, restore preserves numbers while leaving deletion terminal',
    () async {
      final id = await save();
      await db.insertDrawResult(
        round: 1230,
        numbers: [1, 2, 3, 4, 5, 6],
        bonus: 7,
      );
      await db.markPurchaseResultsChecked([id]);
      final original = (await db.getAllPurchaseHistory()).single;
      await db.deletePurchaseHistory(id);
      await db.close();
      expect(await db.getAllPurchaseHistory(), isEmpty);
      expect(await db.getDeletedPurchaseHistory(), hasLength(1));
      final restoredId = await db.restorePurchaseHistory(id);
      final restored = (await db.getAllPurchaseHistory()).single;
      expect(restored['id'], restoredId);
      for (final key in [
        'games',
        'created_at',
        'source',
        'round',
        'draw_date',
        'result_checked_at',
      ]) {
        expect(restored[key], original[key]);
      }
      expect(restored['remote_id'], isNot(original['remote_id']));
      expect(await db.getDeletedPurchaseHistory(), isEmpty);
      final deleted = (await (await db.db).query(
        'purchase_history',
        where: 'id = ?',
        whereArgs: [id],
      )).single;
      expect(deleted['deleted'], 1);
      expect(await db.restorePurchaseHistory(id), isNull);
      await db.deletePurchaseHistory(restoredId!);
      expect((await db.getDeletedPurchaseHistory()).single['id'], restoredId);
      expect(await db.restorePurchaseHistory(restoredId), isNotNull);
    },
  );
  test(
    'other account and guest cannot see or restore deleted records',
    () async {
      final id = await save();
      await db.deletePurchaseHistory(id);
      for (final owner in ['apple:B', null]) {
        await db.switchAccount(owner);
        expect(await db.getDeletedPurchaseHistory(), isEmpty);
        expect(await db.restorePurchaseHistory(id), isNull);
        expect(await db.getAllPurchaseHistory(), isEmpty);
      }
      await db.switchAccount('kakao:A');
      expect(await db.getDeletedPurchaseHistory(), hasLength(1));
    },
  );
  test(
    'two devices restore the same remote ID and old deletion cannot remove the restored copy',
    () async {
      final id = await save();
      await db.deletePurchaseHistory(id);
      final tombstone = (await db.pendingChanges('kakao:A')).single;
      final remote = privateRecordFromRemote(
        'purchase_history',
        tombstone.id,
        privateRecordToRemote(tombstone),
      )!;
      final other = LottoDatabase.forTesting(
        factory: databaseFactoryFfi,
        path: '${temp.path}/b.db',
      );
      try {
        await other.switchAccount('kakao:A');
        await other.applyRemoteRecords('kakao:A', 'purchase_history', [remote]);
        final otherId =
            (await other.getDeletedPurchaseHistory()).single['id'] as int;
        await Future.wait([
          db.restorePurchaseHistory(id),
          other.restorePurchaseHistory(otherId),
        ]);
        final a = (await db.getAllPurchaseHistory()).single;
        final b = (await other.getAllPurchaseHistory()).single;
        expect(a['remote_id'], b['remote_id']);
        await db.applyRemoteRecords('kakao:A', 'purchase_history', [remote]);
        expect(await db.getAllPurchaseHistory(), hasLength(1));
        expect(await db.getDeletedPurchaseHistory(), isEmpty);
      } finally {
        await other.close();
      }
    },
  );
  test(
    'QR restore retains identity and checked state without allowing re-registration',
    () async {
      final ticket = ScannedTicket.tryParse('1230q0102030405060000000001')!;
      await db.insertQrPurchaseBatch([ticket]);
      final id = (await db.getAllPurchaseHistory()).single['id'] as int;
      await db.insertDrawResult(
        round: 1230,
        numbers: [1, 2, 3, 4, 5, 6],
        bonus: 7,
      );
      await db.markPurchaseResultsChecked([id]);
      final original = (await db.getAllPurchaseHistory()).single;
      await db.deletePurchaseHistory(id);
      final deletedScan = await db.insertQrPurchaseBatch([ticket]);
      expect(deletedScan.deletedCount, 1);
      final restoredId = await db.restorePurchaseHistory(id);
      final restored = (await db.getAllPurchaseHistory()).single;
      for (final key in [
        'games',
        'round',
        'draw_date',
        'source',
        'created_at',
        'qr_fingerprint',
        'result_checked_at',
      ]) {
        expect(restored[key], original[key]);
      }
      final repeat = await db.insertQrPurchaseBatch([ticket]);
      expect(repeat.insertedCount, 0);
      expect(repeat.duplicateCount, 1);
      expect(repeat.deletedCount, 0);
      expect(await db.getKnownQrFingerprints(), {ticket.fingerprint});
      final pending = (await db.pendingChanges(
        'kakao:A',
      )).singleWhere((r) => !r.deleted);
      final remote = privateRecordFromRemote(
        'purchase_history',
        pending.id,
        privateRecordToRemote(pending),
      )!;
      expect(remote.values['qr_fingerprint'], ticket.fingerprint);
      expect(remote.values['result_checked_at'], isNotNull);
      await db.deletePurchaseHistory(restoredId!);
      expect((await db.getDeletedPurchaseHistory()).single['id'], restoredId);
      await db.restorePurchaseHistory(restoredId);
      expect(await db.getAllPurchaseHistory(), hasLength(1));
      expect(await db.getDeletedPurchaseHistory(), isEmpty);
    },
  );
}
