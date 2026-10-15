import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/screens/login_screen.dart';

void main() {
  testWidgets('guest transition cannot be submitted twice while pending', (
    tester,
  ) async {
    final transition = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          onLoginSuccess: () {
            calls++;
            return transition.future;
          },
        ),
      ),
    );
    final guest = find.text('로그인 없이 계속하기');
    await tester.tap(guest);
    await tester.pump();
    await tester.tap(guest);
    expect(calls, 1);
    expect(
      tester.widget<TextButton>(find.byType(TextButton)).onPressed,
      isNull,
    );
    transition.complete();
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextButton>(find.byType(TextButton)).onPressed,
      isNotNull,
    );
  });

  testWidgets('failed guest transition shows an error and allows retry', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          onLoginSuccess: () async {
            if (++calls == 1) throw StateError('database unavailable');
          },
        ),
      ),
    );
    await tester.tap(find.text('로그인 없이 계속하기'));
    await tester.pumpAndSettle();
    expect(find.text('화면을 열지 못했습니다. 다시 시도해주세요.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('로그인 없이 계속하기'));
    await tester.pumpAndSettle();
    expect(calls, 2);
  });
}
