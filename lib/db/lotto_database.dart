import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/number_stat.dart';

class LottoDatabase {
  LottoDatabase._();
  static final LottoDatabase instance = LottoDatabase._();

  static Database? _db;

  Future<Database> get db async {
    _db ??= await _initDb();
    return _db!;
  }

  // ─────────────────────────────────────────
  // 초기화
  // ─────────────────────────────────────────

  Future<Database> _initDb() async {
    final String dbPath = join(await getDatabasesPath(), 'lotto.db');
    return openDatabase(
      dbPath,
      version: 2,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
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
    await _seedDrawResults(db);
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

  /// 새 회차 당첨번호를 SQLite에 삽입 (이미 있으면 무시)
  Future<void> insertDrawResult({
    required int round,
    required List<int> numbers,
    required int bonus,
  }) async {
    final Database d = await db;
    await d.insert('draw_results', {
      'round': round,
      'num1': numbers[0],
      'num2': numbers[1],
      'num3': numbers[2],
      'num4': numbers[3],
      'num5': numbers[4],
      'num6': numbers[5],
      'bonus': bonus,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
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
    final conditions = List.generate(
      sequenceLength,
      (i) {
        final n = startNumber + i;
        return '(num1=$n OR num2=$n OR num3=$n OR num4=$n OR num5=$n OR num6=$n)';
      },
    ).join(' AND ');
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

  Future<int> insertNumberSet({
    required List<List<int>> games,
    int? round,
    String? qrRaw,
  }) async {
    final Database d = await db;
    return d.insert('number_sets', {
      'games': jsonEncode(games),
      'created_at': DateTime.now().toIso8601String(),
      'is_purchased': 0,
      'round': round,
      'qr_raw': qrRaw,
    });
  }

  Future<int> insertNumberSetFromSync({
    required List<List<int>> games,
    required String createdAt,
    required bool isPurchased,
    int? round,
    String? qrRaw,
  }) async {
    final Database d = await db;
    return d.insert('number_sets', {
      'games': jsonEncode(games),
      'created_at': createdAt,
      'is_purchased': isPurchased ? 1 : 0,
      'round': round,
      'qr_raw': qrRaw,
    }, conflictAlgorithm: ConflictAlgorithm.abort);
  }

  Future<List<Map<String, dynamic>>> getAllNumberSets() async {
    final Database d = await db;
    return d.query('number_sets', orderBy: 'id DESC');
  }

  Future<void> updatePurchased(int id, {required bool isPurchased}) async {
    final Database d = await db;
    await d.update(
      'number_sets',
      {'is_purchased': isPurchased ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteNumberSet(int id) async {
    final Database d = await db;
    await d.delete('number_sets', where: 'id = ?', whereArgs: [id]);
  }

  // ─────────────────────────────────────────
  // purchase_history CRUD
  // ─────────────────────────────────────────

  Future<int> insertPurchaseHistory({
    required List<List<int>> games,
    required int round,
    required String source, // 'qr' | 'manual'
  }) async {
    final Database d = await db;
    return d.insert('purchase_history', {
      'games': jsonEncode(games),
      'round': round,
      'draw_date': drawDateFromRound(round),
      'source': source,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<int> insertPurchaseHistoryFromSync({
    required List<List<int>> games,
    required int round,
    required String source,
    required String createdAt,
    required String drawDate,
  }) async {
    final Database d = await db;
    return d.insert('purchase_history', {
      'games': jsonEncode(games),
      'round': round,
      'draw_date': drawDate,
      'source': source,
      'created_at': createdAt,
    }, conflictAlgorithm: ConflictAlgorithm.abort);
  }

  Future<List<Map<String, dynamic>>> getAllPurchaseHistory() async {
    final Database d = await db;
    return d.query('purchase_history', orderBy: 'round DESC, id DESC');
  }

  Future<void> deletePurchaseHistory(int id) async {
    final Database d = await db;
    await d.delete('purchase_history', where: 'id = ?', whereArgs: [id]);
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
      } else if (t <= 100)
        dist['81~100'] = dist['81~100']! + 1;
      else if (t <= 120)
        dist['101~120'] = dist['101~120']! + 1;
      else if (t <= 140)
        dist['121~140'] = dist['121~140']! + 1;
      else if (t <= 160)
        dist['141~160'] = dist['141~160']! + 1;
      else if (t <= 180)
        dist['161~180'] = dist['161~180']! + 1;
      else
        dist['181~'] = dist['181~']! + 1;
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
      } else if (n <= 20)
        dist['11~20'] = dist['11~20']! + 1;
      else if (n <= 30)
        dist['21~30'] = dist['21~30']! + 1;
      else if (n <= 40)
        dist['31~40'] = dist['31~40']! + 1;
      else
        dist['41~45'] = dist['41~45']! + 1;
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
