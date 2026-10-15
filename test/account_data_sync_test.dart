import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/data/account_data_sync_engine.dart';
import 'package:my_app/data/private_record.dart';
import 'package:my_app/db/lotto_database.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const games = [
  [1, 2, 3, 4, 5, 6],
];
const otherGames = [
  [7, 8, 9, 10, 11, 12],
];
const ownerA = 'kakao:A';
const ownerB = 'apple:B';

Map<String, dynamic> setValues({bool purchased = false}) => {
  'games': jsonEncode(games),
  'created_at': '2026-08-30T10:00:00.000',
  'is_purchased': purchased ? 1 : 0,
  'round': 1234,
  'qr_raw': null,
};

class FakeRemote implements PrivateRecordRemote {
  final records = <String, Map<String, RemotePrivateRecord>>{};
  final writes = <String>[];
  final pulls = <int?>[];
  int clock = 1;
  bool failNext = false;
  Completer<void>? started;
  Completer<void>? release;
  String key(String owner, String collection) => '$owner/$collection';
  Map<String, RemotePrivateRecord> collection(
    String owner,
    String collection,
  ) => records.putIfAbsent(key(owner, collection), () => {});

  @override
  Future<List<RemotePrivateRecord>> pull(
    String owner,
    String name,
    int? sinceMicros,
  ) async {
    pulls.add(sinceMicros);
    return collection(owner, name).values
        .where(
          (record) =>
              sinceMicros == null ||
              (record.updatedAtMicros ?? 0) >= sinceMicros,
        )
        .toList();
  }

  @override
  Future<bool> push(
    String owner,
    PendingPrivateRecord change,
    bool Function() isActive,
  ) async {
    if (failNext) {
      failNext = false;
      throw StateError('offline');
    }
    final barrier = release;
    if (barrier != null) {
      release = null;
      started!.complete();
      await barrier.future;
    }
    if (!isActive()) throw StateError('account changed');
    final docs = collection(owner, change.collection);
    if (docs[change.id]?.deleted == true) return true;
    final values = Map<String, dynamic>.from(change.row)
      ..removeWhere(
        (key, value) => [
          'id',
          'owner_key',
          'remote_id',
          'dirty',
          'local_revision',
          'deleted',
          'claimed_by',
        ].contains(key),
      );
    docs[change.id] = RemotePrivateRecord(
      id: change.id,
      values: values,
      deleted: change.deleted,
      updatedAtMicros: clock++,
    );
    writes.add('$owner/${change.collection}/${change.id}');
    return change.deleted;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory temporary;
  final databases = <LottoDatabase>[];

  LottoDatabase device(String name) {
    final database = LottoDatabase.forTesting(
      factory: databaseFactoryFfi,
      path: path.join(temporary.path, '$name.db'),
    );
    databases.add(database);
    return database;
  }

  AccountDataSyncEngine engine(LottoDatabase database, FakeRemote remote) =>
      AccountDataSyncEngine(
        database: database,
        remote: remote,
        isOwnerActive: (owner) => database.accountKey == owner,
      );

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('lotto-sync-test-');
  });
  tearDown(() async {
    for (final database in databases) {
      await database.close();
    }
    databases.clear();
    await temporary.delete(recursive: true);
  });

  Future<void> legacy(String name, int version) async {
    final old = await databaseFactoryFfi.openDatabase(
      path.join(temporary.path, '$name.db'),
      options: OpenDatabaseOptions(
        version: version,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE draw_results (round INTEGER PRIMARY KEY)',
          );
          await db.execute(
            'CREATE TABLE number_sets (id INTEGER PRIMARY KEY AUTOINCREMENT, games TEXT NOT NULL, created_at TEXT NOT NULL, is_purchased INTEGER NOT NULL DEFAULT 0, round INTEGER, qr_raw TEXT)',
          );
          if (version == 2) {
            await db.execute(
              "CREATE TABLE purchase_history (id INTEGER PRIMARY KEY AUTOINCREMENT, games TEXT NOT NULL, round INTEGER NOT NULL, draw_date TEXT NOT NULL, source TEXT NOT NULL DEFAULT 'manual', created_at TEXT NOT NULL)",
            );
          }
          await db.insert('number_sets', setValues(purchased: true));
          await db.insert('number_sets', {
            ...setValues(),
            'created_at': 'legacy-unassigned',
          });
          await db.insert('number_sets', {...setValues(), 'games': 'invalid'});
        },
      ),
    );
    await old.close();
  }

  test(
    'malformed legacy numeric data stays quarantined without blocking migration or recovery',
    () async {
      await legacy('bad-numbers', 2);
      final raw = await databaseFactoryFfi.openDatabase(
        path.join(temporary.path, 'bad-numbers.db'),
      );
      await raw.insert('number_sets', {
        ...setValues(),
        'games': '[[1,2,3,4,5,"six"]]',
      });
      await raw.close();
      final database = device('bad-numbers');
      await database.switchAccount(ownerA);
      expect(await database.getUnassignedLegacyRecordCount(), 4);
      expect(await database.claimUnassignedLegacyRecords(), 2);
      expect(await database.getUnassignedLegacyRecordCount(), 2);
      expect((await database.getAllNumberSets()).length, 2);
    },
  );

  for (final version in [1, 2]) {
    test(
      'v$version migration quarantines every legacy row and reconciles only proven owner',
      () async {
        await legacy('legacy', version);
        final database = device('legacy');
        await database.switchAccount(ownerA);
        expect(await database.getAllNumberSets(), isEmpty);
        expect(await database.getUnassignedLegacyRecordCount(), 3);
        expect(await database.pendingChanges(ownerA), isEmpty);
        final values = setValues(purchased: true);
        final id = legacyRemoteId('number_sets', values);
        await database.applyRemoteRecords(ownerA, 'number_sets', [
          RemotePrivateRecord(id: id, values: values, deleted: false),
        ]);
        expect((await database.getAllNumberSets()).single['remote_id'], id);
        expect(await database.getUnassignedLegacyRecordCount(), 2);
        await database.switchAccount(ownerB);
        expect(await database.getAllNumberSets(), isEmpty);
        expect(await database.claimUnassignedLegacyRecords(), 1);
        expect(
          (await database.getAllNumberSets()).single['created_at'],
          'legacy-unassigned',
        );
        expect(
          await database.getUnassignedLegacyRecordCount(),
          1,
        ); // malformed row retained
        final raw = await (await database.db).query(
          'number_sets',
          where: 'owner_key IS NULL',
        );
        expect(raw.length, 3); // originals never removed
      },
    );
  }

  test(
    'guest, A and B are isolated and a suspended CRUD keeps its original owner',
    () async {
      final database = device('scope');
      final guestInsert = database.insertNumberSet(games: games);
      await database.switchAccount(ownerA);
      await guestInsert;
      expect(await database.getAllNumberSets(), isEmpty);
      final aId = await database.insertNumberSet(games: otherGames);
      await database.insertPurchaseHistory(
        games: games,
        round: 1234,
        source: 'manual',
      );
      await database.switchAccount(ownerB);
      await database.deleteNumberSet(aId);
      expect(await database.getAllNumberSets(), isEmpty);
      expect(await database.getAllPurchaseHistory(), isEmpty);
      await database.switchAccount(null);
      expect((await database.getAllNumberSets()).length, 1);
      await database.switchAccount(ownerA);
      expect((await database.getAllNumberSets()).single['id'], aId);
      expect((await database.getAllPurchaseHistory()).length, 1);
    },
  );

  test(
    'guest adoption is explicit, preserves IDs and recovery payload, and cannot be claimed by B',
    () async {
      final database = device('guest-adoption');
      await database.insertNumberSet(games: games);
      await database.insertPurchaseHistory(
        games: otherGames,
        round: 1234,
        source: 'manual',
      );
      final guestId = (await database.getAllNumberSets()).single['remote_id'];
      expect(await database.getGuestRecordCount(), 2);
      await database.switchAccount(ownerA);
      expect(await database.getAllNumberSets(), isEmpty);
      expect(await database.claimGuestRecords(), 2);
      expect((await database.getAllNumberSets()).single['remote_id'], guestId);
      expect((await database.pendingChanges(ownerA)).length, 2);
      await database.switchAccount(null);
      expect(await database.getAllNumberSets(), isEmpty);
      expect(await database.getAllPurchaseHistory(), isEmpty);
      expect(await database.getGuestRecordCount(), 0);
      await expectLater(database.claimGuestRecords(), throwsStateError);
      await database.switchAccount(ownerB);
      expect(await database.claimGuestRecords(), 0);
      expect(await database.getAllNumberSets(), isEmpty);
      final source = await (await database.db).query(
        'number_sets',
        where: "owner_key = ''",
      );
      expect(source.single['games'], jsonEncode(games));
      expect(source.single['claimed_by'], ownerA);
      expect(source.single['dirty'], 0);
    },
  );

  test(
    'two devices preserve concurrent adds and propagate explicit deletes',
    () async {
      final a = device('device-a');
      final b = device('device-b');
      final remote = FakeRemote();
      await a.switchAccount(ownerA);
      await b.switchAccount(ownerA);
      final syncA = engine(a, remote);
      final syncB = engine(b, remote);
      await a.insertNumberSet(games: games);
      await b.insertNumberSet(games: otherGames);
      await Future.wait([syncA.sync(ownerA), syncB.sync(ownerA)]);
      await syncA.sync(ownerA);
      await syncB.sync(ownerA);
      expect((await a.getAllNumberSets()).length, 2);
      expect((await b.getAllNumberSets()).length, 2);
      final remove = (await a.getAllNumberSets()).first;
      await a.deleteNumberSet(remove['id'] as int);
      await syncA.sync(ownerA);
      await syncB.sync(ownerA);
      expect((await b.getAllNumberSets()).length, 1);
      expect(remote.collection(ownerA, 'number_sets').length, 2);
      expect(
        remote
            .collection(ownerA, 'number_sets')
            .values
            .where((row) => row.deleted)
            .length,
        1,
      );
      expect(remote.pulls.any((watermark) => watermark != null), isTrue);
    },
  );

  test('local absence never deletes another device server record', () async {
    final database = device('empty');
    final remote = FakeRemote();
    final values = setValues();
    remote.collection(ownerA, 'number_sets')['remote'] = RemotePrivateRecord(
      id: 'remote',
      values: values,
      deleted: false,
      updatedAtMicros: 1,
    );
    await database.switchAccount(ownerA);
    await engine(database, remote).sync(ownerA, pull: false);
    expect(
      remote.collection(ownerA, 'number_sets')['remote']!.deleted,
      isFalse,
    );
    expect(remote.writes, isEmpty);
  });

  test(
    'dirty local edit survives stale pull and unchanged rows are not reuploaded',
    () async {
      final database = device('dirty');
      final remote = FakeRemote();
      await database.switchAccount(ownerA);
      final sync = engine(database, remote);
      final id = await database.insertNumberSet(games: games);
      await sync.sync(ownerA);
      await database.updatePurchased(id, isPurchased: true);
      await sync.sync(ownerA); // pulls old false while true is dirty
      expect((await database.getAllNumberSets()).single['is_purchased'], 1);
      expect(
        remote
            .collection(ownerA, 'number_sets')
            .values
            .single
            .values['is_purchased'],
        1,
      );
      final writes = remote.writes.length;
      await sync.sync(ownerA);
      expect(remote.writes.length, writes);
    },
  );

  test(
    'edit and delete during upload remain pending until their own acknowledgement',
    () async {
      final database = device('late');
      final remote = FakeRemote();
      await database.switchAccount(ownerA);
      final sync = engine(database, remote);
      final id = await database.insertNumberSet(games: games);
      remote.started = Completer<void>();
      final release = Completer<void>();
      remote.release = release;
      final running = sync.sync(ownerA, pull: false);
      await remote.started!.future;
      await database.updatePurchased(id, isPurchased: true);
      final changed = (await database.pendingChanges(ownerA)).single;
      expect(changed.revision, 2);
      await database.deleteNumberSet(id);
      release.complete();
      await running;
      expect(await database.pendingChanges(ownerA), isEmpty);
      expect(remote.writes.length, 2);
      expect(
        remote.collection(ownerA, 'number_sets').values.single.deleted,
        isTrue,
      );
    },
  );

  test(
    'failed upload survives database restart and retries successfully',
    () async {
      final database = device('restart');
      final remote = FakeRemote()..failNext = true;
      await database.switchAccount(ownerA);
      await database.insertPurchaseHistory(
        games: games,
        round: 1234,
        source: 'manual',
      );
      await expectLater(
        engine(database, remote).sync(ownerA),
        throwsStateError,
      );
      final before = (await database.pendingChanges(ownerA)).single.id;
      await database.close();
      final reopened = device('restart');
      await reopened.switchAccount(ownerA);
      expect((await reopened.pendingChanges(ownerA)).single.id, before);
      await engine(reopened, remote).sync(ownerA);
      expect(await reopened.pendingChanges(ownerA), isEmpty);
      expect(
        remote.collection(ownerA, 'purchase_history').containsKey(before),
        isTrue,
      );
    },
  );

  test(
    'account switch is immediate while upload waits and cannot write new owner',
    () async {
      final database = device('switch');
      final remote = FakeRemote();
      await database.switchAccount(ownerA);
      await database.insertNumberSet(games: games);
      remote.started = Completer<void>();
      final release = Completer<void>();
      remote.release = release;
      final running = engine(database, remote).sync(ownerA, pull: false);
      final failed = expectLater(running, throwsStateError);
      await remote.started!.future;
      await database
          .switchAccount(ownerB)
          .timeout(const Duration(milliseconds: 100));
      await database.insertNumberSet(games: otherGames);
      release.complete();
      await failed;
      expect(remote.writes, isEmpty);
      expect((await database.pendingChanges(ownerA)).length, 1);
      expect((await database.pendingChanges(ownerB)).length, 1);
      expect(
        (await database.getAllNumberSets()).single['games'],
        jsonEncode(otherGames),
      );
    },
  );

  test(
    'remote tombstone wins over stale dirty device even when pull is skipped',
    () async {
      final a = device('delete-a');
      final b = device('delete-b');
      final remote = FakeRemote();
      await a.switchAccount(ownerA);
      await b.switchAccount(ownerA);
      final syncA = engine(a, remote);
      final syncB = engine(b, remote);
      final id = await a.insertNumberSet(games: games);
      await syncA.sync(ownerA);
      await syncB.sync(ownerA);
      final staleId = (await b.getAllNumberSets()).single['id'] as int;
      await a.deleteNumberSet(id);
      await syncA.sync(ownerA);
      await b.updatePurchased(staleId, isPurchased: true);
      await syncB.sync(ownerA, pull: false);
      expect(await b.getAllNumberSets(), isEmpty);
      expect(await b.pendingChanges(ownerA), isEmpty);
      expect(
        remote.collection(ownerA, 'number_sets').values.single.deleted,
        isTrue,
      );
    },
  );

  test('concurrent sync requests share one account worker', () async {
    final database = device('serialized');
    final remote = FakeRemote();
    await database.switchAccount(ownerA);
    await database.insertNumberSet(games: games);
    final sync = engine(database, remote);
    remote.started = Completer<void>();
    final release = Completer<void>();
    remote.release = release;
    final first = sync.sync(ownerA, pull: false);
    await remote.started!.future;
    final second = sync.sync(ownerA);
    expect(identical(first, second), isTrue);
    release.complete();
    await Future.wait([first, second]);
    expect(remote.writes.length, 1);
  });
}
