import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/models/purchase_insights.dart';
import 'package:my_app/models/purchase_calendar.dart';
import 'package:my_app/models/purchase_record.dart';
import 'package:my_app/models/draw_result.dart';
import 'package:my_app/screens/purchase_insights_tab.dart';
import 'package:my_app/widgets/monthly_record_card.dart';

final day = DateTime.utc(2026, 9, 5);
final round = day.difference(DateTime.utc(2002, 12, 7)).inDays ~/ 7 + 1;
PurchaseInsights sample({bool unknown = false}) => PurchaseInsights(
  records: [
    PurchaseRecord(
      id: 1,
      games: unknown
          ? [
              [1, 2, 3, 4, 5, 6],
            ]
          : [
              [1, 2, 3, 40, 41, 42],
              [10, 11, 12, 13, 14, 15],
            ],
      round: round,
      drawDate: '2026-09-05',
      source: 'qr',
      createdAt: day,
    ),
  ],
  draws: {
    round: DrawResult(
      round: round,
      winningNumbers: [1, 2, 3, 4, 5, 6],
      bonusNumber: 7,
      drawDate: '2026-09-05',
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
    'month and week selector, period picker, filtering and expansion work',
    (tester) async {
      var frequency = InsightFrequency.month;
      var anchor = day;
      var wins = false;
      var shares = 0;
      await tester.pumpWidget(
        app(
          StatefulBuilder(
            builder: (context, setState) => PurchaseInsightsView(
              insights: sample(),
              frequency: frequency,
              anchor: anchor,
              today: DateTime.utc(2026, 9, 22),
              winsOnly: wins,
              onFrequencyChanged: (v) => setState(() => frequency = v),
              onPeriodChanged: (v) => setState(() => anchor = v.start),
              onWinsOnlyChanged: (v) => setState(() => wins = v),
              onRefresh: () async {},
              onShare: (_) async {
                shares++;
              },
            ),
          ),
        ),
      );
      expect(find.text('2,000원'), findsOneWidget);
      expect(find.text('5,000원'), findsOneWidget);
      expect(find.text('1장 · 2게임 · 당첨 1게임'), findsOneWidget);
      await tester.tap(find.text('주별'));
      await tester.pumpAndSettle();
      expect(frequency, InsightFrequency.week);
      expect(find.text('2026.8.31 – 9.6'), findsOneWidget);
      await tester.tap(find.text('2026.8.31 – 9.6'));
      await tester.pumpAndSettle();
      expect(find.text('기간 선택'), findsOneWidget);
      await tester.tap(find.text('2026.8.31 – 9.6').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('당첨만'), 160);
      await tester.pumpAndSettle();
      await tester.tap(find.text('당첨만'));
      await tester.pumpAndSettle();
      expect(wins, true);
      await tester.scrollUntilVisible(find.text('$round회'), 200);
      await tester.pumpAndSettle();
      await tester.tap(find.text('$round회'));
      await tester.pumpAndSettle();
      expect(find.text('5등'), findsOneWidget);
      expect(find.text('낙첨'), findsNothing);
      await tester.scrollUntilVisible(find.text('당첨 공유'), 160);
      await tester.pumpAndSettle();
      await tester.tap(find.text('당첨 공유'));
      await tester.pumpAndSettle();
      expect(shares, 1);
    },
  );
  testWidgets('unknown prize is labeled and cannot be shared as zero', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        PurchaseInsightsView(
          insights: sample(unknown: true),
          frequency: InsightFrequency.month,
          anchor: day,
          today: day,
          winsOnly: false,
          onFrequencyChanged: (_) {},
          onPeriodChanged: (_) {},
          onWinsOnlyChanged: (_) {},
          onRefresh: () async {},
          onShare: (_) async {},
        ),
      ),
    );
    expect(find.text('확인 중'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('$round회'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('$round회'));
    await tester.pumpAndSettle();
    expect(find.text('당첨금 확인 중'), findsNWidgets(2));
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '당첨 공유'),
    );
    expect(button.onPressed, isNull);
  });
  testWidgets(
    'results precede an optional trend chart and expansion state stays separate',
    (tester) async {
      await tester.pumpWidget(
        app(
          PurchaseInsightsView(
            insights: sample(),
            frequency: InsightFrequency.month,
            anchor: day,
            today: day,
            winsOnly: false,
            onFrequencyChanged: (_) {},
            onPeriodChanged: (_) {},
            onWinsOnlyChanged: (_) {},
            onRefresh: () async {},
            onShare: (_) async {},
          ),
        ),
      );
      expect(find.text('9월'), findsNothing);
      await tester.scrollUntilVisible(find.text('$round회'), 160);
      await tester.pumpAndSettle();
      expect(find.text('5,000원 당첨'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('최근 6개월 구매 추이'), 160);
      await tester.pumpAndSettle();
      await tester.tap(find.text('최근 6개월 구매 추이'));
      await tester.pumpAndSettle();
      expect(find.text('9월'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('최근 6개월 구매 추이'), -160);
      await tester.pumpAndSettle();
      await tester.tap(find.text('최근 6개월 구매 추이'));
      await tester.pumpAndSettle();
      expect(find.text('9월'), findsNothing);
    },
  );
  testWidgets('light dark empty and 2x text stay readable at 360 width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final brightness in Brightness.values) {
      for (final data in [sample(), PurchaseInsights(records: [], draws: {})]) {
        await tester.pumpWidget(
          app(
            PurchaseInsightsView(
              insights: data,
              frequency: InsightFrequency.month,
              anchor: day,
              today: day,
              winsOnly: false,
              onFrequencyChanged: (_) {},
              onPeriodChanged: (_) {},
              onWinsOnlyChanged: (_) {},
              onRefresh: () async {},
              onShare: (_) async {},
            ),
            brightness: brightness,
            scale: 2,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(
          app(
            SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: MonthlyRecordCard(
                  summary: CalendarMonthSummary(insights: data, month: day),
                  onOpenRecords: () {},
                ),
              ),
            ),
            brightness: brightness,
            scale: 2,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    }
  });
}
