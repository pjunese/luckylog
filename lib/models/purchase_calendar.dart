import 'purchase_insights.dart';
import 'purchase_record.dart';

DateTime calendarPurchaseDay(PurchaseRecord record) =>
    record.purchaseDate ?? koreanCalendarDay(record.createdAt);

class CalendarDaySummary {
  CalendarDaySummary({required this.day, required PurchaseInsights insights})
    : purchases = insights.records
          .where((r) => calendarPurchaseDay(r) == day)
          .toList(),
      wins = insights.games
          .where((g) => g.isWin && PurchaseInsights.drawDay(g.record) == day)
          .toList();
  final DateTime day;
  final List<PurchaseRecord> purchases;
  final List<InsightGame> wins;
  int get spent => purchases.fold(0, (sum, r) => sum + r.games.length * 1000);
  int get knownPrize => wins.fold(0, (sum, g) => sum + (g.amount ?? 0));
  bool get unknownPrize => wins.any((g) => g.amount == null);
}

class CalendarMonthSummary {
  CalendarMonthSummary({required this.insights, required DateTime month})
    : period = InsightPeriod(month, InsightFrequency.month) {
    records = insights.records
        .where((r) => period.contains(calendarPurchaseDay(r)))
        .toList();
    final ids = records.map((r) => r.id).toSet();
    games = insights.games.where((g) => ids.contains(g.record.id)).toList();
    wins = insights.games
        .where(
          (g) => g.isWin && period.contains(PurchaseInsights.drawDay(g.record)),
        )
        .toList();
  }
  final PurchaseInsights insights;
  final InsightPeriod period;
  late final List<PurchaseRecord> records;
  late final List<InsightGame> games;
  late final List<InsightGame> wins;
  int get spent => games.length * 1000;
  int get winCount => wins.length;
  int get knownPrize => wins.fold(0, (sum, g) => sum + (g.amount ?? 0));
  int get unknownPrizeCount => wins.where((g) => g.amount == null).length;
  int get pendingGames => games.where((g) => g.result == null).length;
  String get prizeText => unknownPrizeCount > 0 && knownPrize == 0
      ? '확인 중'
      : insightWon(knownPrize);
  CalendarDaySummary day(DateTime date) =>
      CalendarDaySummary(day: date, insights: insights);
}
