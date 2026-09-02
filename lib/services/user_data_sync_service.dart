import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../db/lotto_database.dart';
import 'user_service.dart';

/// 로그인 사용자 데이터(번호세트/구매이력) 백업/복원 동기화 서비스.
///
/// 설계:
/// - 비로그인: 로컬 SQLite만 사용
/// - 로그인: users/{accountKey} 하위 컬렉션과 양방향 동기화
class UserDataSyncService {
  UserDataSyncService._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const int _maxBatchOps = 400;

  static Future<void> syncOnLogin({
    required String accountKey,
    required int userNumber,
  }) async {
    try {
      await _upsertUserDoc(accountKey: accountKey, userNumber: userNumber);
      await UserService.syncNicknameFromFirestore(accountKey);
      await _pullRemoteToLocal(accountKey: accountKey);
      await pushLocalSnapshot(accountKey: accountKey, userNumber: userNumber);
      debugPrint('[UserSync] login sync 완료 ($accountKey)');
    } catch (e, st) {
      debugPrint('[UserSync] login sync 실패: $e');
      debugPrint('$st');
    }
  }

  /// 로컬 스냅샷을 서버에 반영한다.
  /// (삭제 포함: 로컬에 없는 문서는 서버에서도 제거)
  static Future<void> pushLocalSnapshot({
    required String accountKey,
    required int userNumber,
  }) async {
    final userRef = _firestore.collection('users').doc(accountKey);
    final setsRef = userRef.collection('number_sets');
    final historyRef = userRef.collection('purchase_history');

    final localSetRows = await LottoDatabase.instance.getAllNumberSets();
    final localHistoryRows = await LottoDatabase.instance
        .getAllPurchaseHistory();

    final remoteSets = await setsRef.get();
    final remoteHistory = await historyRef.get();

    final List<void Function(WriteBatch)> ops = [];
    final Set<String> localSetDocIds = <String>{};
    final Set<String> localHistoryDocIds = <String>{};

    for (final row in localSetRows) {
      final games = _decodeGames(row['games']);
      final createdAt = row['created_at'] as String? ?? '';
      if (createdAt.isEmpty || games.isEmpty) {
        continue;
      }
      final signature = _setSignature(createdAt: createdAt, games: games);
      final docId = _docId('set|$signature');
      localSetDocIds.add(docId);

      final round = row['round'] as int?;
      final qrRaw = row['qr_raw'] as String?;
      final isPurchased = ((row['is_purchased'] as int?) ?? 0) == 1;

      ops.add((batch) {
        batch.set(setsRef.doc(docId), {
          'games': jsonEncode(games),
          'createdAt': createdAt,
          'isPurchased': isPurchased,
          'round': round,
          'qrRaw': qrRaw,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      });
    }

    for (final doc in remoteSets.docs) {
      if (localSetDocIds.contains(doc.id)) {
        continue;
      }
      ops.add((batch) => batch.delete(doc.reference));
    }

    for (final row in localHistoryRows) {
      final games = _decodeGames(row['games']);
      final createdAt = row['created_at'] as String? ?? '';
      final round = row['round'] as int? ?? 0;
      final source = row['source'] as String? ?? 'manual';
      if (createdAt.isEmpty || round <= 0 || games.isEmpty) {
        continue;
      }

      final signature = _historySignature(
        createdAt: createdAt,
        games: games,
        round: round,
        source: source,
      );
      final docId = _docId('history|$signature');
      localHistoryDocIds.add(docId);

      final drawDate =
          row['draw_date'] as String? ?? LottoDatabase.drawDateFromRound(round);

      ops.add((batch) {
        batch.set(historyRef.doc(docId), {
          'games': jsonEncode(games),
          'round': round,
          'drawDate': drawDate,
          'source': source,
          'createdAt': createdAt,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      });
    }

    for (final doc in remoteHistory.docs) {
      if (localHistoryDocIds.contains(doc.id)) {
        continue;
      }
      ops.add((batch) => batch.delete(doc.reference));
    }

    await _commitInChunks(ops);
    await _upsertUserDoc(accountKey: accountKey, userNumber: userNumber);
  }

  static Future<void> _pullRemoteToLocal({required String accountKey}) async {
    final userRef = _firestore.collection('users').doc(accountKey);
    final remoteSets = await userRef.collection('number_sets').get();
    final remoteHistory = await userRef.collection('purchase_history').get();

    final localSetRows = await LottoDatabase.instance.getAllNumberSets();
    final localHistoryRows = await LottoDatabase.instance
        .getAllPurchaseHistory();

    final Map<String, Map<String, dynamic>> localSetBySig =
        <String, Map<String, dynamic>>{};
    for (final row in localSetRows) {
      final games = _decodeGames(row['games']);
      final createdAt = row['created_at'] as String? ?? '';
      if (createdAt.isEmpty || games.isEmpty) continue;
      localSetBySig[_setSignature(createdAt: createdAt, games: games)] = row;
    }

    final Map<String, Map<String, dynamic>> localHistoryBySig =
        <String, Map<String, dynamic>>{};
    for (final row in localHistoryRows) {
      final games = _decodeGames(row['games']);
      final createdAt = row['created_at'] as String? ?? '';
      final round = row['round'] as int? ?? 0;
      final source = row['source'] as String? ?? 'manual';
      if (createdAt.isEmpty || round <= 0 || games.isEmpty) continue;
      localHistoryBySig[_historySignature(
            createdAt: createdAt,
            games: games,
            round: round,
            source: source,
          )] =
          row;
    }

    for (final doc in remoteSets.docs) {
      final data = doc.data();
      final games = _decodeGames(data['games']);
      final createdAt = _toIsoString(data['createdAt'] ?? data['created_at']);
      if (games.isEmpty || createdAt.isEmpty) continue;

      final signature = _setSignature(createdAt: createdAt, games: games);
      final localRow = localSetBySig[signature];
      final bool remotePurchased = _toBool(
        data['isPurchased'] ?? data['is_purchased'],
      );

      if (localRow == null) {
        await LottoDatabase.instance.insertNumberSetFromSync(
          games: games,
          createdAt: createdAt,
          isPurchased: remotePurchased,
          round: _toInt(data['round']),
          qrRaw: data['qrRaw'] as String? ?? data['qr_raw'] as String?,
        );
        continue;
      }

      final localPurchased = ((localRow['is_purchased'] as int?) ?? 0) == 1;
      if (localPurchased != remotePurchased) {
        await LottoDatabase.instance.updatePurchased(
          localRow['id'] as int,
          isPurchased: remotePurchased,
        );
      }
    }

    for (final doc in remoteHistory.docs) {
      final data = doc.data();
      final games = _decodeGames(data['games']);
      final createdAt = _toIsoString(data['createdAt'] ?? data['created_at']);
      final round = _toInt(data['round']);
      final source = data['source'] as String? ?? 'manual';
      if (games.isEmpty || createdAt.isEmpty || round <= 0) continue;

      final signature = _historySignature(
        createdAt: createdAt,
        games: games,
        round: round,
        source: source,
      );
      if (localHistoryBySig.containsKey(signature)) {
        continue;
      }

      await LottoDatabase.instance.insertPurchaseHistoryFromSync(
        games: games,
        round: round,
        source: source,
        createdAt: createdAt,
        drawDate:
            data['drawDate'] as String? ??
            data['draw_date'] as String? ??
            LottoDatabase.drawDateFromRound(round),
      );
    }
  }

  static Future<void> _upsertUserDoc({
    required String accountKey,
    required int userNumber,
  }) async {
    final userRef = _firestore.collection('users').doc(accountKey);
    final splitAt = accountKey.indexOf(':');
    final provider = splitAt > 0 ? accountKey.substring(0, splitAt) : 'unknown';
    final providerUserId = splitAt > 0
        ? accountKey.substring(splitAt + 1)
        : accountKey;

    String? fcmToken;
    try {
      fcmToken = await FirebaseMessaging.instance.getToken();
    } catch (e) {
      // 토큰이 없으면 개인 당첨/낙첨 알림을 받지 못한다.
      debugPrint('[UserSync] FCM 토큰 획득 실패 - 개인 알림 수신 불가: $e');
    }

    await userRef.set({
      'provider': provider,
      'providerUserId': providerUserId,
      'userNumber': userNumber,
      'lastLoginAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'schemaVersion': 1,
      if (fcmToken != null) 'fcmToken': fcmToken,
    }, SetOptions(merge: true));
  }

  static Future<void> _commitInChunks(
    List<void Function(WriteBatch)> operations,
  ) async {
    if (operations.isEmpty) {
      return;
    }

    int index = 0;
    while (index < operations.length) {
      final end = (index + _maxBatchOps < operations.length)
          ? index + _maxBatchOps
          : operations.length;
      final batch = _firestore.batch();
      for (int i = index; i < end; i++) {
        operations[i](batch);
      }
      await batch.commit();
      index = end;
    }
  }

  static String _setSignature({
    required String createdAt,
    required List<List<int>> games,
  }) {
    return '$createdAt|${jsonEncode(games)}';
  }

  static String _historySignature({
    required String createdAt,
    required List<List<int>> games,
    required int round,
    required String source,
  }) {
    return '$createdAt|$round|$source|${jsonEncode(games)}';
  }

  static String _docId(String signature) {
    return base64UrlEncode(utf8.encode(signature)).replaceAll('=', '');
  }

  static List<List<int>> _decodeGames(dynamic value) {
    if (value == null) return const <List<int>>[];

    try {
      if (value is String) {
        final decoded = jsonDecode(value) as List<dynamic>;
        return decoded
            .map((e) => (e as List).map((n) => n as int).toList())
            .toList();
      }
      if (value is List) {
        return value
            .map((e) => (e as List).map((n) => _toInt(n)).toList())
            .toList();
      }
    } catch (_) {
      return const <List<int>>[];
    }
    return const <List<int>>[];
  }

  static int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  static bool _toBool(dynamic value) {
    if (value is bool) return value;
    if (value is int) return value == 1;
    if (value is num) return value.toInt() == 1;
    if (value is String) {
      return value == '1' || value.toLowerCase() == 'true';
    }
    return false;
  }

  static String _toIsoString(dynamic value) {
    if (value == null) {
      return '';
    }
    if (value is Timestamp) {
      return value.toDate().toIso8601String();
    }
    if (value is DateTime) {
      return value.toIso8601String();
    }
    if (value is String) {
      return value;
    }
    return '';
  }
}
