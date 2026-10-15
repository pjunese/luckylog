import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/data/account_data_sync_engine.dart';
import 'package:my_app/data/private_record.dart';
import 'package:my_app/db/lotto_database.dart';
import 'package:my_app/models/purchase_record.dart';
import 'package:my_app/models/scanned_ticket.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const ownerA = 'kakao:11';
const ownerB = 'apple:22';
const tokenA = '1230q0102030405060000000001';
const tokenB = '1230q0102030405060000000002';
const game = [
  [1, 2, 3, 4, 5, 6],
];
ScannedTicket ticket(String token) => ScannedTicket.tryParse(token)!;

class MemoryRemote implements PrivateRecordRemote {
  final documents = <String, Map<String, Map<String, dynamic>>>{};
  int clock = 0;
  int writes = 0;
  Completer<void>? started;
  Completer<void>? release;
  Map<String, Map<String, dynamic>> collection(String owner, String name) =>
      documents.putIfAbsent('$owner/$name', () => {});

  @override
  Future<List<RemotePrivateRecord>> pull(
    String owner,
    String name,
    int? sinceMicros,
  ) async {
    return collection(owner, name).entries
        .where(
          (entry) =>
              sinceMicros == null || entry.value['stamp'] as int >= sinceMicros,
        )
        .map(
          (entry) => privateRecordFromRemote(
            name,
            entry.key,
            entry.value,
            updatedAtMicros: entry.value['stamp'] as int,
          )!,
        )
        .toList();
  }

  @override
  Future<bool> push(
    String owner,
    PendingPrivateRecord change,
    bool Function() isActive,
  ) async {
    final barrier = release;
    if (barrier != null) {
      release = null;
      started!.complete();
      await barrier.future;
    }
    if (!isActive()) throw StateError('Account changed');
    final records = collection(owner, change.collection);
    final existing = records[change.id] ?? {};
    if (existing['deleted'] == true) return true;
    records[change.id] = {
      ...existing,
      ...privateRecordToRemote(change, existing: existing),
      'stamp': ++clock,
    };
    writes++;
    return change.deleted;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory temporary;
  final databases = <LottoDatabase>[];
  LottoDatabase device(String name) {
    final d = LottoDatabase.forTesting(
      factory: databaseFactoryFfi,
      path: path.join(temporary.path, '$name.db'),
    );
    databases.add(d);
    return d;
  }

  AccountDataSyncEngine engine(LottoDatabase database, MemoryRemote remote) =>
      AccountDataSyncEngine(
        database: database,
        remote: remote,
        isOwnerActive: (owner) => database.accountKey == owner,
      );
  Future<void> draw(LottoDatabase d, int round) =>
      d.insertDrawResult(round: round, numbers: game.single, bonus: 7);
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('lotto-qr-data-');
  });
  tearDown(() async {
    for (final database in databases) {
      await database.close();
    }
    databases.clear();
    await temporary.delete(recursive: true);
  });

  test(
    'scan identity hashes the complete canonical token and retains distinct same-number tickets',
    () {
      final raw = ticket(tokenA);
      final url = ticket(
        'http://www.dhlottery.co.kr/qr.do?method=winQr&v=$tokenA&unused=value',
      );
      expect(raw.fingerprint, sha256.convert(utf8.encode(tokenA)).toString());
      expect(url.fingerprint, raw.fingerprint);
      expect(url.uri.toString(), 'https://qr.dhlottery.co.kr/?v=$tokenA');
      expect(raw.round, 1230);
      expect(raw.games, game);
      expect(ticket(tokenB).games, game);
      expect(ticket(tokenB).fingerprint, isNot(raw.fingerprint));
      expect(() => raw.games.single.add(7), throwsUnsupportedError);
      for (final invalid in [
        '1230m010101010101',
        '0000m010203040506',
        'https://evil.invalid/qr.do?method=winQr&v=$tokenA',
      ]) {
        expect(ScannedTicket.tryParse(invalid), isNull);
      }
    },
  );

  test(
    'QR batch deduplicates active/deleted tickets and persists fingerprint without raw token',
    () async {
      final d = device('duplicates');
      await d.switchAccount(ownerA);
      final a = ticket(tokenA);
      final b = ticket(tokenB);
      final result = await d.insertQrPurchaseBatch([a, a, b]);
      expect(result.insertedCount, 2);
      expect(result.duplicateCount, 1);
      expect(result.deletedCount, 0);
      final rows = await d.getAllPurchaseHistory();
      expect(rows.length, 2);
      expect(
        rows.map((row) => row['remote_id']),
        containsAll(['qr_${a.fingerprint}', 'qr_${b.fingerprint}']),
      );
      expect(jsonEncode(rows), isNot(contains(tokenA)));
      expect(jsonEncode(rows), isNot(contains('dhlottery')));
      final removed = rows.firstWhere(
        (row) => row['qr_fingerprint'] == a.fingerprint,
      );
      await d.deletePurchaseHistory(removed['id'] as int);
      final repeat = await d.insertQrPurchaseBatch([a, b]);
      expect(repeat.insertedCount, 0);
      expect(repeat.duplicateCount, 1);
      expect(repeat.deletedCount, 1);
      expect(await d.getKnownQrFingerprints(), {a.fingerprint, b.fingerprint});
      await d.switchAccount(ownerB);
      expect(await d.getKnownQrFingerprints(), isEmpty);
      expect((await d.insertQrPurchaseBatch([a])).insertedCount, 1);
    },
  );

  test('QR batch rolls back completely on a later insert failure', () async {
    final d = device('atomic');
    await d.switchAccount(ownerA);
    final sql = await d.db;
    final blocked = ticket(tokenB).fingerprint;
    await sql.execute(
      "CREATE TRIGGER reject_second BEFORE INSERT ON purchase_history WHEN NEW.qr_fingerprint = '$blocked' BEGIN SELECT RAISE(ABORT, 'test failure'); END",
    );
    final before = d.revision.value;
    await expectLater(
      d.insertQrPurchaseBatch([ticket(tokenA), ticket(tokenB)]),
      throwsA(isA<DatabaseException>()),
    );
    expect(await d.getAllPurchaseHistory(), isEmpty);
    expect(await d.pendingChanges(ownerA), isEmpty);
    expect(d.revision.value, before);
    await sql.execute('DROP TRIGGER reject_second');
    expect(
      (await d.insertQrPurchaseBatch([
        ticket(tokenA),
        ticket(tokenB),
      ])).insertedCount,
      2,
    );
  });

  test(
    'batch and result marking retain the owner captured before awaiting SQLite',
    () async {
      final d = device('captured');
      await d.switchAccount(ownerA);
      final pending = d.insertQrPurchaseBatch([ticket(tokenA)]);
      await d.switchAccount(ownerB);
      await pending;
      expect(await d.getAllPurchaseHistory(), isEmpty);
      await d.switchAccount(ownerA);
      await draw(d, 1230);
      final id = (await d.getAllPurchaseHistory()).single['id'] as int;
      final mark = d.markPurchaseResultsChecked([id]);
      await d.switchAccount(ownerB);
      expect(await mark, 1);
      expect(await d.getAllPurchaseHistory(), isEmpty);
      await d.switchAccount(ownerA);
      expect(
        PurchaseRecord.fromDb(
          (await d.getAllPurchaseHistory()).single,
        ).isResultChecked,
        isTrue,
      );
    },
  );

  test(
    'v3 upgrade preserves existing rows, IDs, dirty revisions and optional metadata defaults',
    () async {
      final name = path.join(temporary.path, 'v3.db');
      final old = await databaseFactoryFfi.openDatabase(
        name,
        options: OpenDatabaseOptions(
          version: 3,
          onCreate: (d, _) async {
            await d.execute(
              'CREATE TABLE draw_results (round INTEGER PRIMARY KEY, num1 INTEGER, num2 INTEGER, num3 INTEGER, num4 INTEGER, num5 INTEGER, num6 INTEGER, bonus INTEGER)',
            );
            const metadata =
                'owner_key TEXT, remote_id TEXT, dirty INTEGER DEFAULT 0, local_revision INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0, claimed_by TEXT';
            await d.execute(
              'CREATE TABLE number_sets(id INTEGER PRIMARY KEY, games TEXT NOT NULL, created_at TEXT NOT NULL, is_purchased INTEGER DEFAULT 0, round INTEGER, qr_raw TEXT, $metadata)',
            );
            await d.execute(
              'CREATE TABLE purchase_history(id INTEGER PRIMARY KEY, games TEXT NOT NULL, round INTEGER NOT NULL, draw_date TEXT NOT NULL, source TEXT NOT NULL, created_at TEXT NOT NULL, $metadata)',
            );
            await d.execute(
              'CREATE TABLE sync_checkpoints(owner_key TEXT, collection TEXT, watermark INTEGER, PRIMARY KEY(owner_key,collection))',
            );
            await d.insert('purchase_history', {
              'id': 7,
              'games': jsonEncode(game),
              'round': 1230,
              'draw_date': '2026-06-27',
              'source': 'qr',
              'created_at': '2026-06-20T01:00:00.000Z',
              'owner_key': ownerA,
              'remote_id': 'legacy-id',
              'dirty': 1,
              'local_revision': 8,
            });
          },
        ),
      );
      await old.close();
      final d = device('v3');
      await d.switchAccount(ownerA);
      final row = (await d.getAllPurchaseHistory()).single;
      expect(row['id'], 7);
      expect(row['remote_id'], 'legacy-id');
      expect(row['dirty'], 1);
      expect(row['local_revision'], 8);
      expect(row['qr_fingerprint'], isNull);
      expect(row['result_checked_at'], isNull);
      final record = PurchaseRecord.fromDb(row);
      expect(record.qrFingerprint, isNull);
      expect(record.resultCheckedAt, isNull);
      expect(record.isResultChecked, isFalse);
      expect(await (await d.db).getVersion(), 5);
    },
  );

  test(
    'checked status requires the exact draw and is immutable for repeated checks',
    () async {
      final d = device('check');
      await d.switchAccount(ownerA);
      final missing = await d.insertPurchaseHistory(
        games: game,
        round: 1230,
        source: 'manual',
      );
      final ready = await d.insertPurchaseHistory(
        games: game,
        round: 1231,
        source: 'manual',
      );
      final deleted = await d.insertPurchaseHistory(
        games: game,
        round: 1231,
        source: 'manual',
      );
      await d.deletePurchaseHistory(deleted);
      await draw(d, 1231);
      expect(
        await d.markPurchaseResultsChecked([missing, ready, deleted, ready]),
        1,
      );
      final rows = await d.getAllPurchaseHistory();
      expect(
        rows.firstWhere((row) => row['id'] == missing)['result_checked_at'],
        isNull,
      );
      final stamp = rows.firstWhere(
        (row) => row['id'] == ready,
      )['result_checked_at'];
      final before = d.revision.value;
      expect(await d.markPurchaseResultsChecked([ready]), 0);
      expect(d.revision.value, before);
      expect(
        (await d.getAllPurchaseHistory()).firstWhere(
          (row) => row['id'] == ready,
        )['result_checked_at'],
        stamp,
      );
    },
  );

  test(
    'drawRevision only signals actual public inserts and bulk lookup omits missing rounds',
    () async {
      final d = device('draw');
      final privateBefore = d.revision.value;
      await draw(d, 1230);
      await draw(d, 1230);
      expect(d.drawRevision.value, 1);
      expect(d.revision.value, privateBefore);
      final draws = await d.getDrawResultsForRounds({
        ...List.generate(1500, (index) => index + 1),
      });
      expect(draws.keys, [1230]);
      expect(draws[1230]!.winningNumbers, game.single);
      expect(draws[1230]!.bonusNumber, 7);
      expect(await d.getDrawResultsForRounds({}), isEmpty);
    },
  );

  test(
    'remote codec roundtrip includes QR and checked metadata with legacy-compatible defaults',
    () {
      final checked = '2026-06-27T13:00:00.000Z';
      final fingerprint = ticket(tokenA).fingerprint;
      final row = {
        'games': jsonEncode(game),
        'round': 1230,
        'draw_date': '2026-06-27',
        'source': 'qr',
        'created_at': '2026-06-20T00:00:00.000Z',
        'qr_fingerprint': fingerprint,
        'result_checked_at': checked,
        'deleted': 0,
      };
      final remote = privateRecordToRemote(
        PendingPrivateRecord('purchase_history', row),
      );
      final decoded = privateRecordFromRemote(
        'purchase_history',
        'qr_$fingerprint',
        remote,
      )!;
      expect(decoded.values['qr_fingerprint'], fingerprint);
      expect(decoded.values['result_checked_at'], checked);
      final oldPayload = Map<String, dynamic>.from(remote)
        ..remove('qrFingerprint')
        ..remove('resultCheckedAt');
      final oldRecord = privateRecordFromRemote(
        'purchase_history',
        'old',
        oldPayload,
      )!;
      expect(oldRecord.values['qr_fingerprint'], isNull);
      expect(oldRecord.values['result_checked_at'], isNull);
      final stale = Map<String, dynamic>.from(row)
        ..['result_checked_at'] = null
        ..['qr_fingerprint'] = null;
      final merged = privateRecordToRemote(
        PendingPrivateRecord('purchase_history', stale),
        existing: remote,
      );
      expect(merged['qrFingerprint'], fingerprint);
      expect(merged['resultCheckedAt'], checked);
    },
  );

  test(
    'two devices scanning the same QR converge; same numbers with distinct full tokens remain separate',
    () async {
      final a = device('qr-a');
      final b = device('qr-b');
      final remote = MemoryRemote();
      await a.switchAccount(ownerA);
      await b.switchAccount(ownerA);
      await a.insertQrPurchaseBatch([ticket(tokenA)]);
      await b.insertQrPurchaseBatch([ticket(tokenA), ticket(tokenB)]);
      final syncA = engine(a, remote);
      final syncB = engine(b, remote);
      await Future.wait([
        syncA.sync(ownerA, pull: false),
        syncB.sync(ownerA, pull: false),
      ]);
      await syncA.sync(ownerA);
      await syncB.sync(ownerA);
      expect(remote.collection(ownerA, 'purchase_history').length, 2);
      expect((await a.getAllPurchaseHistory()).length, 2);
      expect((await b.getAllPurchaseHistory()).length, 2);
      final removed = (await a.getAllPurchaseHistory()).firstWhere(
        (row) => row['qr_fingerprint'] == ticket(tokenA).fingerprint,
      );
      await a.deletePurchaseHistory(removed['id'] as int);
      await syncA.sync(ownerA);
      await syncB.sync(ownerA);
      expect((await b.insertQrPurchaseBatch([ticket(tokenA)])).deletedCount, 1);
    },
  );

  test(
    'stale unchecked device upload cannot clear server check and pulls converge checked state',
    () async {
      final a = device('checked-a');
      final b = device('checked-b');
      final remote = MemoryRemote();
      await a.switchAccount(ownerA);
      await b.switchAccount(ownerA);
      await a.insertQrPurchaseBatch([ticket(tokenA)]);
      await b.insertQrPurchaseBatch([ticket(tokenA)]);
      final syncA = engine(a, remote);
      final syncB = engine(b, remote);
      await draw(a, 1230);
      final id = (await a.getAllPurchaseHistory()).single['id'] as int;
      await a.markPurchaseResultsChecked([id]);
      await syncA.sync(ownerA);
      final checked = remote
          .collection(ownerA, 'purchase_history')
          .values
          .single['resultCheckedAt'];
      await syncB.sync(ownerA, pull: false);
      expect(
        remote
            .collection(ownerA, 'purchase_history')
            .values
            .single['resultCheckedAt'],
        checked,
      );
      await syncB.sync(ownerA);
      expect(
        (await b.getAllPurchaseHistory()).single['result_checked_at'],
        checked,
      );
      final values =
          Map<String, dynamic>.from((await a.getAllPurchaseHistory()).single)
            ..removeWhere(
              (key, _) => [
                'id',
                'owner_key',
                'remote_id',
                'dirty',
                'local_revision',
                'deleted',
                'claimed_by',
              ].contains(key),
            );
      values['result_checked_at'] = null;
      await a.applyRemoteRecords(ownerA, 'purchase_history', [
        RemotePrivateRecord(
          id: 'qr_${ticket(tokenA).fingerprint}',
          values: values,
          deleted: false,
        ),
      ]);
      expect(
        (await a.getAllPurchaseHistory()).single['result_checked_at'],
        checked,
      );
    },
  );

  test(
    'checking during an upload stays dirty until checked revision is uploaded',
    () async {
      final d = device('late-check');
      final remote = MemoryRemote();
      await d.switchAccount(ownerA);
      await d.insertQrPurchaseBatch([ticket(tokenA)]);
      await draw(d, 1230);
      final id = (await d.getAllPurchaseHistory()).single['id'] as int;
      remote.started = Completer<void>();
      final release = Completer<void>();
      remote.release = release;
      final running = engine(d, remote).sync(ownerA, pull: false);
      await remote.started!.future;
      expect(await d.markPurchaseResultsChecked([id]), 1);
      release.complete();
      await running;
      expect(remote.writes, 2);
      expect(await d.pendingChanges(ownerA), isEmpty);
      expect(
        remote
            .collection(ownerA, 'purchase_history')
            .values
            .single['resultCheckedAt'],
        isNotNull,
      );
    },
  );

  test(
    'checked metadata merges into dirty local row without clearing its pending mutation',
    () async {
      final d = device('dirty-check');
      await d.switchAccount(ownerA);
      await d.insertQrPurchaseBatch([ticket(tokenA)]);
      final row = (await d.getAllPurchaseHistory()).single;
      final remoteValues = Map<String, dynamic>.from(row)
        ..removeWhere(
          (key, _) => [
            'id',
            'owner_key',
            'remote_id',
            'dirty',
            'local_revision',
            'deleted',
            'claimed_by',
          ].contains(key),
        );
      remoteValues['result_checked_at'] = '2026-06-27T13:00:00.000Z';
      await d.applyRemoteRecords(ownerA, 'purchase_history', [
        RemotePrivateRecord(
          id: row['remote_id'] as String,
          values: remoteValues,
          deleted: false,
        ),
      ]);
      final pending = (await d.pendingChanges(ownerA)).single;
      expect(pending.revision, 2);
      expect(
        pending.row['result_checked_at'],
        remoteValues['result_checked_at'],
      );
      final old = PendingPrivateRecord('purchase_history', row);
      await d.acknowledgeUpload(ownerA, old, remoteDeleted: false);
      expect((await d.pendingChanges(ownerA)).length, 1);
    },
  );
}
