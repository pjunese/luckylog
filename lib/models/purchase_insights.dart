import 'draw_result.dart';
import 'purchase_record.dart';
import 'purchase_summary.dart';

enum InsightFrequency { month, week }

DateTime koreanCalendarDay([DateTime? now]) {
  final date = (now ?? DateTime.now()).toUtc().add(const Duration(hours: 9));
  return DateTime.utc(date.year, date.month, date.day);
}

String insightWon(int amount) =>
    '${amount.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}원';

class InsightPeriod {
  InsightPeriod(DateTime date, this.frequency)
    : start = frequency == InsightFrequency.month
          ? DateTime.utc(date.year, date.month)
          : DateTime.utc(
              date.year,
              date.month,
              date.day,
            ).subtract(Duration(days: date.weekday - DateTime.monday));
  final DateTime start;
  final InsightFrequency frequency;
  DateTime get end => frequency == InsightFrequency.month
      ? DateTime.utc(start.year, start.month + 1)
      : start.add(const Duration(days: 7));
  bool contains(DateTime date) => !date.isBefore(start) && date.isBefore(end);
  InsightPeriod shift(int count) => InsightPeriod(
    frequency == InsightFrequency.month
        ? DateTime.utc(start.year, start.month + count)
        : start.add(Duration(days: count * 7)),
    frequency,
  );
  String get key => '${frequency.name}-${start.toIso8601String()}';
  String get label {
    if (frequency == InsightFrequency.month) {
      return '${start.year}년 ${start.month}월';
    }
    final last = end.subtract(const Duration(days: 1));
    return '${start.year}.${start.month}.${start.day} – ${last.year != start.year ? '${last.year}.' : ''}${last.month}.${last.day}';
  }

  String get shortLabel => frequency == InsightFrequency.month
      ? '${start.month}월'
      : '${start.month}.${start.day}';
}

class InsightGame {
  const InsightGame({
    required this.record,
    required this.index,
    required this.result,
    required this.amount,
  });
  final PurchaseRecord record;
  final int index;
  final PurchaseGameResult? result;

  /// Null is an unavailable amount/result, never a confirmed zero prize.
  final int? amount;
  List<int> get numbers => record.games[index];
  bool get isWin => (result?.rank ?? 0) > 0;
}

class PeriodInsight {
  const PeriodInsight({
    required this.period,
    required this.records,
    required this.games,
  });
  final InsightPeriod period;
  final List<PurchaseRecord> records;
  final List<InsightGame> games;
  int get spent => games.length * 1000;
  int get winCount => games.where((g) => g.isWin).length;
  int get pendingGames => games.where((g) => g.result == null).length;
  int get unknownPrizeCount =>
      games.where((g) => g.isWin && g.amount == null).length;
  int get knownPrize => games.fold(0, (total, g) => total + (g.amount ?? 0));
  String get prizeText => unknownPrizeCount > 0 && knownPrize == 0
      ? '확인 중'
      : insightWon(knownPrize);
  List<int> get rounds =>
      records.map((r) => r.round).toSet().toList()
        ..sort((a, b) => b.compareTo(a));
}

class PurchaseInsights {
  PurchaseInsights({
    required List<PurchaseRecord> records,
    required this.draws,
    this.prizes = const {},
  }) : records = List.unmodifiable(records) {
    games = List.unmodifiable([
      for (final record in this.records)
        for (var index = 0; index < record.games.length; index++)
          _evaluate(record, index),
    ]);
  }
  final List<PurchaseRecord> records;
  final Map<int, DrawResult> draws;
  final Map<int, Map<int, int>> prizes;
  late final List<InsightGame> games;
  static DateTime drawDay(PurchaseRecord record) {
    // Derive the date from the round so malformed/legacy display dates cannot
    // move the same draw into different weeks on different devices.
    return DateTime.utc(
      2002,
      12,
      7,
    ).add(Duration(days: (record.round - 1) * 7));
  }

  InsightGame _evaluate(PurchaseRecord record, int index) {
    final draw = draws[record.round];
    final result = hasActualDraw(draw, round: record.round)
        ? PurchaseGameResult.evaluate(record.games[index], draw)
        : null;
    final remote = prizes[record.round]?[result?.rank];
    final amount = result == null
        ? null
        : result.fixedPrize ?? (remote != null && remote > 0 ? remote : null);
    return InsightGame(
      record: record,
      index: index,
      result: result,
      amount: amount,
    );
  }

  PeriodInsight forPeriod(InsightPeriod period) => PeriodInsight(
    period: period,
    records: records.where((r) => period.contains(drawDay(r))).toList(),
    games: games.where((g) => period.contains(drawDay(g.record))).toList(),
  );
  DateTime earliestDay(DateTime today) => records.fold(today, (first, r) {
    final d = drawDay(r);
    return d.isBefore(first) ? d : first;
  });
  DateTime latestDay(DateTime today) => records.fold(today, (last, r) {
    final d = drawDay(r);
    return d.isAfter(last) ? d : last;
  });
}
