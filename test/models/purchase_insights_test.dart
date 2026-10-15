import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/models/purchase_insights.dart';
import 'package:my_app/models/draw_result.dart';
import 'package:my_app/models/purchase_record.dart';

int roundOn(DateTime day) =>
    day.difference(DateTime.utc(2002, 12, 7)).inDays ~/ 7 + 1;
PurchaseRecord record(int id, DateTime day, List<List<int>> games) =>
    PurchaseRecord(
      id: id,
      round: roundOn(day),
      drawDate: 'old-invalid-date',
      games: games,
      source: 'qr',
      createdAt: DateTime.utc(2026, 10, 1),
    );
DrawResult draw(int round) => DrawResult(
  round: round,
  winningNumbers: const [1, 2, 3, 4, 5, 6],
  bonusNumber: 7,
  drawDate: '',
);
void main() {
  test(
    'calendar boundaries use Korea, inclusive start/exclusive end, Monday weeks',
    () {
      expect(
        koreanCalendarDay(DateTime.utc(2026, 12, 31, 15)),
        DateTime.utc(2027),
      );
      final month = InsightPeriod(
        DateTime.utc(2026, 12, 31),
        InsightFrequency.month,
      );
      expect(month.shift(1).start, DateTime.utc(2027));
      expect(month.contains(DateTime.utc(2027)), false);
      final week = InsightPeriod(
        DateTime.utc(2027, 1, 3),
        InsightFrequency.week,
      );
      expect(week.start, DateTime.utc(2026, 12, 28));
      expect(week.end, DateTime.utc(2027, 1, 4));
      expect(week.label, contains('2027.1.3'));
      expect(
        InsightPeriod(DateTime.utc(2024, 2), InsightFrequency.month).end,
        DateTime.utc(2024, 3),
      );
    },
  );
  test(
    'draw date defines period, duplicate round tickets count games correctly',
    () {
      final day = DateTime.utc(2026, 9, 5);
      final round = roundOn(day);
      final data = PurchaseInsights(
        records: [
          record(1, day, [
            [1, 2, 3, 40, 41, 42],
            [1, 2, 3, 4, 40, 41],
          ]),
          record(2, day, [
            [10, 11, 12, 13, 14, 15],
          ]),
        ],
        draws: {round: draw(round)},
      );
      final month = data.forPeriod(InsightPeriod(day, InsightFrequency.month));
      expect(month.records.length, 2);
      expect(month.rounds, [round]);
      expect(month.games.length, 3);
      expect(month.spent, 3000);
      expect(month.winCount, 2);
      expect(month.knownPrize, 55000);
      expect(month.pendingGames, 0);
      expect(
        data
            .forPeriod(
              InsightPeriod(DateTime.utc(2026, 10), InsightFrequency.month),
            )
            .spent,
        0,
      );
    },
  );
  test(
    'missing results and unknown variable prizes are never confirmed zero wins',
    () {
      final d = DateTime.utc(2026, 9, 5);
      final r = roundOn(d);
      final records = [
        record(1, d, [
          [1, 2, 3, 4, 5, 6],
        ]),
        record(2, d.add(const Duration(days: 7)), [
          [1, 2, 3, 4, 5, 7],
        ]),
      ];
      final data = PurchaseInsights(records: records, draws: {r: draw(r)});
      final p = InsightPeriod(d, InsightFrequency.month);
      final sum = data.forPeriod(p);
      expect(sum.winCount, 1);
      expect(sum.unknownPrizeCount, 1);
      expect(sum.pendingGames, 1);
      expect(sum.prizeText, '확인 중');
      final loaded = PurchaseInsights(
        records: records,
        draws: {r: draw(r)},
        prizes: {
          r: {1: 1234567890},
        },
      ).forPeriod(p);
      expect(loaded.knownPrize, 1234567890);
      expect(loaded.unknownPrizeCount, 0);
      expect(insightWon(loaded.knownPrize), '1,234,567,890원');
    },
  );
  test(
    'removing and restoring rows recomputes totals without double counting',
    () {
      final d = DateTime.utc(2026, 9, 5);
      final row = record(1, d, [
        [1, 2, 3, 40, 41, 42],
      ]);
      final p = InsightPeriod(d, InsightFrequency.month);
      expect(
        PurchaseInsights(records: [row], draws: {}).forPeriod(p).spent,
        1000,
      );
      expect(PurchaseInsights(records: [], draws: {}).forPeriod(p).spent, 0);
      expect(
        PurchaseInsights(
          records: [record(2, d, row.games)],
          draws: {},
        ).forPeriod(p).spent,
        1000,
      );
    },
  );
}
