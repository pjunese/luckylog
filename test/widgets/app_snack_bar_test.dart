import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/widgets/app_snack_bar.dart';

void main() {
  late BuildContext page;
  Future<void> mount(WidgetTester tester, {bool accessible = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(accessibleNavigation: accessible),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              page = context;
              return const Text('화면');
            },
          ),
        ),
      ),
    );
  }

  testWidgets('plain completion closes automatically', (tester) async {
    await mount(tester);
    showAppSnackBar(page, content: const Text('저장 완료'));
    await tester.pumpAndSettle();
    expect(find.text('저장 완료'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('undo action no longer makes the notification permanent', (
    tester,
  ) async {
    await mount(tester);
    showAppSnackBar(
      page,
      content: const Text('휴지통 이동'),
      action: SnackBarAction(label: '실행 취소', onPressed: () {}),
    );
    await tester.pumpAndSettle();
    expect(find.text('실행 취소'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets(
    'later completion replaces undo and rapid messages do not queue',
    (tester) async {
      await mount(tester);
      showAppSnackBar(
        page,
        content: const Text('이전 삭제'),
        action: SnackBarAction(label: '실행 취소', onPressed: () {}),
      );
      await tester.pumpAndSettle();
      showAppSnackBar(page, content: const Text('첫 복원'));
      showAppSnackBar(page, content: const Text('마지막 복원'));
      await tester.pumpAndSettle();
      expect(find.text('이전 삭제'), findsNothing);
      expect(find.text('첫 복원'), findsNothing);
      expect(find.text('마지막 복원'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets('action works once and the close button dismisses directly', (
    tester,
  ) async {
    await mount(tester);
    var undo = 0;
    showAppSnackBar(
      page,
      content: const Text('삭제 완료'),
      action: SnackBarAction(label: '실행 취소', onPressed: () => undo++),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('실행 취소'));
    await tester.pumpAndSettle();
    expect(undo, 1);
    expect(find.byType(SnackBar), findsNothing);
    showAppSnackBar(page, content: const Text('복원 완료'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('screen-reader actions remain reachable and dismissible', (
    tester,
  ) async {
    await mount(tester, accessible: true);
    showAppSnackBar(
      page,
      content: const Text('삭제 완료'),
      action: SnackBarAction(label: '실행 취소', onPressed: () {}),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('실행 취소'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('navigation cleanup leaves no delayed messages', (tester) async {
    await mount(tester);
    showAppSnackBar(page, content: const Text('저장 완료'));
    await tester.pumpAndSettle();
    dismissAppSnackBars(page);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    expect(find.byType(SnackBar), findsNothing);
  });
}
