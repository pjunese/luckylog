import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqlite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:my_app/db/lotto_database.dart';
import 'package:my_app/models/number_set.dart';
import 'package:my_app/models/purchase_record.dart';
import 'package:my_app/models/scanned_ticket.dart';
import 'package:my_app/screens/login_screen.dart';
import 'package:my_app/screens/home_tab.dart';
import 'package:my_app/screens/generator_tab.dart';
import 'package:my_app/screens/vault_tab.dart';
import 'package:my_app/screens/profile_tab.dart';
import 'package:my_app/screens/stats_screen.dart';
import 'package:my_app/screens/calendar_purchase_entry_page.dart';
import 'package:my_app/services/purchase_insights_controller.dart';
import 'package:my_app/widgets/number_picker_sheet.dart';
import 'package:my_app/widgets/app_content_frame.dart';

const profiles = [
  (
    name: 'small',
    size: Size(320, 568),
    scale: 1.0,
    platform: TargetPlatform.iOS,
    padding: EdgeInsets.only(top: 20),
  ),
  (
    name: 'android',
    size: Size(360, 800),
    scale: 1.0,
    platform: TargetPlatform.android,
    padding: EdgeInsets.only(top: 24, bottom: 24),
  ),
  (
    name: 'notch',
    size: Size(393, 852),
    scale: 1.0,
    platform: TargetPlatform.iOS,
    padding: EdgeInsets.only(top: 59, bottom: 34),
  ),
  (
    name: 'large',
    size: Size(430, 932),
    scale: 1.3,
    platform: TargetPlatform.android,
    padding: EdgeInsets.only(top: 24, bottom: 24),
  ),
  (
    name: 'large-text',
    size: Size(320, 568),
    scale: 2.0,
    platform: TargetPlatform.iOS,
    padding: EdgeInsets.only(top: 20, bottom: 20),
  ),
  (
    name: 'landscape',
    size: Size(844, 390),
    scale: 1.3,
    platform: TargetPlatform.iOS,
    padding: EdgeInsets.fromLTRB(44, 0, 44, 21),
  ),
  (
    name: 'foldable',
    size: Size(600, 800),
    scale: 1.3,
    platform: TargetPlatform.android,
    padding: EdgeInsets.only(top: 24, bottom: 24),
  ),
  (
    name: 'tablet',
    size: Size(768, 1024),
    scale: 1.3,
    platform: TargetPlatform.iOS,
    padding: EdgeInsets.only(top: 24, bottom: 20),
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  sqfliteFfiInit();
  late Directory temporary;
  final db = LottoDatabase.instance;
  late PurchaseInsightsController insights;
  late List<PurchaseRecord> records;
  final games = [
    [1, 13, 18, 26, 34, 38],
    [1, 2, 3, 4, 5, 6],
  ];
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    temporary = await Directory.systemTemp.createTemp('luckylog-layout-');
    sqlite.databaseFactory = databaseFactoryFfi;
    await databaseFactoryFfi.setDatabasesPath(temporary.path);
    await db.db;
    await db.insertDrawResult(round: 1244, numbers: games.first, bonus: 25);
    await db.insertPurchaseHistory(
      games: games,
      round: 1244,
      source: 'manual',
      purchaseDate: DateTime.utc(2026, 10, 3),
    );
    records = (await db.getAllPurchaseHistory())
        .map(PurchaseRecord.fromDb)
        .toList();
    insights = PurchaseInsightsController(
      database: db,
      loadDetail: (_) async => null,
    );
    await insights.refresh();
  });
  tearDownAll(() async {
    insights.dispose();
    await db.close();
    await temporary.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> scrollPage(WidgetTester tester) async {
    final scrollables = find.byType(Scrollable);
    for (final element in scrollables.evaluate().toList()) {
      final state = (element as StatefulElement).state as ScrollableState;
      if (state.position.axis != Axis.vertical ||
          !state.position.hasContentDimensions) {
        continue;
      }
      state.position.jumpTo(state.position.maxScrollExtent);
    }
    await settle(tester);
  }

  void check(WidgetTester tester, [String? reason]) {
    final error = tester.takeException();
    if (error is FlutterError) debugPrint(error.toStringDeep());
    expect(error, isNull, reason: reason);
  }

  for (final p in profiles) {
    for (final screen in [
      'login',
      'home',
      'generator',
      'vault',
      'profile',
      'stats',
      'entry',
      'picker',
    ]) {
      testWidgets('${p.name} $screen', (tester) async {
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.view.resetViewInsets();
        });
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = p.size;
        final reportError = FlutterError.onError;
        FlutterError.onError = (details) {
          debugPrint(details.toString());
          reportError?.call(details);
        };
        try {
          final vaultKey = GlobalKey<NumberSetVaultTabState>();
          Widget child;
          switch (screen) {
            case 'login':
              child = LoginScreen(onLoginSuccess: () async {});
            case 'home':
              child = HomeTab(
                database: db,
                insights: insights,
                purchaseHistory: records,
                onSaveQrBatch: (_) async => const QrBatchSaveResult(
                  insertedCount: 0,
                  duplicateCount: 0,
                  deletedCount: 0,
                ),
                onMarkResultsChecked: (_) async {},
                onNavigateToVault: (_) {},
              );
            case 'generator':
              child = NumberGeneratorTab(onSaveSet: (_) async {});
            case 'vault':
              child = NumberSetVaultTab(
                key: vaultKey,
                savedSets: [
                  NumberSet(
                    id: 1,
                    games: games,
                    createdAt: DateTime(2026, 10, 3),
                    isPurchased: false,
                  ),
                ],
                purchaseHistory: records,
                onSaveSet: (_) async {},
                onDeleteSet: (_) async {},
                onTogglePurchased: (_, _) async {},
                onAddPurchaseHistory: (_, _, _) async {},
                onDeletePurchaseHistory: (_) async {},
                onMarkResultsChecked: (_) async {},
              );
            case 'profile':
              child = ProfileTab(
                onLogout: () async {},
                insights: insights,
                onRequireLogin: () {},
                purchaseHistory: records,
                themeMode: ThemeMode.system,
                onThemeModeChanged: (_) async {},
              );
            case 'stats':
              child = const StatsScreen();
            case 'entry':
              child = CalendarPurchaseEntryPage(
                day: DateTime.utc(2026, 10, 3),
                controller: insights,
              );
            default:
              child = const NumberPickerSheet(
                gameIndex: 0,
                initialSelection: [1, 2, 3],
                maxSelection: 6,
              );
          }
          final standalone = screen == 'login' || screen == 'entry';
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                useMaterial3: true,
                brightness: p.name == 'large-text'
                    ? Brightness.dark
                    : Brightness.light,
                colorSchemeSeed: const Color(0xFF0F766E),
                platform: p.platform,
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(p.scale),
                  padding: p.padding,
                  viewPadding: p.padding,
                ),
                child: child!,
              ),
              home: standalone
                  ? child
                  : Scaffold(
                      appBar: AppBar(title: Text(screen)),
                      body: AppContentFrame(child: child),
                      bottomNavigationBar: NavigationBar(
                        destinations: const [
                          NavigationDestination(
                            icon: Icon(Icons.home),
                            label: '홈',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.book),
                            label: '번호세트',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.bar_chart),
                            label: '통계',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.casino),
                            label: '번호 생성',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.person),
                            label: '마이페이지',
                          ),
                        ],
                      ),
                    ),
            ),
          );
          await settle(tester);
          check(tester, 'initial $screen ${p.name}');
          if (screen == 'generator') {
            await tester.ensureVisible(find.text('조건 설정'));
            await tester.tap(find.text('조건 설정'));
            await settle(tester);
            check(tester, 'filter sheet');
            await tester.tap(find.byIcon(Icons.close).last);
            await settle(tester);
            await tester.ensureVisible(find.text('번호 생성하기'));
            await tester.tap(find.text('번호 생성하기'));
            await tester.pump(const Duration(seconds: 5));
            await settle(tester);
            check(tester, 'generated numbers');
            await tester.ensureVisible(find.text('내 번호에 저장'));
            await tester.tap(find.text('내 번호에 저장'));
            await settle(tester);
            await scrollPage(tester);
            check(tester, 'saved generation');
          }
          if (screen == 'entry') {
            await tester.ensureVisible(find.text('번호 선택'));
            await tester.tap(find.text('번호 선택'));
            await settle(tester);
            check(tester, 'number picker modal');
            expect(find.text('적용').hitTestable(), findsOneWidget);
            await tester.tap(find.text('적용'));
            await settle(tester);
          }
          if (screen == 'vault') {
            for (final tab in [1, 2]) {
              vaultKey.currentState!.jumpToTab(tab);
              await settle(tester);
              check(tester);
              await scrollPage(tester);
              check(tester);
            }
          } else if (screen == 'profile' || screen == 'stats') {
            final tabs = find.byType(Tab);
            for (var i = 1; i < tabs.evaluate().length; i++) {
              await tester.tap(tabs.at(i));
              await settle(tester);
              check(tester);
              await scrollPage(tester);
              check(tester);
            }
          }
          await scrollPage(tester);
          check(tester, 'scrolled $screen ${p.name}');
          if (screen == 'stats') {
            final triples = find.text('3연번');
            await tester.scrollUntilVisible(
              triples,
              -200,
              scrollable: find.byType(Scrollable).last,
            );
            await Scrollable.ensureVisible(
              tester.element(triples),
              alignment: 0.5,
            );
            await settle(tester);
            await tester.tap(triples);
            await settle(tester);
            check(tester, 'three-number sequences');
            await scrollPage(tester);
            check(tester, 'scrolled three-number sequences');
          }
          if (screen == 'profile') {
            final feedback = find.text('의견 보내기');
            await Scrollable.ensureVisible(
              tester.element(feedback),
              alignment: 0.5,
            );
            await settle(tester);
            expect(feedback.hitTestable(), findsOneWidget);
            await tester.tap(feedback);
            await settle(tester);
            tester.view.viewInsets = FakeViewPadding(
              bottom: p.size.height > 500 ? 280 : 160,
            );
            await tester.pump(const Duration(milliseconds: 400));
            check(tester, 'feedback keyboard');
            await tester.ensureVisible(find.byType(TextField));
            await tester.enterText(find.byType(TextField), '화면 크기 점검');
            await tester.pump();
            check(tester, 'feedback input');
            await tester.tap(find.text('취소'));
            tester.view.resetViewInsets();
            await settle(tester);
          }
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await settle(tester);
          FlutterError.onError = reportError;
        }
      }, variant: TargetPlatformVariant({p.platform}));
    }
  }
}
