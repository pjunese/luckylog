import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/widgets/result_share_card.dart';

/// 공유 카드는 화면 밖에서 고정 크기로 렌더링되므로,
/// 오버플로우가 나도 사용자 화면에는 아무 경고가 보이지 않는다.
/// (이미지만 잘린 채 공유된다) 그래서 레이아웃 검증이 특히 중요하다.
Widget host(Widget card) => MediaQuery(
  data: const MediaQueryData(textScaler: TextScaler.noScaling),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Center(child: card),
  ),
);

void main() {
  const winning = [5, 12, 18, 23, 31, 43];

  testWidgets('5등 - 3개 적중 카드가 넘치지 않고 그려진다', (tester) async {
    await tester.pumpWidget(
      host(
        const ResultShareCard(
          round: 1230,
          numbers: [5, 12, 18, 2, 9, 44],
          winningNumbers: winning,
          bonusNumber: 7,
          rankLabel: '5등',
          amount: 5000,
          drawDate: '2026-09-05',
        ),
      ),
    );

    expect(tester.takeException(), isNull); // 오버플로우 없음
    expect(find.text('5등'), findsOneWidget);
    expect(find.text('3개 적중'), findsOneWidget);
    expect(find.text('5,000원'), findsOneWidget);
    expect(find.text('럭키로그'), findsOneWidget);
  });

  testWidgets('낙첨 카드는 등수 대신 안내 문구를 보여준다', (tester) async {
    await tester.pumpWidget(
      host(
        const ResultShareCard(
          round: 1230,
          numbers: [1, 2, 3, 4, 6, 8],
          winningNumbers: winning,
          bonusNumber: 7,
          rankLabel: '낙첨',
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('아쉽게 낙첨'), findsOneWidget);
    expect(find.text('0개 적중'), findsOneWidget);
  });

  testWidgets('2등은 보너스 적중을 따로 표기한다', (tester) async {
    await tester.pumpWidget(
      host(
        const ResultShareCard(
          round: 1230,
          numbers: [5, 12, 18, 23, 31, 7], // 5개 + 보너스(7)
          winningNumbers: winning,
          bonusNumber: 7,
          rankLabel: '2등',
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('5개 + 보너스 적중'), findsOneWidget);
  });

  testWidgets('당첨금이 0이면 금액을 표시하지 않는다', (tester) async {
    await tester.pumpWidget(
      host(
        const ResultShareCard(
          round: 1230,
          numbers: winning,
          winningNumbers: winning,
          bonusNumber: 7,
          rankLabel: '1등',
          amount: 0, // 1등은 회차마다 달라 앱이 확정 금액을 모른다
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('1등'), findsOneWidget);
    expect(find.textContaining('원'), findsNothing);
  });

  testWidgets('큰 금액은 천 단위로 구분된다', (tester) async {
    await tester.pumpWidget(
      host(
        const ResultShareCard(
          round: 1230,
          numbers: [5, 12, 18, 23, 1, 2],
          winningNumbers: winning,
          bonusNumber: 7,
          rankLabel: '4등',
          amount: 1234567,
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('1,234,567원'), findsOneWidget);
  });

  testWidgets('번호 6개가 모두 렌더링된다', (tester) async {
    await tester.pumpWidget(
      host(
        const ResultShareCard(
          round: 1230,
          numbers: [1, 11, 21, 31, 41, 45],
          winningNumbers: winning,
          bonusNumber: 7,
          rankLabel: '낙첨',
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    for (final n in [1, 11, 21, 31, 41, 45]) {
      expect(find.text('$n'), findsOneWidget, reason: '$n번 누락');
    }
  });
}
