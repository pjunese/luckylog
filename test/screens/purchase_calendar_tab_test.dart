import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/models/purchase_insights.dart';
import 'package:my_app/models/purchase_record.dart';
import 'package:my_app/models/draw_result.dart';
import 'package:my_app/screens/purchase_calendar_tab.dart';

final day = DateTime.utc(2026, 9, 5);
final round = day.difference(DateTime.utc(2002, 12, 7)).inDays ~/ 7 + 1;
PurchaseInsights sample() => PurchaseInsights(
  records: [
    PurchaseRecord(
      id: 1,
      games: [
        [1, 2, 3, 40, 41, 42],
      ],
      round: round,
      drawDate: '',
      source: 'qr',
      createdAt: day,
      purchaseDate: day,
    ),
  ],
  draws: {
    round: DrawResult(
      round: round,
      winningNumbers: [1, 2, 3, 4, 5, 6],
      bonusNumber: 7,
      drawDate: '',
    ),
  },
);
Widget app(
  Widget child, {
  Brightness brightness = Brightness.light,
  double scale = 1,
}) => MaterialApp(
  theme: ThemeData(
    colorSchemeSeed: const Color(0xFF0F766E),
    brightness: brightness,
  ),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(body: child),
);
void main() {
  testWidgets(
    'calendar date markers, navigation, registration, edit and share actions',
    (tester) async {
      var selected = day;
      var adds = 0;
      var edits = 0;
      var shares = 0;
      await tester.pumpWidget(
        app(
          StatefulBuilder(
            builder: (context, setState) => PurchaseCalendarView(
              insights: sample(),
              selected: selected,
              today: DateTime.utc(2026, 9, 22),
              onSelect: (v) => setState(() => selected = v),
              onAdd: () => adds++,
              onEditDate: (_) async {
                edits++;
              },
              onShare: (_) async {
                shares++;
              },
              onRefresh: () async {},
            ),
          ),
        ),
      );
      expect(find.text('1천'), findsOneWidget);
      expect(find.text('★1'), findsOneWidget);
      expect(find.text('1장 · 1게임 · 당첨 1게임'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('구매 등록'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('구매 등록'));
      expect(adds, 1);
      await tester.scrollUntilVisible(
        find.text('$round회 · 1,000원'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('$round회 · 1,000원'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('구매일 수정'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('구매일 수정'));
      expect(edits, 1);
      await tester.scrollUntilVisible(
        find.text('당첨 공유'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('당첨 공유'));
      expect(shares, 1);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('calendar-day-2026-09-06')),
        -500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('calendar-day-2026-09-06')));
      await tester.pumpAndSettle();
      expect(selected, DateTime.utc(2026, 9, 6));
      expect(find.text('이날의 기록이 없어요.'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byTooltip('이전 달'),
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('이전 달'));
      await tester.pumpAndSettle();
      expect(find.text('2026년 8월'), findsOneWidget);
      await tester.tap(find.byTooltip('다음 달'));
      await tester.pumpAndSettle();
      expect(find.text('2026년 9월'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('calendar-day-2026-09-30')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('구매 등록'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '구매 등록'))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('light and dark calendar fit narrow phones with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        await tester.pumpWidget(
          app(
            PurchaseCalendarView(
              insights: sample(),
              selected: day,
              today: DateTime.utc(2026, 9, 22),
              onSelect: (_) {},
              onAdd: () {},
              onEditDate: (_) async {},
              onShare: (_) async {},
              onRefresh: () async {},
            ),
            brightness: brightness,
            scale: scale,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          find.text('구매 등록'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    }
  });
  testWidgets(
    'earliest month and future selected date safely open date picker',
    (tester) async {
      for (final selected in [
        DateTime.utc(2002, 12, 1),
        DateTime.utc(2026, 9, 30),
      ]) {
        await tester.pumpWidget(
          app(
            PurchaseCalendarView(
              insights: PurchaseInsights(records: [], draws: {}),
              selected: selected,
              today: DateTime.utc(2026, 9, 22),
              onSelect: (_) {},
              onAdd: () {},
              onEditDate: (_) async {},
              onShare: (_) async {},
              onRefresh: () async {},
            ),
          ),
        );
        await tester.tap(find.text('${selected.year}년 ${selected.month}월'));
        await tester.pumpAndSettle();
        expect(find.byType(DatePickerDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      }
    },
  );
}
