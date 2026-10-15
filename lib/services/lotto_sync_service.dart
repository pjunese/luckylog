import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../db/lotto_database.dart';

/// Firestore ↔ 로컬 SQLite 동기화 서비스
class LottoSyncService {
  LottoSyncService._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static Future<int>? _running;

  /// 앱 시작 시 호출. 로컬 DB보다 새 회차가 있으면 동기화.
  /// 반환값: 새로 추가된 회차 수 (0 = 이미 최신)
  static Future<int> syncIfNeeded() =>
      _running ??= _sync().whenComplete(() => _running = null);

  static Future<int> _sync() async {
    try {
      // Firestore meta 문서에서 최신 회차 확인
      final metaDoc = await _firestore
          .collection('meta')
          .doc('latest')
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 12));
      if (!metaDoc.exists) return 0;

      final remoteRound = metaDoc.data()!['round'] as int;
      final localRound = await LottoDatabase.instance.getLatestRound();

      debugPrint('[LottoSync] remote=$remoteRound, local=$localRound');

      if (remoteRound <= localRound) {
        debugPrint('[LottoSync] 이미 최신 상태');
        return 0;
      }

      // 누락된 회차들 순서대로 가져와서 로컬 저장
      int added = 0;
      for (int r = localRound + 1; r <= remoteRound; r++) {
        final doc = await _firestore
            .collection('lotto_draws')
            .doc(r.toString())
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 12));
        if (!doc.exists) continue;

        final data = doc.data()!;
        final numbers = List<int>.from(data['numbers'] as List);
        if (numbers.length != 6) continue;

        await LottoDatabase.instance.insertDrawResult(
          round: r,
          numbers: numbers,
          bonus: data['bonus'] as int,
        );
        added++;
      }
      return added;
    } catch (e, st) {
      // 네트워크 오류 등 — 조용히 실패 (로컬 데이터로 동작)
      debugPrint('[LottoSync] 에러: $e');
      debugPrint('[LottoSync] 스택: $st');
      return 0;
    }
  }

  /// 특정 회차의 prizes/stores 상세 데이터 Firestore에서 가져오기
  static Future<Map<String, dynamic>?> fetchDrawDetail(int round) async {
    try {
      final doc = await _firestore
          .collection('lotto_draws')
          .doc(round.toString())
          .get();
      if (!doc.exists) return null;
      return doc.data();
    } catch (e) {
      debugPrint('[LottoSync] fetchDrawDetail error: $e');
      return null;
    }
  }
}
