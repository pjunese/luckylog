import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../services/lotto_qr_policy.dart';

/// A validated scan. The full token stays in memory for opening the official
/// result page; persistence and synchronization use only its SHA-256 digest.
class ScannedTicket {
  ScannedTicket._({
    required this.uri,
    required this.round,
    required List<List<int>> games,
    required this.fingerprint,
  }) : games = List.unmodifiable(
         games.map((game) => List<int>.unmodifiable(game)),
       );

  final Uri uri;
  final int round;
  final List<List<int>> games;
  final String fingerprint;

  static ScannedTicket? tryParse(String raw) {
    final uri = LottoQrPolicy.fromScan(raw);
    if (uri == null) return null;
    final round = LottoQrPolicy.round(uri);
    final games = LottoQrPolicy.games(uri);
    final token = uri.queryParameters['v'];
    if (round == null || games == null || token == null) return null;
    return ScannedTicket._(
      uri: uri,
      round: round,
      games: games,
      fingerprint: sha256.convert(utf8.encode(token)).toString(),
    );
  }
}

class QrBatchSaveResult {
  const QrBatchSaveResult({
    required this.insertedCount,
    required this.duplicateCount,
    required this.deletedCount,
  });
  final int insertedCount;
  final int duplicateCount;
  final int deletedCount;
}
