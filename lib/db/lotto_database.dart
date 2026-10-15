import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';

import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/number_stat.dart';
import '../models/scanned_ticket.dart';
import '../models/purchase_date.dart';
import '../models/draw_result.dart';
import '../core/lotto_validation.dart';
import '../data/private_record.dart';

class LottoDatabase {
  LottoDatabase._();
  static final LottoDatabase instance = LottoDatabase._();

  /// Injectable SQLite factory/path for migration and multi-device tests.
  @visibleForTesting
  LottoDatabase.forTesting({
    required DatabaseFactory factory,
    required String path,
  }) : _factory = factory,
       _path = path,
       _seed = false;

  DatabaseFactory? _factory;
  String? _path;
  bool _seed = true;
  Future<Database>? _opening;
  String? _accountKey;

  String? get accountKey => _accountKey;
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  final ValueNotifier<int> drawRevision = ValueNotifier<int>(0);
  String get _owner => _accountKey ?? '';

  /// Switching never waits for a network worker and never closes an in-use DB.
  Future<void> switchAccount(String? accountKey) async {
    final next = accountKey == null || accountKey.isEmpty ? null : accountKey;
    if (_accountKey == next) return;
    _accountKey = next;
    revision.value++;
  }

  Future<Database> get db => _opening ??= _initDb();

  @visibleForTesting
  Future<void> close() async {
    if (_opening != null) await (await _opening!).close();
    _opening = null;
  }

  void _changed(String owner) {
    if (owner == _owner) revision.value++;
  }

  // ─────────────────────────────────────────
  // 초기화
  // ─────────────────────────────────────────

  Future<Database> _initDb() async {
    final factory = _factory ?? databaseFactory;
    final dbPath = _path ?? join(await factory.getDatabasesPath(), 'lotto.db');
    return factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 5,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS purchase_history (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          games       TEXT    NOT NULL,
          round       INTEGER NOT NULL,
          draw_date   TEXT    NOT NULL,
          source      TEXT    NOT NULL DEFAULT 'manual',
          created_at  TEXT    NOT NULL
        )
      ''');
    }
    if (oldVersion < 3) await _addPrivateOwnership(db);
    if (oldVersion < 4) await _addPurchaseMetadata(db);
    if (oldVersion < 5) await _addPurchaseDate(db);
  }

  Future<void> _onCreate(Database db, int version) async {
    // 회차별 당첨번호 테이블
    await db.execute('''
      CREATE TABLE draw_results (
        round  INTEGER PRIMARY KEY,
        num1   INTEGER NOT NULL,
        num2   INTEGER NOT NULL,
        num3   INTEGER NOT NULL,
        num4   INTEGER NOT NULL,
        num5   INTEGER NOT NULL,
        num6   INTEGER NOT NULL,
        bonus  INTEGER NOT NULL
      )
    ''');

    // 내 번호세트 테이블
    await db.execute('''
      CREATE TABLE number_sets (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        games        TEXT    NOT NULL,
        created_at   TEXT    NOT NULL,
        is_purchased INTEGER NOT NULL DEFAULT 0,
        round        INTEGER,
        qr_raw       TEXT
      )
    ''');

    // purchase_history 테이블
    await db.execute('''
      CREATE TABLE purchase_history (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        games       TEXT    NOT NULL,
        round       INTEGER NOT NULL,
        draw_date   TEXT    NOT NULL,
        source      TEXT    NOT NULL DEFAULT 'manual',
        created_at  TEXT    NOT NULL
      )
    ''');

    // 최초 실행 시 JSON → SQLite 로드
    await _addPrivateOwnership(db);
    await _addPurchaseMetadata(db);
    await _addPurchaseDate(db);
    if (_seed) await _seedDrawResults(db);
  }

  Future<void> _addPurchaseDate(Database d) async {
    await d.execute(
      'ALTER TABLE purchase_history ADD COLUMN purchase_date TEXT',
    );
    await d.execute(
      'ALTER TABLE purchase_history ADD COLUMN purchase_date_updated_at TEXT',
    );
  }

  Future<void> _addPurchaseMetadata(Database d) async {
    await d.execute(
      'ALTER TABLE purchase_history ADD COLUMN qr_fingerprint TEXT',
    );
    await d.execute(
      'ALTER TABLE purchase_history ADD COLUMN result_checked_at TEXT',
    );
    await d.execute(
      'CREATE INDEX purchase_owner_qr ON purchase_history(owner_key, qr_fingerprint)',
    );
  }

  Future<void> _addPrivateOwnership(Database d) async {
    for (final table in privateCollections) {
      // Legacy owner stays NULL. Never infer ownership from the next login.
      await d.execute('ALTER TABLE $table ADD COLUMN owner_key TEXT');
      await d.execute('ALTER TABLE $table ADD COLUMN remote_id TEXT');
      await d.execute(
        'ALTER TABLE $table ADD COLUMN dirty INTEGER NOT NULL DEFAULT 0',
      );
      await d.execute(
        'ALTER TABLE $table ADD COLUMN local_revision INTEGER NOT NULL DEFAULT 0',
      );
      await d.execute(
        'ALTER TABLE $table ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0',
      );
      await d.execute('ALTER TABLE $table ADD COLUMN claimed_by TEXT');
      final rows = await d.query(table);
      for (final row in rows) {
        await d.update(
          table,
          {'remote_id': legacyRemoteId(table, row)},
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
      await d.execute(
        'CREATE UNIQUE INDEX ${table}_owner_remote ON $table(owner_key, remote_id)',
      );
      await d.execute(
        'CREATE INDEX ${table}_owner_dirty ON $table(owner_key, dirty)',
      );
    }
    await d.execute(
      'CREATE TABLE sync_checkpoints (owner_key TEXT NOT NULL, collection TEXT NOT NULL, watermark INTEGER NOT NULL, PRIMARY KEY(owner_key, collection))',
    );
  }

  // 회차 → 추첨일 계산 (1회: 2002-12-07, 이후 매주 토요일)
  static String drawDateFromRound(int round) {
    final DateTime base = DateTime(2002, 12, 7);
    final DateTime date = base.add(Duration(days: (round - 1) * 7));
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  // ─────────────────────────────────────────
  // JSON 시드 데이터 로드 (최초 1회)
  // ─────────────────────────────────────────

  Future<void> _seedDrawResults(Database db) async {
    final String raw = await rootBundle.loadString('assets/lotto_history.json');
    final List<dynamic> list = jsonDecode(raw) as List<dynamic>;

    final Batch batch = db.batch();
    for (final dynamic item in list) {
      final Map<String, dynamic> m = item as Map<String, dynamic>;
      final List<int> nums = List<int>.from(m['numbers'] as List);
      batch.insert('draw_results', {
        'round': m['round'] as int,
        'num1': nums[0],
        'num2': nums[1],
        'num3': nums[2],
        'num4': nums[3],
        'num5': nums[4],
        'num6': nums[5],
        'bonus': m['bonus'] as int,
      });
    }
    await batch.commit(noResult: true);
  }

  // ─────────────────────────────────────────
  // draw_results 기본 조회
  // ─────────────────────────────────────────

  Future<Map<String, dynamic>?> getDrawResult(int round) async {
    final Database d = await db;
    final List<Map<String, dynamic>> rows = await d.query(
      'draw_results',
      where: 'round = ?',
      whereArgs: [round],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> getLatestRound() async {
    final Database d = await db;
    final List<Map<String, dynamic>> rows = await d.rawQuery(
      'SELECT MAX(round) as r FROM draw_results',
    );
    return (rows.first['r'] as int?) ?? 0;
  }

  /// Signals public draw changes independently from account-private changes.
  Future<void> insertDrawResult({
    required int round,
    required List<int> numbers,
    required int bonus,
  }) async {
    final captured = List<int>.of(numbers);
    if (round <= 0 ||
        !isValidLottoGame(captured) ||
        bonus < 1 ||
        bonus > 45 ||
        captured.contains(bonus)) {
      throw ArgumentError('Invalid draw result.');
    }
    final d = await db;
    final inserted = await d.transaction((txn) async {
      await txn.insert('draw_results', {
        'round': round,
        for (var i = 0; i < captured.length; i++) 'num${i + 1}': captured[i],
        'bonus': bonus,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      return Sqflite.firstIntValue(await txn.rawQuery('SELECT changes()')) == 1;
    });
    if (inserted) drawRevision.value++;
  }

  Future<Map<int, DrawResult>> getDrawResultsForRounds(Set<int> rounds) async {
    final requested = rounds
        .where((round) => round > 0)
        .toList(growable: false);
    if (requested.isEmpty) return {};
    final d = await db;
    final result = <int, DrawResult>{};
    for (var start = 0; start < requested.length; start += 500) {
      final chunk = requested.sublist(
        start,
        min(start + 500, requested.length),
      );
      final rows = await d.query(
        'draw_results',
        where: 'round IN (${List.filled(chunk.length, '?').join(',')})',
        whereArgs: chunk,
      );
      for (final row in rows) {
        final round = row['round'] as int;
        result[round] = DrawResult(
          round: round,
          winningNumbers: List.generate(6, (i) => row['num${i + 1}'] as int),
          bonusNumber: row['bonus'] as int,
          drawDate: drawDateFromRound(round),
        );
      }
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> getDrawResultsInRange({
    required int from,
    required int to,
  }) async {
    final Database d = await db;
    return d.query(
      'draw_results',
      where: 'round BETWEEN ? AND ?',
      whereArgs: [from, to],
      orderBy: 'round ASC',
    );
  }

  /// 특정 연번(startNumber ~ startNumber+length-1)이 포함된 회차 목록 (최신순)
  Future<List<Map<String, dynamic>>> getConsecutiveSequenceRounds({
    required int startNumber,
    required int sequenceLength,
  }) async {
    final Database d = await db;
    // 연번의 각 숫자가 6개 번호 중 하나인 행만 추출
    final conditions = List.generate(sequenceLength, (i) {
      final n = startNumber + i;
      return '(num1=$n OR num2=$n OR num3=$n OR num4=$n OR num5=$n OR num6=$n)';
    }).join(' AND ');
    return d.rawQuery(
      'SELECT * FROM draw_results WHERE $conditions ORDER BY round DESC',
    );
  }

  /// 전체 당첨결과 (최신순, 페이지네이션)
  Future<List<Map<String, dynamic>>> getAllDrawResults({
    int limit = 50,
    int offset = 0,
    String? searchRound,
  }) async {
    final Database d = await db;
    if (searchRound != null && searchRound.isNotEmpty) {
      return d.query(
        'draw_results',
        where: 'round = ?',
        whereArgs: [int.tryParse(searchRound) ?? 0],
        orderBy: 'round DESC',
      );
    }
    return d.query(
      'draw_results',
      orderBy: 'round DESC',
      limit: limit,
      offset: offset,
    );
  }

  // ─────────────────────────────────────────
  // number_sets CRUD
  // ─────────────────────────────────────────

  String _newRemoteId() {
    final random = Random.secure();
    return 'v2_${base64UrlEncode(List.generate(18, (_) => random.nextInt(256)))}';
  }

  Future<int> _insertPrivate(
    String table,
    String owner,
    Map<String, dynamic> values,
  ) async {
    if (!isValidPrivateRecord(table, values)) {
      throw ArgumentError('Invalid lotto record.');
    }
    final d = await db;
    final id = await d.insert(table, {
      ...values,
      'owner_key': owner,
      'remote_id': _newRemoteId(),
      'dirty': 1,
      'local_revision': 1,
      'deleted': 0,
    });
    _changed(owner);
    return id;
  }

  Future<int> insertNumberSet({
    required List<List<int>> games,
    int? round,
    String? qrRaw,
  }) {
    final owner = _owner;
    return _insertPrivate('number_sets', owner, {
      'games': jsonEncode(games),
      'created_at': DateTime.now().toIso8601String(),
      'is_purchased': 0,
      'round': round,
      'qr_raw': qrRaw,
    });
  }

  Future<List<Map<String, dynamic>>> getAllNumberSets() async {
    final owner = _owner;
    final d = await db;
    return d.query(
      'number_sets',
      where: 'owner_key = ? AND deleted = 0',
      whereArgs: [owner],
      orderBy: 'id DESC',
    );
  }

  Future<void> updatePurchased(int id, {required bool isPurchased}) async {
    final owner = _owner;
    final d = await db;
    await d.rawUpdate(
      'UPDATE number_sets SET is_purchased = ?, dirty = 1, local_revision = local_revision + 1 WHERE id = ? AND owner_key = ? AND deleted = 0',
      [isPurchased ? 1 : 0, id, owner],
    );
    _changed(owner);
  }

  Future<void> _deletePrivate(String table, int id, String owner) async {
    final d = await db;
    await d.rawUpdate(
      'UPDATE $table SET deleted = 1, dirty = 1, local_revision = local_revision + 1 WHERE id = ? AND owner_key = ? AND deleted = 0',
      [id, owner],
    );
    _changed(owner);
  }

  Future<void> deleteNumberSet(int id) =>
      _deletePrivate('number_sets', id, _owner);

  // A tombstone remains terminal. Restoration creates a stable successor, so
  // concurrent restores on two devices converge on one new remote record.
  String _restoredId(String original) =>
      'restored_${sha256.convert(utf8.encode(original))}';

  Future<List<Map<String, dynamic>>> getDeletedNumberSets() async {
    final owner = _owner;
    final d = await db;
    final rows = await d.query(
      'number_sets',
      where: 'owner_key = ?',
      whereArgs: [owner],
      orderBy: 'id DESC',
    );
    final ids = rows.map((row) => row['remote_id']).toSet();
    return rows
        .where(
          (row) =>
              row['deleted'] == 1 &&
              !ids.contains(_restoredId(row['remote_id'] as String)),
        )
        .toList();
  }

  Future<int?> restoreNumberSet(int id) async {
    final owner = _owner;
    final d = await db;
    final restored = await d.transaction<int?>((txn) async {
      final rows = await txn.query(
        'number_sets',
        where: 'id = ? AND owner_key = ? AND deleted = 1',
        whereArgs: [id, owner],
      );
      if (rows.isEmpty) return null;
      final source = rows.single;
      if (!isValidPrivateRecord('number_sets', source)) {
        throw StateError('번호 정보를 확인할 수 없어 복원하지 못했습니다.');
      }
      final remoteId = _restoredId(source['remote_id'] as String);
      final existing = await txn.query(
        'number_sets',
        columns: ['id'],
        where: 'owner_key = ? AND remote_id = ?',
        whereArgs: [owner, remoteId],
      );
      if (existing.isNotEmpty) return null;
      return txn.insert('number_sets', {
        for (final key in [
          'games',
          'created_at',
          'is_purchased',
          'round',
          'qr_raw',
        ])
          key: source[key],
        'owner_key': owner,
        'remote_id': remoteId,
        'dirty': 1,
        'local_revision': 1,
        'deleted': 0,
      });
    });
    if (restored != null) _changed(owner);
    return restored;
  }

  Future<int> insertPurchaseHistory({
    required List<List<int>> games,
    required int round,
    required String source,
    DateTime? purchaseDate,
  }) {
    final owner = _owner;
    if (purchaseDate != null) _validatePurchaseDate(purchaseDate, round);
    return _insertPrivate('purchase_history', owner, {
      'games': jsonEncode(games),
      'round': round,
      'draw_date': drawDateFromRound(round),
      'source': source,
      'created_at': DateTime.now().toIso8601String(),
      if (purchaseDate != null) 'purchase_date': purchaseDateKey(purchaseDate),
      if (purchaseDate != null)
        'purchase_date_updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<QrBatchSaveResult> insertQrPurchaseBatch(
    List<ScannedTicket> tickets, {
    DateTime? purchaseDate,
  }) async {
    final owner = _owner;
    final captured = List<ScannedTicket>.of(tickets);
    if (purchaseDate != null) {
      for (final ticket in captured) {
        _validatePurchaseDate(purchaseDate, ticket.round);
      }
    }
    if (captured.isEmpty) {
      return const QrBatchSaveResult(
        insertedCount: 0,
        duplicateCount: 0,
        deletedCount: 0,
      );
    }
    final d = await db;
    final result = await d.transaction((txn) async {
      var inserted = 0;
      var duplicate = 0;
      var deleted = 0;
      final now = DateTime.now().toUtc().toIso8601String();
      for (final ticket in captured) {
        final remoteId = 'qr_${ticket.fingerprint}';
        final existing = await txn.query(
          'purchase_history',
          where: 'owner_key = ? AND (qr_fingerprint = ? OR remote_id = ?)',
          whereArgs: [owner, ticket.fingerprint, remoteId],
        );
        if (existing.isNotEmpty) {
          if (existing.any((row) => row['deleted'] == 0)) {
            duplicate++;
          } else {
            deleted++;
          }
          continue;
        }
        await txn.insert('purchase_history', {
          'games': jsonEncode(ticket.games),
          'round': ticket.round,
          'draw_date': drawDateFromRound(ticket.round),
          'source': 'qr',
          'created_at': now,
          if (purchaseDate != null)
            'purchase_date': purchaseDateKey(purchaseDate),
          if (purchaseDate != null) 'purchase_date_updated_at': now,
          'owner_key': owner,
          'remote_id': remoteId,
          'qr_fingerprint': ticket.fingerprint,
          'dirty': 1,
          'local_revision': 1,
        });
        inserted++;
      }
      return QrBatchSaveResult(
        insertedCount: inserted,
        duplicateCount: duplicate,
        deletedCount: deleted,
      );
    });
    if (result.insertedCount > 0) _changed(owner);
    return result;
  }

  Future<Set<String>> getKnownQrFingerprints() async {
    final owner = _owner;
    final d = await db;
    final rows = await d.query(
      'purchase_history',
      columns: ['qr_fingerprint'],
      where: 'owner_key = ? AND qr_fingerprint IS NOT NULL',
      whereArgs: [owner],
    );
    return rows.map((row) => row['qr_fingerprint'] as String).toSet();
  }

  /// A result can be marked checked only after its actual draw is available.
  Future<int> markPurchaseResultsChecked(List<int> ids) async {
    final owner = _owner;
    final captured = ids.toSet().toList(growable: false);
    if (captured.isEmpty) return 0;
    final d = await db;
    final count = await d.transaction((txn) async {
      var count = 0;
      final now = DateTime.now().toUtc().toIso8601String();
      for (var start = 0; start < captured.length; start += 500) {
        final chunk = captured.sublist(
          start,
          min(start + 500, captured.length),
        );
        count += await txn.rawUpdate(
          'UPDATE purchase_history SET result_checked_at = ?, dirty = 1, local_revision = local_revision + 1 '
          'WHERE owner_key = ? AND deleted = 0 AND result_checked_at IS NULL '
          'AND id IN (${List.filled(chunk.length, '?').join(',')}) '
          'AND EXISTS (SELECT 1 FROM draw_results WHERE draw_results.round = purchase_history.round)',
          [now, owner, ...chunk],
        );
      }
      return count;
    });
    if (count > 0) _changed(owner);
    return count;
  }

  Future<List<Map<String, dynamic>>> getAllPurchaseHistory() async {
    final owner = _owner;
    final d = await db;
    return d.query(
      'purchase_history',
      where: 'owner_key = ? AND deleted = 0',
      whereArgs: [owner],
      orderBy: 'round DESC, id DESC',
    );
  }

  Future<void> deletePurchaseHistory(int id) =>
      _deletePrivate('purchase_history', id, _owner);

  void _validatePurchaseDate(DateTime date, int round) {
    final day = parsePurchaseDate(purchaseDateKey(date));
    final draw = DateTime.utc(2002, 12, 7).add(Duration(days: (round - 1) * 7));
    if (day == null ||
        day.isBefore(DateTime.utc(2002, 12, 2)) ||
        day.isAfter(draw)) {
      throw ArgumentError('구매일은 추첨일 이전 날짜로 선택해주세요.');
    }
  }

  Future<void> updatePurchaseDate(int id, DateTime date) async {
    final owner = _owner;
    final d = await db;
    await d.transaction((txn) async {
      final rows = await txn.query(
        'purchase_history',
        where: 'id = ? AND owner_key = ? AND deleted = 0',
        whereArgs: [id, owner],
      );
      if (rows.isEmpty) throw StateError('구매내역을 찾을 수 없습니다.');
      _validatePurchaseDate(date, rows.single['round'] as int);
      final previous = DateTime.tryParse(
        rows.single['purchase_date_updated_at'] as String? ?? '',
      );
      var updated = DateTime.now().toUtc();
      if (previous != null && !updated.isAfter(previous)) {
        updated = previous.add(const Duration(microseconds: 1));
      }
      await txn.rawUpdate(
        'UPDATE purchase_history SET purchase_date = ?, purchase_date_updated_at = ?, dirty = 1, local_revision = local_revision + 1 WHERE id = ? AND owner_key = ? AND deleted = 0',
        [purchaseDateKey(date), updated.toIso8601String(), id, owner],
      );
    });
    _changed(owner);
  }

  Future<List<Map<String, dynamic>>> getDeletedPurchaseHistory() async {
    final owner = _owner;
    final d = await db;
    final rows = await d.query(
      'purchase_history',
      where: 'owner_key = ?',
      whereArgs: [owner],
      orderBy: 'id DESC',
    );
    final ids = rows.map((row) => row['remote_id']).toSet();
    return rows
        .where(
          (row) =>
              row['deleted'] == 1 &&
              !ids.contains(_restoredId(row['remote_id'] as String)),
        )
        .toList();
  }

  Future<int?> restorePurchaseHistory(int id) async {
    final owner = _owner;
    final d = await db;
    final restored = await d.transaction<int?>((txn) async {
      final rows = await txn.query(
        'purchase_history',
        where: 'id = ? AND owner_key = ? AND deleted = 1',
        whereArgs: [id, owner],
      );
      if (rows.isEmpty) return null;
      final source = rows.single;
      if (!isValidPrivateRecord('purchase_history', source)) {
        throw StateError('번호 정보를 확인할 수 없어 복원하지 못했습니다.');
      }
      final remoteId = _restoredId(source['remote_id'] as String);
      final existing = await txn.query(
        'purchase_history',
        columns: ['id'],
        where: 'owner_key = ? AND remote_id = ?',
        whereArgs: [owner, remoteId],
      );
      if (existing.isNotEmpty) return null;
      return txn.insert('purchase_history', {
        for (final key in [
          'games',
          'created_at',
          'round',
          'draw_date',
          'source',
          'qr_fingerprint',
          'result_checked_at',
          'purchase_date',
          'purchase_date_updated_at',
        ])
          key: source[key],
        'owner_key': owner,
        'remote_id': remoteId,
        'dirty': 1,
        'local_revision': 1,
        'deleted': 0,
      });
    });
    if (restored != null) _changed(owner);
    return restored;
  }

  Future<int> getUnassignedLegacyRecordCount() async {
    final d = await db;
    var count = 0;
    for (final table in privateCollections) {
      count +=
          Sqflite.firstIntValue(
            await d.rawQuery(
              'SELECT COUNT(*) FROM $table WHERE owner_key IS NULL AND claimed_by IS NULL',
            ),
          ) ??
          0;
    }
    return count;
  }

  Future<int> getGuestRecordCount() async {
    final d = await db;
    var count = 0;
    for (final table in privateCollections) {
      count +=
          Sqflite.firstIntValue(
            await d.rawQuery(
              "SELECT COUNT(*) FROM $table WHERE owner_key = '' AND claimed_by IS NULL AND deleted = 0",
            ),
          ) ??
          0;
    }
    return count;
  }

  /// Call only after the user explicitly confirms these preserved records are theirs.
  /// Originals remain quarantined as a local recovery copy, even after import.
  Future<int> claimUnassignedLegacyRecords() =>
      _claimPreservedRecords(_accountKey, guest: false);

  /// Explicitly adopt guest-created records; login alone never transfers them.
  Future<int> claimGuestRecords() =>
      _claimPreservedRecords(_accountKey, guest: true);

  Future<int> _claimPreservedRecords(
    String? owner, {
    required bool guest,
  }) async {
    if (owner == null) {
      throw StateError('Sign in before recovering legacy records.');
    }
    final d = await db;
    final count = await d.transaction((txn) async {
      var count = 0;
      for (final table in privateCollections) {
        final rows = await txn.query(
          table,
          where: guest
              ? "owner_key = '' AND claimed_by IS NULL AND deleted = 0"
              : 'owner_key IS NULL AND claimed_by IS NULL',
        );
        for (final row in rows) {
          if (!isValidPrivateRecord(table, row)) continue;
          final existing = await txn.query(
            table,
            where: 'owner_key = ? AND remote_id = ?',
            whereArgs: [owner, row['remote_id']],
          );
          if (existing.isEmpty) {
            final values = Map<String, dynamic>.from(row)..remove('id');
            await txn.insert(table, {
              ...values,
              'owner_key': owner,
              'dirty': 1,
              'local_revision': 1,
            });
          }
          await txn.update(
            table,
            {
              'claimed_by': owner,
              if (guest) 'deleted': 1,
              if (guest) 'dirty': 0,
            },
            where: guest
                ? "id = ? AND owner_key = ''"
                : 'id = ? AND owner_key IS NULL',
            whereArgs: [row['id']],
          );
          count++;
        }
      }
      return count;
    });
    _changed(owner);
    return count;
  }

  /// All worker APIs require a captured owner; they never read the active account.
  Future<List<PendingPrivateRecord>> pendingChanges(String owner) async {
    final d = await db;
    final pending = <PendingPrivateRecord>[];
    for (final table in privateCollections) {
      final rows = await d.query(
        table,
        where: 'owner_key = ? AND dirty = 1',
        whereArgs: [owner],
      );
      pending.addAll(rows.map((row) => PendingPrivateRecord(table, row)));
    }
    return pending;
  }

  Future<void> acknowledgeUpload(
    String owner,
    PendingPrivateRecord change, {
    required bool remoteDeleted,
  }) async {
    final d = await db;
    if (remoteDeleted) {
      // Deletion is terminal across devices, including unsent local edits.
      await d.update(
        change.collection,
        {'deleted': 1, 'dirty': 0},
        where: 'owner_key = ? AND remote_id = ?',
        whereArgs: [owner, change.id],
      );
      _changed(owner);
    } else {
      // An edit/delete made during the request must remain pending.
      await d.update(
        change.collection,
        {'dirty': 0},
        where: 'owner_key = ? AND remote_id = ? AND local_revision = ?',
        whereArgs: [owner, change.id, change.revision],
      );
    }
  }

  Future<int?> syncWatermark(String owner, String collection) async {
    final d = await db;
    final rows = await d.query(
      'sync_checkpoints',
      where: 'owner_key = ? AND collection = ?',
      whereArgs: [owner, collection],
    );
    return rows.isEmpty ? null : rows.first['watermark'] as int;
  }

  Future<void> applyRemoteRecords(
    String owner,
    String collection,
    List<RemotePrivateRecord> records,
  ) async {
    if (!privateCollections.contains(collection)) {
      throw ArgumentError.value(collection);
    }
    final d = await db;
    var changed = false;
    await d.transaction((txn) async {
      int? watermark;
      for (final remote in records) {
        final stamp = remote.updatedAtMicros;
        if (stamp != null && (watermark == null || stamp > watermark)) {
          watermark = stamp;
        }
        final existing = await txn.query(
          collection,
          where: 'owner_key = ? AND remote_id = ?',
          whereArgs: [owner, remote.id],
        );
        final values = {
          ...remote.values,
          'owner_key': owner,
          'remote_id': remote.id,
          'dirty': 0,
          'deleted': remote.deleted ? 1 : 0,
        };
        if (collection == 'purchase_history' && existing.isNotEmpty) {
          final local = existing.first;
          values['result_checked_at'] = mergeResultCheckedAt(
            local['result_checked_at'],
            values['result_checked_at'],
          );
          values['qr_fingerprint'] ??= local['qr_fingerprint'];
          values.addAll(
            mergePurchaseDateFields(
              local['purchase_date'],
              local['purchase_date_updated_at'],
              values['purchase_date'],
              values['purchase_date_updated_at'],
            ),
          );
          if (!remote.deleted &&
              local['dirty'] == 1 &&
              (values['result_checked_at'] != local['result_checked_at'] ||
                  values['qr_fingerprint'] != local['qr_fingerprint'] ||
                  values['purchase_date'] != local['purchase_date'] ||
                  values['purchase_date_updated_at'] !=
                      local['purchase_date_updated_at'])) {
            await txn.update(
              collection,
              {
                'result_checked_at': values['result_checked_at'],
                'qr_fingerprint': values['qr_fingerprint'],
                'purchase_date': values['purchase_date'],
                'purchase_date_updated_at': values['purchase_date_updated_at'],
                'local_revision': (local['local_revision'] as int) + 1,
              },
              where: 'id = ?',
              whereArgs: [local['id']],
            );
            changed = true;
          }
        }
        if (existing.isEmpty) {
          await txn.insert(collection, values);
          changed = true;
        } else if ((remote.deleted ||
                (existing.first['dirty'] == 0 &&
                    existing.first['deleted'] == 0)) &&
            values.entries.any(
              (entry) => existing.first[entry.key] != entry.value,
            )) {
          await txn.update(
            collection,
            values,
            where: 'id = ?',
            whereArgs: [existing.first['id']],
          );
          changed = true;
        }
        // A server copy is proof of ownership. Preserve originals but remove them
        // from the unassigned recovery queue so another account cannot claim them.
        final signature = legacyRemoteId(collection, remote.values);
        final claimed = await txn.update(
          collection,
          {'claimed_by': owner},
          where: 'owner_key IS NULL AND claimed_by IS NULL AND remote_id = ?',
          whereArgs: [signature],
        );
        changed = changed || claimed > 0;
      }
      if (watermark != null) {
        final previous = await txn.query(
          'sync_checkpoints',
          where: 'owner_key = ? AND collection = ?',
          whereArgs: [owner, collection],
        );
        if (previous.isEmpty ||
            (previous.first['watermark'] as int) < watermark) {
          // INSERT OR REPLACE also works on older Android SQLite versions.
          await txn.insert('sync_checkpoints', {
            'owner_key': owner,
            'collection': collection,
            'watermark': watermark,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });
    if (changed) _changed(owner);
  }

  // ─────────────────────────────────────────
  // 통계: 번호 출현 빈도
  // ─────────────────────────────────────────

  /// 번호별 출현 빈도 (회차 범위)
  Future<List<Map<String, dynamic>>> getNumberFrequency({
    required int from,
    required int to,
  }) async {
    final Database d = await db;
    return d.rawQuery(
      '''
      SELECT number, COUNT(*) AS freq
      FROM (
        SELECT num1 AS number FROM draw_results WHERE round BETWEEN ? AND ?
        UNION ALL SELECT num2 FROM draw_results WHERE round BETWEEN ? AND ?
        UNION ALL SELECT num3 FROM draw_results WHERE round BETWEEN ? AND ?
        UNION ALL SELECT num4 FROM draw_results WHERE round BETWEEN ? AND ?
        UNION ALL SELECT num5 FROM draw_results WHERE round BETWEEN ? AND ?
        UNION ALL SELECT num6 FROM draw_results WHERE round BETWEEN ? AND ?
      )
      GROUP BY number
      ORDER BY number ASC
    ''',
      [from, to, from, to, from, to, from, to, from, to, from, to],
    );
  }

  /// 보너스 번호 출현 빈도
  Future<List<Map<String, dynamic>>> getBonusFrequency({
    required int from,
    required int to,
  }) async {
    final Database d = await db;
    return d.rawQuery(
      '''
      SELECT bonus AS number, COUNT(*) AS freq
      FROM draw_results
      WHERE round BETWEEN ? AND ?
      GROUP BY bonus
      ORDER BY number ASC
    ''',
      [from, to],
    );
  }

  /// 1~45 번호 전체 통계 (출현 빈도 + 미출현 횟수 + 마지막 출현 회차)
  Future<List<NumberStat>> getNumberStats({
    required int from,
    required int to,
    bool includeBonus = false,
  }) async {
    final int latest = await getLatestRound();
    final int totalRounds = to - from + 1;
    // 보너스 포함 시 회차당 7개 번호가 집계 대상
    final double avgFreq = totalRounds * (includeBonus ? 7 : 6) / 45;

    // 번호별 출현 빈도
    final List<Map<String, dynamic>> freqRows = await getNumberFrequency(
      from: from,
      to: to,
    );
    final Map<int, int> freqMap = {
      for (final r in freqRows) r['number'] as int: r['freq'] as int,
    };

    // 보너스 포함 시 보너스 빈도 합산
    if (includeBonus) {
      final List<Map<String, dynamic>> bonusRows = await getBonusFrequency(
        from: from,
        to: to,
      );
      for (final r in bonusRows) {
        final int n = r['number'] as int;
        freqMap[n] = (freqMap[n] ?? 0) + (r['freq'] as int);
      }
    }

    // 마지막 출현 회차 (전체 기준)
    final Database d = await db;
    final List<Map<String, dynamic>> lastRows = await d.rawQuery('''
      SELECT number, MAX(round) AS last_appeared
      FROM (
        SELECT num1 AS number, round FROM draw_results
        UNION ALL SELECT num2, round FROM draw_results
        UNION ALL SELECT num3, round FROM draw_results
        UNION ALL SELECT num4, round FROM draw_results
        UNION ALL SELECT num5, round FROM draw_results
        UNION ALL SELECT num6, round FROM draw_results
      )
      GROUP BY number
    ''');
    final Map<int, int> lastMap = {
      for (final r in lastRows) r['number'] as int: r['last_appeared'] as int,
    };

    return List<NumberStat>.generate(45, (i) {
      final int n = i + 1;
      final int lastAppeared = lastMap[n] ?? 0;
      return NumberStat(
        number: n,
        freq: freqMap[n] ?? 0,
        lastAppeared: lastAppeared,
        absenceCount: latest - lastAppeared,
        avgFreq: avgFreq,
      );
    });
  }

  // ─────────────────────────────────────────
  // 통계: 최근 N회 흐름
  // ─────────────────────────────────────────

  /// 최근 N회 회차 패턴 리스트
  Future<List<RoundPattern>> getRecentRoundPatterns(int recentN) async {
    final int latest = await getLatestRound();
    final int from = (latest - recentN + 1).clamp(1, latest);
    final List<Map<String, dynamic>> rows = await getDrawResultsInRange(
      from: from,
      to: latest,
    );

    return rows
        .map(
          (r) => RoundPattern(
            round: r['round'] as int,
            numbers: [
              r['num1'] as int,
              r['num2'] as int,
              r['num3'] as int,
              r['num4'] as int,
              r['num5'] as int,
              r['num6'] as int,
            ],
            bonus: r['bonus'] as int,
          ),
        )
        .toList();
  }

  // ─────────────────────────────────────────
  // 통계: 홀짝 비율 분포
  // ─────────────────────────────────────────

  /// 6개 번호 중 홀수 개수 분포 (0~6개)
  Future<Map<int, int>> getOddEvenDistribution({
    required int from,
    required int to,
  }) async {
    final Database d = await db;
    final List<Map<String, dynamic>> rows = await d.rawQuery(
      '''
      SELECT
        (CASE WHEN num1 % 2 = 1 THEN 1 ELSE 0 END +
         CASE WHEN num2 % 2 = 1 THEN 1 ELSE 0 END +
         CASE WHEN num3 % 2 = 1 THEN 1 ELSE 0 END +
         CASE WHEN num4 % 2 = 1 THEN 1 ELSE 0 END +
         CASE WHEN num5 % 2 = 1 THEN 1 ELSE 0 END +
         CASE WHEN num6 % 2 = 1 THEN 1 ELSE 0 END) AS odd_count,
        COUNT(*) AS freq
      FROM draw_results
      WHERE round BETWEEN ? AND ?
      GROUP BY odd_count
      ORDER BY odd_count ASC
    ''',
      [from, to],
    );

    final Map<int, int> result = {for (int i = 0; i <= 6; i++) i: 0};
    for (final r in rows) {
      result[r['odd_count'] as int] = r['freq'] as int;
    }
    return result;
  }

  // ─────────────────────────────────────────
  // 통계: 번호 합계 분포
  // ─────────────────────────────────────────

  /// 6개 번호 합계 분포 (구간별 집계)
  Future<Map<String, int>> getSumDistribution({
    required int from,
    required int to,
  }) async {
    final Database d = await db;
    final List<Map<String, dynamic>> rows = await d.rawQuery(
      '''
      SELECT (num1 + num2 + num3 + num4 + num5 + num6) AS total
      FROM draw_results
      WHERE round BETWEEN ? AND ?
    ''',
      [from, to],
    );

    // 구간: ~80, 81~100, 101~120, 121~140, 141~160, 161~180, 181~
    final Map<String, int> dist = {
      '~80': 0,
      '81~100': 0,
      '101~120': 0,
      '121~140': 0,
      '141~160': 0,
      '161~180': 0,
      '181~': 0,
    };
    for (final r in rows) {
      final int t = r['total'] as int;
      if (t <= 80) {
        dist['~80'] = dist['~80']! + 1;
      } else if (t <= 100) {
        dist['81~100'] = dist['81~100']! + 1;
      } else if (t <= 120) {
        dist['101~120'] = dist['101~120']! + 1;
      } else if (t <= 140) {
        dist['121~140'] = dist['121~140']! + 1;
      } else if (t <= 160) {
        dist['141~160'] = dist['141~160']! + 1;
      } else if (t <= 180) {
        dist['161~180'] = dist['161~180']! + 1;
      } else {
        dist['181~'] = dist['181~']! + 1;
      }
    }
    return dist;
  }

  // ─────────────────────────────────────────
  // 통계: 구간 분포
  // ─────────────────────────────────────────

  /// 1~10, 11~20, 21~30, 31~40, 41~45 구간별 출현 수
  Future<Map<String, int>> getRangeDistribution({
    required int from,
    required int to,
  }) async {
    final Database d = await db;
    final List<Map<String, dynamic>> rows = await d.rawQuery(
      '''
      SELECT number FROM (
        SELECT num1 AS number FROM draw_results WHERE round BETWEEN ? AND ?
        UNION ALL SELECT num2 FROM draw_results WHERE round BETWEEN ? AND ?
        UNION ALL SELECT num3 FROM draw_results WHERE round BETWEEN ? AND ?
        UNION ALL SELECT num4 FROM draw_results WHERE round BETWEEN ? AND ?
        UNION ALL SELECT num5 FROM draw_results WHERE round BETWEEN ? AND ?
        UNION ALL SELECT num6 FROM draw_results WHERE round BETWEEN ? AND ?
      )
    ''',
      [from, to, from, to, from, to, from, to, from, to, from, to],
    );

    final Map<String, int> dist = {
      '1~10': 0,
      '11~20': 0,
      '21~30': 0,
      '31~40': 0,
      '41~45': 0,
    };
    for (final r in rows) {
      final int n = r['number'] as int;
      if (n <= 10) {
        dist['1~10'] = dist['1~10']! + 1;
      } else if (n <= 20) {
        dist['11~20'] = dist['11~20']! + 1;
      } else if (n <= 30) {
        dist['21~30'] = dist['21~30']! + 1;
      } else if (n <= 40) {
        dist['31~40'] = dist['31~40']! + 1;
      } else {
        dist['41~45'] = dist['41~45']! + 1;
      }
    }
    return dist;
  }

  // ─────────────────────────────────────────
  // 통계: 끝수(일의 자리) 분포
  // ─────────────────────────────────────────

  Future<Map<int, int>> getEndingDigitDistribution({
    required int from,
    required int to,
  }) async {
    final Database d = await db;
    final List<Map<String, dynamic>> rows = await d.rawQuery(
      '''
      SELECT (number % 10) AS ending, COUNT(*) AS freq
      FROM (
        SELECT num1 AS number FROM draw_results WHERE round BETWEEN ? AND ?
        UNION ALL SELECT num2 FROM draw_results WHERE round BETWEEN ? AND ?
        UNION ALL SELECT num3 FROM draw_results WHERE round BETWEEN ? AND ?
        UNION ALL SELECT num4 FROM draw_results WHERE round BETWEEN ? AND ?
        UNION ALL SELECT num5 FROM draw_results WHERE round BETWEEN ? AND ?
        UNION ALL SELECT num6 FROM draw_results WHERE round BETWEEN ? AND ?
      )
      GROUP BY ending
      ORDER BY ending ASC
    ''',
      [from, to, from, to, from, to, from, to, from, to, from, to],
    );

    final Map<int, int> result = {for (int i = 0; i <= 9; i++) i: 0};
    for (final r in rows) {
      result[r['ending'] as int] = r['freq'] as int;
    }
    return result;
  }

  // ─────────────────────────────────────────
  // 통계: 연번(연속 번호 쌍) 분포
  // ─────────────────────────────────────────

  /// 회차별 연속 번호 쌍 개수 분포.
  /// 예: [1,2,10,20,30,40] => 1쌍, [1,2,3,10,20,30] => 2쌍
  Future<Map<int, int>> getConsecutivePairDistribution({
    required int from,
    required int to,
  }) async {
    final Database d = await db;
    final List<Map<String, dynamic>> rows = await d.rawQuery(
      '''
      SELECT consecutive_pairs, COUNT(*) AS freq
      FROM (
        SELECT
          (CASE WHEN num2 - num1 = 1 THEN 1 ELSE 0 END +
           CASE WHEN num3 - num2 = 1 THEN 1 ELSE 0 END +
           CASE WHEN num4 - num3 = 1 THEN 1 ELSE 0 END +
           CASE WHEN num5 - num4 = 1 THEN 1 ELSE 0 END +
           CASE WHEN num6 - num5 = 1 THEN 1 ELSE 0 END) AS consecutive_pairs
        FROM draw_results
        WHERE round BETWEEN ? AND ?
      )
      GROUP BY consecutive_pairs
      ORDER BY consecutive_pairs ASC
      ''',
      [from, to],
    );

    final Map<int, int> result = {for (int i = 0; i <= 5; i++) i: 0};
    for (final r in rows) {
      result[r['consecutive_pairs'] as int] = r['freq'] as int;
    }
    return result;
  }

  /// 연속 조합(예: 1-2, 2-3 ... / 1-2-3, 2-3-4 ...)별 출현 횟수.
  /// key = 시작 번호(start), value = 조합 출현 횟수
  Future<Map<int, int>> getConsecutiveSequenceFrequency({
    required int sequenceLength,
    required int from,
    required int to,
  }) async {
    if (sequenceLength < 2) {
      throw ArgumentError.value(
        sequenceLength,
        'sequenceLength',
        '2 이상이어야 합니다.',
      );
    }

    final List<Map<String, dynamic>> rows = await getDrawResultsInRange(
      from: from,
      to: to,
    );
    final int maxStart = 45 - sequenceLength + 1;
    final Map<int, int> result = {
      for (int start = 1; start <= maxStart; start++) start: 0,
    };

    for (final row in rows) {
      final Set<int> numbers = <int>{
        row['num1'] as int,
        row['num2'] as int,
        row['num3'] as int,
        row['num4'] as int,
        row['num5'] as int,
        row['num6'] as int,
      };

      for (int start = 1; start <= maxStart; start++) {
        bool allIncluded = true;
        for (int offset = 0; offset < sequenceLength; offset++) {
          if (!numbers.contains(start + offset)) {
            allIncluded = false;
            break;
          }
        }
        if (allIncluded) {
          result[start] = (result[start] ?? 0) + 1;
        }
      }
    }
    return result;
  }

  // ─────────────────────────────────────────
  // 통계: 동반 출현
  // ─────────────────────────────────────────

  /// 기준 번호가 등장한 회차 수 (한 회차당 최대 1회)
  Future<int> getTargetAppearCount({
    required int targetNumber,
    required int from,
    required int to,
  }) async {
    final Database d = await db;
    final List<Map<String, dynamic>> rows = await d.rawQuery(
      '''
      SELECT COUNT(*) AS cnt
      FROM draw_results
      WHERE round BETWEEN ? AND ?
        AND ? IN (num1, num2, num3, num4, num5, num6)
      ''',
      [from, to, targetNumber],
    );
    return (rows.first['cnt'] as int?) ?? 0;
  }

  /// 기준 번호와 함께 등장한 번호 TOP N
  Future<List<Map<String, dynamic>>> getCoOccurrenceTop({
    required int targetNumber,
    required int from,
    required int to,
    int topN = 5,
  }) async {
    final Database d = await db;
    return d.rawQuery(
      '''
      SELECT number, COUNT(*) AS freq
      FROM (
        SELECT num1 AS number
        FROM draw_results
        WHERE round BETWEEN ? AND ?
          AND ? IN (num1, num2, num3, num4, num5, num6)
          AND num1 != ?
        UNION ALL
        SELECT num2 AS number
        FROM draw_results
        WHERE round BETWEEN ? AND ?
          AND ? IN (num1, num2, num3, num4, num5, num6)
          AND num2 != ?
        UNION ALL
        SELECT num3 AS number
        FROM draw_results
        WHERE round BETWEEN ? AND ?
          AND ? IN (num1, num2, num3, num4, num5, num6)
          AND num3 != ?
        UNION ALL
        SELECT num4 AS number
        FROM draw_results
        WHERE round BETWEEN ? AND ?
          AND ? IN (num1, num2, num3, num4, num5, num6)
          AND num4 != ?
        UNION ALL
        SELECT num5 AS number
        FROM draw_results
        WHERE round BETWEEN ? AND ?
          AND ? IN (num1, num2, num3, num4, num5, num6)
          AND num5 != ?
        UNION ALL
        SELECT num6 AS number
        FROM draw_results
        WHERE round BETWEEN ? AND ?
          AND ? IN (num1, num2, num3, num4, num5, num6)
          AND num6 != ?
      )
      GROUP BY number
      ORDER BY freq DESC, number ASC
      LIMIT ?
      ''',
      [
        from,
        to,
        targetNumber,
        targetNumber,
        from,
        to,
        targetNumber,
        targetNumber,
        from,
        to,
        targetNumber,
        targetNumber,
        from,
        to,
        targetNumber,
        targetNumber,
        from,
        to,
        targetNumber,
        targetNumber,
        from,
        to,
        targetNumber,
        targetNumber,
        topN,
      ],
    );
  }
}
