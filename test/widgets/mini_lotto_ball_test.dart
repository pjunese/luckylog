import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/core/lotto_palette.dart';
import 'package:my_app/widgets/mini_lotto_ball.dart';

Widget wrap(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

BoxDecoration decorationOf(WidgetTester tester) {
  final container = tester.widget<Container>(
    find.descendant(
      of: find.byType(MiniLottoBall),
      matching: find.byType(Container),
    ),
  );
  return container.decoration! as BoxDecoration;
}

void main() {
  testWidgets('번호를 그대로 표시한다', (tester) async {
    await tester.pumpWidget(wrap(const MiniLottoBall(number: 42)));
    expect(find.text('42'), findsOneWidget);
  });

  testWidgets('일반 볼은 구간 색으로 꽉 채워지고 테두리가 없다', (tester) async {
    await tester.pumpWidget(wrap(const MiniLottoBall(number: 7)));
    final d = decorationOf(tester);

    expect(d.color, lottoBallColor(7));
    expect(d.border, isNull);
    expect(d.shape, BoxShape.circle);
  });

  testWidgets('보너스 볼은 불투명 배경과 테두리로 대비를 유지한다', (tester) async {
    await tester.pumpWidget(
      wrap(const MiniLottoBall(number: 7, isBonus: true)),
    );
    final d = decorationOf(tester);

    // 보너스도 숫자의 대비가 줄어들지 않는다.
    expect(d.color, lottoBallColor(7));
    expect(d.color!.a, 1.0);
    expect(d.border, isNotNull);
  });

  testWidgets('45번까지 모든 번호가 예외 없이 렌더링된다', (tester) async {
    for (int n = 1; n <= 45; n++) {
      await tester.pumpWidget(wrap(MiniLottoBall(number: n)));
      expect(find.text('$n'), findsOneWidget, reason: '$n번 렌더 실패');
    }
  });
}
