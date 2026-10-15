import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/models/draw_result.dart';
import 'package:my_app/models/purchase_record.dart';
import 'package:my_app/models/purchase_summary.dart';

const draw = DrawResult(
  round: 1230,
  winningNumbers: [1, 2, 3, 4, 5, 6],
  bonusNumber: 7,
  drawDate: '2026-09-05',
);
final now = DateTime.utc(2026, 9, 8);
PurchaseRecord ticket(
  int id, {
  int round = 1230,
  bool checked = false,
  String date = '2026-09-05',
  int games = 1,
}) => PurchaseRecord(
  id: id,
  round: round,
  games: List.generate(games, (_) => [1, 2, 3, 4, 5, 6]),
  drawDate: date,
  source: 'qr',
  createdAt: DateTime.utc(2026, 9, 1, id),
  resultCheckedAt: checked ? now : null,
);

void main() {
  test('실제 결과가 없으면 날짜나 확인 기록만으로 확인 완료가 되지 않는다', () {
    expect(
      PurchaseSummary.statusFor(
        ticket(1, checked: true),
        draws: {},
        knownLatestRound: 1230,
        now: now,
      ),
      PurchaseReviewStatus.awaitingResult,
    );
    expect(
      PurchaseSummary.statusFor(ticket(1), draws: {}, now: now),
      PurchaseReviewStatus.awaitingResult,
    );
    expect(
      PurchaseSummary.statusFor(
        ticket(2, round: 1231, date: '2026-09-12'),
        draws: {},
        now: now,
      ),
      PurchaseReviewStatus.awaitingDraw,
    );
  });

  test('현재 한국 날짜의 추첨은 실제 결과가 올 때까지 대기한다', () {
    expect(
      PurchaseSummary.statusFor(
        ticket(1),
        draws: {},
        now: DateTime.utc(2026, 9, 4, 22),
      ),
      PurchaseReviewStatus.awaitingDraw,
    );
  });

  test('선택 회차만 집계하고 복권 수와 게임 수를 구분한다', () {
    final summary = PurchaseSummary.forRound(
      round: 1230,
      records: [
        ticket(1, games: 5),
        ticket(2, checked: true),
        ticket(3, round: 1231),
      ],
      draws: {1230: draw},
      now: now,
    );
    expect(summary.ticketCount, 2);
    expect(summary.gameCount, 6);
    expect(summary.uncheckedCount, 1);
    expect(summary.checkedCount, 1);
    expect(summary.waitingCount, 0);
    expect(summary.uncheckedIds, [1]);
  });

  test('손상되거나 다른 회차의 당첨번호는 실제 결과로 사용하지 않는다', () {
    const invalid = DrawResult(
      round: 1230,
      winningNumbers: [1, 1, 1, 1, 1, 1],
      bonusNumber: 7,
      drawDate: '',
    );
    expect(hasActualDraw(invalid), false);
    expect(
      PurchaseSummary.forRound(
        round: 1231,
        records: [ticket(1, round: 1231)],
        draws: {1231: draw},
        now: now,
      ).draw,
      isNull,
    );
    expect(
      PurchaseSummary.statusFor(
        ticket(1, checked: true),
        draws: {1230: invalid},
        now: now,
      ),
      PurchaseReviewStatus.awaitingResult,
    );
  });

  test('새 결과 회차는 다음 주 복권이 있어도 먼저 제안한다', () {
    final records = [ticket(1), ticket(2, round: 1231, date: '2026-09-12')];
    expect(
      PurchaseSummary.defaultRound(
        records: records,
        draws: {1230: draw},
        now: now,
      ),
      1230,
    );
    expect(
      PurchaseSummary.defaultRound(
        records: [ticket(1, checked: true), records.last],
        draws: {1230: draw},
        now: now,
      ),
      1230,
    );
    expect(PurchaseSummary.suggestedRounds([...records, ticket(3)]), [
      1231,
      1230,
    ]);
  });

  test('최신 회차 구매가 없으면 미확인 과거 결과를 먼저 보여준다', () {
    const newer = DrawResult(
      round: 1231,
      winningNumbers: [1, 2, 3, 4, 5, 6],
      bonusNumber: 7,
      drawDate: '2026-09-12',
    );
    expect(
      PurchaseSummary.defaultRound(
        records: [
          ticket(1),
          ticket(2, round: 1232, date: '2026-09-19'),
        ],
        draws: {1230: draw, 1231: newer},
        now: now,
      ),
      1230,
    );
  });

  test('오래된 오프라인 데이터는 과거를 추첨 완료로 간주하지 않고 예정 회차를 제안한다', () {
    final records = [
      ticket(1),
      ticket(2, round: 1232, date: '2026-09-19'),
      ticket(3, round: 1231, date: '2026-09-12'),
    ];
    expect(
      PurchaseSummary.defaultRound(
        records: records,
        draws: {},
        knownLatestRound: 1220,
        now: now,
      ),
      1231,
    );
    expect(
      PurchaseSummary.defaultRound(records: [ticket(1)], draws: {}, now: now),
      1230,
    );
    expect(
      PurchaseSummary.defaultRound(records: [], draws: {}, now: now),
      isNull,
    );
  });

  test('모든 등수와 보너스 규칙 및 확정 금액만 계산한다', () {
    final cases = <List<int>, int>{
      [1, 2, 3, 4, 5, 6]: 1,
      [1, 2, 3, 4, 5, 7]: 2,
      [1, 2, 3, 4, 5, 8]: 3,
      [1, 2, 3, 4, 8, 9]: 4,
      [1, 2, 3, 8, 9, 10]: 5,
      [1, 2, 8, 9, 10, 11]: 0,
    };
    for (final entry in cases.entries) {
      final result = PurchaseGameResult.evaluate(entry.key, draw)!;
      expect(result.rank, entry.value);
      expect(result.rankLabel, entry.value == 0 ? '낙첨' : '${entry.value}등');
      if (entry.value >= 1 && entry.value <= 3) {
        expect(result.fixedPrize, isNull);
      }
    }
    expect(
      PurchaseGameResult.evaluate([1, 2, 3, 4, 8, 9], draw)!.fixedPrize,
      50000,
    );
    expect(
      PurchaseGameResult.evaluate([1, 2, 3, 8, 9, 10], draw)!.fixedPrize,
      5000,
    );
    expect(
      PurchaseGameResult.evaluate([1, 2, 3, 4, 5, 7], draw)!.matchLabel,
      '5개 + 보너스 적중',
    );
    expect(PurchaseGameResult.evaluate([1, 1, 1, 1, 1, 1], draw), isNull);
    expect(PurchaseGameResult.evaluate([1, 2, 3, 4, 5, 46], draw), isNull);
    expect(PurchaseGameResult.evaluate([1, 2, 3, 4, 5, 6], null), isNull);
  });
}
