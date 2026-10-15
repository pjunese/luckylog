import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/models/draw_result.dart';
import 'package:my_app/models/purchase_record.dart';
import 'package:my_app/models/purchase_summary.dart';
import 'package:my_app/screens/purchase_review_page.dart';
import 'package:my_app/widgets/purchase_summary_card.dart';

const draw = DrawResult(
  round: 1230,
  winningNumbers: [1, 2, 3, 4, 5, 6],
  bonusNumber: 7,
  drawDate: '2026-09-05',
);
final now = DateTime.utc(2026, 9, 8);
PurchaseRecord ticket(int id, {int round = 1230, bool checked = false}) =>
    PurchaseRecord(
      id: id,
      round: round,
      games: const [
        [1, 2, 3, 4, 5, 7],
      ],
      drawDate: round == 1230 ? '2026-09-05' : '2026-09-12',
      source: 'qr',
      createdAt: DateTime.utc(2026, 9, 1),
      resultCheckedAt: checked ? now : null,
    );
Widget app(
  Widget child, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  String? fontFamily,
}) => MaterialApp(
  theme: ThemeData(
    colorSchemeSeed: const Color(0xFF0F766E),
    brightness: brightness,
    useMaterial3: true,
    fontFamily: fontFamily,
  ),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: child,
);

void main() {
  const previewDirectory = String.fromEnvironment('PURCHASE_PREVIEW_DIR');
  testWidgets('빈 구매 현황에서 등록으로 이동한다', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      app(
        Scaffold(
          body: PurchaseSummaryCard(
            summary: PurchaseSummary.forRound(
              round: 1231,
              records: [],
              draws: {},
            ),
            onOpenRecords: () {},
            onAddPurchase: () => opened++,
          ),
        ),
      ),
    );
    await tester.tap(find.text('구매 복권 등록'));
    expect(opened, 1);
    expect(find.text('아직 등록한 복권이 없어요.'), findsOneWidget);
  });

  testWidgets('회차 전환과 결과 열기 콜백을 호출하고 미확인 상태를 유지한다', (tester) async {
    int? changed;
    var opened = 0;
    final summary = PurchaseSummary.forRound(
      round: 1230,
      records: [ticket(1)],
      draws: {1230: draw},
    );
    await tester.pumpWidget(
      app(
        Scaffold(
          body: PurchaseSummaryCard(
            summary: summary,
            onOpenRecords: () => opened++,
            onRoundChanged: (round) => changed = round,
            availableRounds: const [1231, 1230],
          ),
        ),
      ),
    );
    await tester.tap(find.text('구매 결과 확인'));
    expect(opened, 1);
    expect(summary.uncheckedCount, 1);
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('제1231회').last);
    await tester.pumpAndSettle();
    expect(changed, 1231);
  });

  testWidgets('과거 결과 누락은 업데이트 대기로 안내하고 확인 버튼을 표시하지 않는다', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      app(
        PurchaseReviewPage(
          round: 1230,
          records: [ticket(1, checked: true)],
          draws: {},
          now: now,
          onMarkChecked: (_) async => calls++,
        ),
      ),
    );
    expect(find.text('결과 업데이트 대기'), findsWidgets);
    expect(
      find.byKey(const Key('mark-purchase-results-checked')),
      findsNothing,
    );
    expect(calls, 0);
  });

  testWidgets('선택 회차의 실제 결과 미확인 ID만 명시적으로 저장한다', (tester) async {
    List<int>? marked;
    await tester.pumpWidget(
      app(
        PurchaseReviewPage(
          round: 1230,
          records: [
            ticket(1),
            ticket(2, checked: true),
            ticket(3, round: 1231),
          ],
          draws: {1230: draw},
          onMarkChecked: (ids) async => marked = ids,
        ),
      ),
    );
    expect(marked, isNull);
    final button = find.byKey(const Key('mark-purchase-results-checked'));
    await tester.scrollUntilVisible(
      button,
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(marked, [1]);
    expect(find.text('이 회차의 결과를 모두 확인했어요.'), findsOneWidget);
    expect(find.text('2등'), findsWidgets);
    expect(find.text('5개 + 보너스 적중'), findsWidgets);
  });

  testWidgets('저장 중 중복 클릭을 막고 실패하면 미확인 상태에서 재시도한다', (tester) async {
    final gate = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      app(
        PurchaseReviewPage(
          round: 1230,
          records: [ticket(1)],
          draws: {1230: draw},
          onMarkChecked: (_) {
            calls++;
            return calls == 1 ? gate.future : Future.value();
          },
        ),
      ),
    );
    final button = find.byKey(const Key('mark-purchase-results-checked'));
    await tester.scrollUntilVisible(
      button,
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(button);
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    gate.completeError(Exception('offline'));
    await tester.pumpAndSettle();
    expect(find.text('확인 상태를 저장하지 못했어요. 다시 눌러주세요.'), findsOneWidget);
    expect(find.text('결과 미확인'), findsOneWidget);
    await tester.scrollUntilVisible(
      button,
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('이 회차의 결과를 모두 확인했어요.'), findsOneWidget);
  });

  testWidgets('열린 페이지에 새 결과와 기록이 도착하면 상태와 확인 대상이 갱신된다', (tester) async {
    List<int>? marked;
    Widget page(Map<int, DrawResult> draws, List<PurchaseRecord> records) =>
        app(
          PurchaseReviewPage(
            key: const ValueKey('review'),
            round: 1230,
            records: records,
            draws: draws,
            onMarkChecked: (ids) async => marked = ids,
            now: now,
          ),
        );
    await tester.pumpWidget(page({}, [ticket(1)]));
    expect(
      find.byKey(const Key('mark-purchase-results-checked')),
      findsNothing,
    );
    await tester.pumpWidget(page({1230: draw}, [ticket(1), ticket(4)]));
    final button = find.byKey(const Key('mark-purchase-results-checked'));
    await tester.scrollUntilVisible(
      button,
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(marked, unorderedEquals([1, 4]));
  });

  testWidgets('360폭 큰 글씨와 밝은·어두운 테마에서 카드와 상세가 넘치지 않는다', (tester) async {
    tester.view.physicalSize = const Size(360, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        app(
          Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: PurchaseSummaryCard(
                  summary: PurchaseSummary.forRound(
                    round: 1230,
                    records: [ticket(1), ticket(2, checked: true)],
                    draws: {1230: draw},
                  ),
                  onOpenRecords: () {},
                  onRoundChanged: (_) {},
                  availableRounds: const [1230, 1231],
                ),
              ),
            ),
          ),
          brightness: brightness,
          scale: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.bySemanticsLabel('결과 미확인 1장'), findsOneWidget);
      await tester.pumpWidget(
        app(
          PurchaseReviewPage(
            round: 1230,
            records: [ticket(1)],
            draws: {1230: draw},
            onMarkChecked: (_) async {},
          ),
          brightness: brightness,
          scale: 2,
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('mark-purchase-results-checked')),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    semantics.dispose();
  });

  testWidgets('구매 요약과 상세 화면 시각 검토 이미지 생성', (tester) async {
    tester.view.physicalSize = const Size(360, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.runAsync(() async {
      final file = File('/System/Library/Fonts/AppleSDGothicNeo.ttc');
      if (await file.exists()) {
        final loader = FontLoader('PurchasePreview');
        loader.addFont(file.readAsBytes().then(ByteData.sublistView));
        await loader.load();
      }
      final icons = FontLoader('MaterialIcons');
      icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
    Future<void> save(String name) async {
      await tester.pumpAndSettle();
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory(previewDirectory);
        await directory.create(recursive: true);
        await File(
          '${directory.path}/$name.png',
        ).writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        await tester.pumpWidget(
          app(
            RepaintBoundary(
              key: key,
              child: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(16),
                  child: PurchaseSummaryCard(
                    summary: PurchaseSummary.forRound(
                      round: 1230,
                      records: [ticket(1), ticket(2, checked: true)],
                      draws: {1230: draw},
                    ),
                    onOpenRecords: () {},
                    onRoundChanged: (_) {},
                    availableRounds: const [1230, 1231],
                  ),
                ),
              ),
            ),
            brightness: brightness,
            scale: scale,
            fontFamily: 'PurchasePreview',
          ),
        );
        await save(
          'summary-${brightness.name}${scale > 1 ? '-large-text' : ''}',
        );
      }
    }
    await tester.pumpWidget(
      app(
        RepaintBoundary(
          key: key,
          child: PurchaseReviewPage(
            round: 1230,
            records: [ticket(1)],
            draws: {1230: draw},
            onMarkChecked: (_) async {},
          ),
        ),
        fontFamily: 'PurchasePreview',
      ),
    );
    await save('purchase-review');
  }, skip: previewDirectory.isEmpty);
}
