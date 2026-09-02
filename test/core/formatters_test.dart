import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/core/formatters.dart';

void main() {
  group('rankLabel - 등수 판정', () {
    test('6개 일치는 1등', () {
      expect(rankLabel(matchCount: 6, bonusMatch: false), '1등');
    });

    test('6개 일치는 보너스 여부와 무관하게 1등', () {
      expect(rankLabel(matchCount: 6, bonusMatch: true), '1등');
    });

    test('5개 + 보너스는 2등', () {
      expect(rankLabel(matchCount: 5, bonusMatch: true), '2등');
    });

    test('5개 (보너스 불일치)는 3등', () {
      expect(rankLabel(matchCount: 5, bonusMatch: false), '3등');
    });

    test('4개는 4등 (보너스 무관)', () {
      expect(rankLabel(matchCount: 4, bonusMatch: true), '4등');
      expect(rankLabel(matchCount: 4, bonusMatch: false), '4등');
    });

    test('3개는 5등 (보너스 무관)', () {
      expect(rankLabel(matchCount: 3, bonusMatch: true), '5등');
      expect(rankLabel(matchCount: 3, bonusMatch: false), '5등');
    });

    test('2개 이하는 낙첨', () {
      for (final n in [0, 1, 2]) {
        expect(rankLabel(matchCount: n, bonusMatch: false), '낙첨');
        // 보너스만 맞아도 낙첨
        expect(rankLabel(matchCount: n, bonusMatch: true), '낙첨');
      }
    });
  });

  group('formatDateTime', () {
    test('한 자리 월/일/시/분은 0으로 채운다', () {
      expect(
        formatDateTime(DateTime(2026, 3, 7, 9, 5)),
        '2026-03-07 09:05',
      );
    });

    test('두 자리 값은 그대로 표시', () {
      expect(
        formatDateTime(DateTime(2026, 12, 25, 18, 42)),
        '2026-12-25 18:42',
      );
    });

    test('자정은 00:00으로 표시', () {
      expect(formatDateTime(DateTime(2026, 1, 1)), '2026-01-01 00:00');
    });
  });
}
