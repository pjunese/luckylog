import 'dart:io';
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
  Future<int> save() => db.insertNumberSet(
    games: [
      [1, 2, 3, 4, 5, 6],
    ],
    round: 1230,
  );

  test(
    'delete, restart, restore preserves numbers while leaving deletion terminal',
    () async {
      final id = await save();
      await db.updatePurchased(id, isPurchased: true);
      final original = (await db.getAllNumberSets()).single;
      await db.deleteNumberSet(id);
      await db.close();
      expect(await db.getAllNumberSets(), isEmpty);
      expect(await db.getDeletedNumberSets(), hasLength(1));
      final restoredId = await db.restoreNumberSet(id);
      final restored = (await db.getAllNumberSets()).single;
      expect(restored['id'], restoredId);
      for (final key in ['games', 'created_at', 'is_purchased', 'round']) {
        expect(restored[key], original[key]);
      }
      expect(restored['remote_id'], isNot(original['remote_id']));
      expect(await db.getDeletedNumberSets(), isEmpty);
      final deleted = (await (await db.db).query(
        'number_sets',
        where: 'id = ?',
        whereArgs: [id],
      )).single;
      expect(deleted['deleted'], 1);
      expect(await db.restoreNumberSet(id), isNull);
      await db.deleteNumberSet(restoredId!);
      expect((await db.getDeletedNumberSets()).single['id'], restoredId);
      expect(await db.restoreNumberSet(restoredId), isNotNull);
    },
  );
  test(
    'other account and guest cannot see or restore deleted records',
    () async {
      final id = await save();
      await db.deleteNumberSet(id);
      for (final owner in ['apple:B', null]) {
        await db.switchAccount(owner);
        expect(await db.getDeletedNumberSets(), isEmpty);
        expect(await db.restoreNumberSet(id), isNull);
        expect(await db.getAllNumberSets(), isEmpty);
      }
      await db.switchAccount('kakao:A');
      expect(await db.getDeletedNumberSets(), hasLength(1));
    },
  );
  test(
    'two devices restore the same remote ID and old deletion cannot remove the restored copy',
    () async {
      final id = await save();
      await db.deleteNumberSet(id);
      final tombstone = (await db.pendingChanges('kakao:A')).single;
      final remote = privateRecordFromRemote(
        'number_sets',
        tombstone.id,
        privateRecordToRemote(tombstone),
      )!;
      final other = LottoDatabase.forTesting(
        factory: databaseFactoryFfi,
        path: '${temp.path}/b.db',
      );
      try {
        await other.switchAccount('kakao:A');
        await other.applyRemoteRecords('kakao:A', 'number_sets', [remote]);
        final otherId =
            (await other.getDeletedNumberSets()).single['id'] as int;
        await Future.wait([
          db.restoreNumberSet(id),
          other.restoreNumberSet(otherId),
        ]);
        final a = (await db.getAllNumberSets()).single;
        final b = (await other.getAllNumberSets()).single;
        expect(a['remote_id'], b['remote_id']);
        await db.applyRemoteRecords('kakao:A', 'number_sets', [remote]);
        expect(await db.getAllNumberSets(), hasLength(1));
        expect(await db.getDeletedNumberSets(), isEmpty);
      } finally {
        await other.close();
      }
    },
  );
}
