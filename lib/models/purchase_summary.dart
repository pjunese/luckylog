import '../core/formatters.dart' as formatters;
import 'draw_result.dart';
import 'purchase_record.dart';

enum PurchaseReviewStatus {
  awaitingDraw('추첨 대기'),
  awaitingResult('결과 업데이트 대기'),
  unchecked('결과 미확인'),
  checked('확인 완료');

  const PurchaseReviewStatus(this.label);
  final String label;
}

/// A result is available only when the actual, valid winning numbers are loaded.
/// A date or a newer round number can explain a delay, but cannot confirm a draw.
bool hasActualDraw(DrawResult? draw, {int? round}) =>
    draw != null &&
    (round == null || draw.round == round) &&
    isLottoGame(draw.winningNumbers) &&
    draw.bonusNumber >= 1 &&
    draw.bonusNumber <= 45 &&
    !draw.winningNumbers.contains(draw.bonusNumber);

bool isLottoGame(List<int> game) =>
    game.length == 6 &&
    game.toSet().length == 6 &&
    game.every((number) => number >= 1 && number <= 45);

class PurchaseGameResult {
  const PurchaseGameResult({
    required this.matches,
    required this.bonusMatched,
    required this.rank,
  });

  final int matches;
  final bool bonusMatched;

  /// 1..5 for a winning game, 0 for a valid non-winning game.
  final int rank;

  String get rankLabel =>
      formatters.rankLabel(matchCount: matches, bonusMatch: bonusMatched);
  String get matchLabel =>
      matches == 5 && bonusMatched ? '5개 + 보너스 적중' : '$matches개 적중';

  /// 1st–3rd prizes depend on the round, so never display an estimated amount.
  int? get fixedPrize => switch (rank) {
    4 => 50000,
    5 => 5000,
    0 => 0,
    _ => null,
  };

  static PurchaseGameResult? evaluate(List<int> game, DrawResult? draw) {
    if (!isLottoGame(game) || !hasActualDraw(draw)) return null;
    final actual = draw!;
    final matches = game.where(actual.winningNumbers.contains).length;
    final bonusMatched = game.contains(actual.bonusNumber);
    final rank = switch (matches) {
      6 => 1,
      5 => bonusMatched ? 2 : 3,
      4 => 4,
      3 => 5,
      _ => 0,
    };
    return PurchaseGameResult(
      matches: matches,
      bonusMatched: bonusMatched,
      rank: rank,
    );
  }
}

class PurchaseSummary {
  PurchaseSummary._({
    required this.round,
    required this.records,
    required this.draw,
    required this.statuses,
  });

  factory PurchaseSummary.forRound({
    required int round,
    required List<PurchaseRecord> records,
    required Map<int, DrawResult> draws,
    int? knownLatestRound,
    DateTime? now,
  }) {
    final selected = records.where((record) => record.round == round).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return PurchaseSummary._(
      round: round,
      records: List.unmodifiable(selected),
      draw: hasActualDraw(draws[round], round: round) ? draws[round] : null,
      statuses: Map.unmodifiable({
        for (final record in selected)
          record.id: statusFor(
            record,
            draws: draws,
            knownLatestRound: knownLatestRound,
            now: now,
          ),
      }),
    );
  }

  final int round;
  final List<PurchaseRecord> records;
  final DrawResult? draw;
  final Map<int, PurchaseReviewStatus> statuses;

  int get ticketCount => records.length;
  int get gameCount =>
      records.fold(0, (count, record) => count + record.games.length);
  int count(PurchaseReviewStatus status) =>
      records.where((record) => statuses[record.id] == status).length;
  int get waitingCount =>
      count(PurchaseReviewStatus.awaitingDraw) + delayedResultCount;
  int get delayedResultCount => count(PurchaseReviewStatus.awaitingResult);
  int get uncheckedCount => count(PurchaseReviewStatus.unchecked);
  int get checkedCount => count(PurchaseReviewStatus.checked);
  List<int> get uncheckedIds => List.unmodifiable(
    records
        .where(
          (record) => statuses[record.id] == PurchaseReviewStatus.unchecked,
        )
        .map((record) => record.id)
        .toSet(),
  );

  static PurchaseReviewStatus statusFor(
    PurchaseRecord record, {
    required Map<int, DrawResult> draws,
    int? knownLatestRound,
    DateTime? now,
  }) {
    if (hasActualDraw(draws[record.round], round: record.round)) {
      return record.isResultChecked
          ? PurchaseReviewStatus.checked
          : PurchaseReviewStatus.unchecked;
    }
    final date = DateTime.tryParse(record.drawDate);
    // Compare Korean calendar dates, independent of the device's time zone.
    final today = (now ?? DateTime.now()).toUtc().add(const Duration(hours: 9));
    final pastDate =
        date != null &&
        DateTime.utc(
          date.year,
          date.month,
          date.day,
        ).isBefore(DateTime.utc(today.year, today.month, today.day));
    if ((knownLatestRound != null && record.round <= knownLatestRound) ||
        pastDate) {
      return PurchaseReviewStatus.awaitingResult;
    }
    return PurchaseReviewStatus.awaitingDraw;
  }

  static List<int> suggestedRounds(List<PurchaseRecord> records) =>
      (records
          .map((record) => record.round)
          .where((round) => round > 0)
          .toSet()
          .toList()
        ..sort((a, b) => b.compareTo(a)));

  /// Keep a newly released result in focus even when next week's tickets exist.
  /// With no purchase for it, surface older unreviewed results before upcoming
  /// tickets. Cached/stale dates never imply an actual result is available.
  static int? defaultRound({
    required List<PurchaseRecord> records,
    required Map<int, DrawResult> draws,
    int? knownLatestRound,
    DateTime? now,
  }) {
    final rounds = suggestedRounds(records);
    if (rounds.isEmpty) return null;
    final actualRounds =
        draws.entries
            .where((entry) => hasActualDraw(entry.value, round: entry.key))
            .map((entry) => entry.key)
            .toList()
          ..sort((a, b) => b.compareTo(a));
    if (actualRounds.isNotEmpty && rounds.contains(actualRounds.first)) {
      return actualRounds.first;
    }
    for (final round in rounds) {
      if (hasActualDraw(draws[round], round: round) &&
          records.any(
            (record) => record.round == round && !record.isResultChecked,
          )) {
        return round;
      }
    }
    final upcoming =
        rounds
            .where(
              (round) => records.any(
                (record) =>
                    record.round == round &&
                    statusFor(
                          record,
                          draws: draws,
                          knownLatestRound: knownLatestRound,
                          now: now,
                        ) ==
                        PurchaseReviewStatus.awaitingDraw,
              ),
            )
            .toList()
          ..sort();
    if (upcoming.isNotEmpty) return upcoming.first;
    return rounds.first;
  }
}
