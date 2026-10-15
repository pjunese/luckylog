import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/core/lotto_palette.dart';
import 'package:my_app/widgets/mini_lotto_ball.dart';
import 'package:my_app/widgets/purchase_number_ball.dart';

double contrast(Color a, Color b) =>
    (max(a.computeLuminance(), b.computeLuminance()) + .05) /
    (min(a.computeLuminance(), b.computeLuminance()) + .05);
void main() {
  test('all filled ball numbers have at least 4.5:1 contrast', () {
    for (var n = 1; n <= 45; n++) {
      expect(
        contrast(lottoBallColor(n), lottoBallTextColor(n)),
        greaterThanOrEqualTo(4.5),
        reason: '$n',
      );
    }
  });
  for (final brightness in Brightness.values) {
    testWidgets(
      'bonus and unmatched black balls remain readable in $brightness',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(
              body: Column(
                children: [
                  const MiniLottoBall(number: 35, isBonus: true),
                  const PurchaseNumberBall(number: 36),
                  const PurchaseNumberBall(number: 37, matched: true),
                  const PurchaseNumberBall(number: 38, bonus: true),
                ],
              ),
            ),
          ),
        );
        for (final number in [35, 36, 37, 38]) {
          final text = tester.widget<Text>(find.text('$number'));
          final ball = tester.widget<Container>(
            find
                .ancestor(
                  of: find.text('$number'),
                  matching: find.byType(Container),
                )
                .first,
          );
          final background = (ball.decoration as BoxDecoration).color!;
          expect(
            contrast(text.style!.color!, background),
            greaterThanOrEqualTo(4.5),
          );
        }
        expect(find.byIcon(Icons.check), findsOneWidget);
        expect(find.text('B'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
