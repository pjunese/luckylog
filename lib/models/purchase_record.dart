import 'dart:convert';
import 'purchase_date.dart';

/// 실제 구매한 복권 1건 (QR 스캔 또는 수동 입력).
class PurchaseRecord {
  const PurchaseRecord({
    required this.id,
    required this.games,
    required this.round,
    required this.drawDate,
    required this.source,
    required this.createdAt,
    this.qrFingerprint,
    this.resultCheckedAt,
    this.purchaseDate,
  });

  final int id;
  final List<List<int>> games;
  final int round;
  final String drawDate;
  final String source; // 'qr' | 'manual'
  final DateTime createdAt;
  final String? qrFingerprint;
  final DateTime? resultCheckedAt;
  final DateTime? purchaseDate;
  bool get isResultChecked => resultCheckedAt != null;

  factory PurchaseRecord.fromDb(Map<String, dynamic> row) {
    final List<List<int>> games =
        (jsonDecode(row['games'] as String) as List<dynamic>)
            .map((g) => List<int>.from(g as List))
            .toList();
    return PurchaseRecord(
      id: row['id'] as int,
      games: games,
      round: row['round'] as int,
      drawDate: row['draw_date'] as String,
      source: row['source'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
      qrFingerprint: row['qr_fingerprint'] as String?,
      resultCheckedAt: DateTime.tryParse(
        row['result_checked_at'] as String? ?? '',
      ),
      purchaseDate: parsePurchaseDate(row['purchase_date']),
    );
  }
}
