import 'dart:async';
import 'package:flutter/foundation.dart';
import '../db/lotto_database.dart';
import '../models/purchase_record.dart';
import '../models/purchase_insights.dart';
import '../models/scanned_ticket.dart';
import 'lotto_sync_service.dart';

typedef DrawDetailLoader = Future<Map<String, dynamic>?> Function(int round);

/// One account-scoped snapshot shared by home and profile. Never marks results read.
class PurchaseInsightsController extends ChangeNotifier {
  PurchaseInsightsController({
    required this.database,
    DrawDetailLoader? loadDetail,
    this.onRecordsChanged,
  }) : _loadDetail = loadDetail ?? LottoSyncService.fetchDrawDetail,
       _owner = database.accountKey {
    database.revision.addListener(_changed);
    database.drawRevision.addListener(_changed);
    unawaited(refresh());
  }
  final LottoDatabase database;
  final VoidCallback? onRecordsChanged;
  final DrawDetailLoader _loadDetail;
  final String? _owner;
  final _prizes = <int, Map<int, int>>{};
  final _pending = <int, Future<Map<String, dynamic>?>>{};
  final _attempted = <int>{};
  PurchaseInsights value = PurchaseInsights(records: [], draws: {});
  bool loading = true;
  bool failed = false;
  bool _disposed = false;
  int _generation = 0;
  bool get _active => !_disposed && database.accountKey == _owner;
  bool get isActive => _active;
  Future<void> addPurchase(
    List<List<int>> games,
    int round,
    DateTime day,
  ) async {
    if (!_active) throw StateError('계정이 변경되었습니다.');
    await database.insertPurchaseHistory(
      games: games,
      round: round,
      source: 'manual',
      purchaseDate: day,
    );
    if (!_active) throw StateError('계정이 변경되었습니다.');
    onRecordsChanged?.call();
    await refresh();
  }

  Future<QrBatchSaveResult> addQrPurchases(
    List<ScannedTicket> tickets,
    DateTime day,
  ) async {
    if (!_active) throw StateError('계정이 변경되었습니다.');
    final result = await database.insertQrPurchaseBatch(
      tickets,
      purchaseDate: day,
    );
    if (!_active) throw StateError('계정이 변경되었습니다.');
    onRecordsChanged?.call();
    await refresh();
    return result;
  }

  Future<void> changePurchaseDate(int id, DateTime day) async {
    if (!_active) throw StateError('계정이 변경되었습니다.');
    await database.updatePurchaseDate(id, day);
    if (!_active) throw StateError('계정이 변경되었습니다.');
    onRecordsChanged?.call();
    await refresh();
  }

  void _changed() {
    if (!_active) {
      if (!_disposed) {
        _generation++;
        value = PurchaseInsights(records: [], draws: {});
        loading = false;
        notifyListeners();
      }
      return;
    }
    unawaited(refresh());
  }

  Future<void> refresh({bool retryPrizes = false}) async {
    if (!_active) return;
    if (retryPrizes) _attempted.clear();
    final generation = ++_generation;
    try {
      final rows = await database.getAllPurchaseHistory();
      final records = rows.map(PurchaseRecord.fromDb).toList();
      final draws = await database.getDrawResultsForRounds(
        records.map((r) => r.round).toSet(),
      );
      if (!_active || generation != _generation) return;
      value = PurchaseInsights(
        records: records,
        draws: draws,
        prizes: Map.of(_prizes),
      );
      loading = false;
      failed = false;
      notifyListeners();
      final rounds = value.games
          .where((g) => g.isWin && g.amount == null)
          .map((g) => g.record.round)
          .toSet()
          .where((r) => !_attempted.contains(r))
          .toList();
      // Bound concurrent public reads; fixed 4th/5th prizes require no request.
      for (var i = 0; i < rounds.length; i += 3) {
        if (!_active || generation != _generation) return;
        final batch = rounds.skip(i).take(3).toList();
        await Future.wait(
          batch.map((round) async {
            try {
              final detail = await _pending.putIfAbsent(
                round,
                () => _loadDetail(round).timeout(const Duration(seconds: 8)),
              );
              if (!_active) return;
              final raw = detail?['prizes'];
              final parsed = <int, int>{};
              if (raw is Map) {
                for (var rank = 1; rank <= 3; rank++) {
                  final row = raw['$rank'];
                  final amount = row is Map ? row['perPrize'] : null;
                  if (amount is num &&
                      amount.isFinite &&
                      amount > 0 &&
                      amount == amount.roundToDouble()) {
                    parsed[rank] = amount.toInt();
                  }
                }
              }
              if (parsed.isNotEmpty) _prizes[round] = parsed;
            } catch (_) {
              // Keep unknown prizes explicit; retry from the records refresh action.
            } finally {
              _pending.remove(round);
              _attempted.add(round);
            }
          }),
        );
        if (!_active || generation != _generation) return;
        value = PurchaseInsights(
          records: records,
          draws: draws,
          prizes: Map.of(_prizes),
        );
        notifyListeners();
      }
    } catch (_) {
      if (_active && generation == _generation) {
        loading = false;
        failed = true;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    database.revision.removeListener(_changed);
    database.drawRevision.removeListener(_changed);
    super.dispose();
  }
}
