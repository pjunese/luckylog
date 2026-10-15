import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/models/scanned_ticket.dart';
import 'package:my_app/screens/qr_scan_page.dart';
import 'package:my_app/widgets/qr_camera.dart';

const first = '1230q0102030405060000000001';
const second = '1230q0102030405060000000002';
const third = '1231s071321293845m0314182733440000000003';

class FakeCamera implements QrCamera {
  ValueChanged<List<String>>? onDetected;
  final Map<String, List<String>> images = {};
  final List<String> analyzed = [];
  int starts = 0;
  int stops = 0;
  bool disposed = false;
  Completer<List<String>>? analysisGate;

  @override
  Widget buildPreview(
    BuildContext context,
    ValueChanged<List<String>> onDetect,
  ) {
    onDetected = onDetect;
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF152E2A), Color(0xFF345D52)],
        ),
      ),
      child: Center(
        child: Icon(Icons.qr_code_2, size: 100, color: Color(0xFFB4CFC4)),
      ),
    );
  }

  @override
  Future<void> start() async {
    starts++;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  Future<List<String>> analyzeImage(String path) async {
    analyzed.add(path);
    return analysisGate?.future ?? images[path] ?? [];
  }
}

void main() {
  late FakeCamera camera;
  late bool returned;
  List<ScannedTicket>? result;
  final boundaryKey = GlobalKey();

  setUpAll(() async {
    const configuredSdk = String.fromEnvironment('FLUTTER_PREVIEW_SDK');
    final sdk = configuredSdk.isNotEmpty
        ? configuredSdk
        : Platform.environment['FLUTTER_ROOT'] ?? '';
    final icons = File(
      '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (await icons.exists()) {
      final loader = FontLoader('MaterialIcons');
      loader.addFont(
        Future.value(ByteData.sublistView(await icons.readAsBytes())),
      );
      await loader.load();
    }
    // Optional local visual QA uses the platform Korean font; the tests remain
    // runnable on CI hosts without it.
    final font = File('/System/Library/Fonts/AppleSDGothicNeo.ttc');
    if (await font.exists()) {
      final loader = FontLoader('QrPreviewKorean');
      loader.addFont(
        Future.value(ByteData.sublistView(await font.readAsBytes())),
      );
      await loader.load();
    }
  });

  setUp(() {
    camera = FakeCamera();
    returned = false;
    result = null;
  });

  Future<void> openPage(
    WidgetTester tester, {
    Set<String> known = const {},
    Future<void> Function(List<ScannedTicket>)? onSave,
    Future<List<String>> Function()? pickImages,
    Future<void> Function(BuildContext, Uri)? openResult,
    Size size = const Size(390, 844),
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF0F766E),
              brightness: brightness,
            ),
            fontFamily: 'QrPreviewKorean',
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async {
                    result = await Navigator.of(context)
                        .push<List<ScannedTicket>>(
                          MaterialPageRoute(
                            builder: (_) => QRScanPage(
                              knownFingerprints: known,
                              onSave: onSave,
                              camera: camera,
                              pickImages: pickImages,
                              openResult: openResult,
                            ),
                          ),
                        );
                    returned = true;
                  },
                  child: const Text('스캐너 열기'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('스캐너 열기'));
    await tester.pumpAndSettle();
  }

  Future<void> emit(WidgetTester tester, List<String> values) async {
    camera.onDetected!(values);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'continuous queue returns only after explicit save and supports remove',
    (tester) async {
      await openPage(tester);
      await emit(tester, [first, second]);
      expect(returned, false);
      expect(find.text('등록 대기 2장'), findsOneWidget);
      await tester.tap(find.byTooltip('1230회 복권을 대기 목록에서 제외').first);
      await tester.pumpAndSettle();
      // A stationary camera callback cannot immediately resurrect the removal.
      await emit(tester, [first, second]);
      expect(find.text('등록 대기 1장'), findsOneWidget);
      await tester.tap(find.byKey(const Key('qr-save')));
      await tester.pumpAndSettle();
      expect(returned, true);
      expect(result, hasLength(1));
      expect(
        result!.single.fingerprint,
        ScannedTicket.tryParse(second)!.fingerprint,
      );
      expect(camera.disposed, true);
    },
  );

  testWidgets(
    'empty camera frame allows a deliberately removed ticket to be rescanned',
    (tester) async {
      await openPage(tester);
      await emit(tester, [first]);
      await tester.tap(find.byTooltip('1230회 복권을 대기 목록에서 제외'));
      await tester.pumpAndSettle();
      await emit(tester, [first]);
      expect(find.text('등록 대기 0장'), findsOneWidget);
      await emit(tester, []);
      await emit(tester, [first]);
      expect(find.text('등록 대기 1장'), findsOneWidget);
    },
  );

  testWidgets('known/deleted ticket and foreign QR cannot enable save', (
    tester,
  ) async {
    await openPage(tester, known: {ScannedTicket.tryParse(first)!.fingerprint});
    await emit(tester, [first]);
    expect(find.text('이미 등록한 복권입니다. 삭제했다면 구매내역 휴지통에서 복원해주세요.'), findsOneWidget);
    await emit(tester, ['https://evil.invalid/']);
    expect(find.text('동행복권 로또 QR 코드를 비춰 주세요.'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('qr-save'))).onPressed,
      isNull,
    );
  });

  testWidgets(
    'multiple photos ingest every barcode and keep camera available',
    (tester) async {
      camera.images.addAll({
        'one': [first, second],
        'two': [second, third],
        'empty': [],
      });
      await openPage(tester, pickImages: () async => ['one', 'two', 'empty']);
      await tester.tap(find.byTooltip('사진 여러 장에서 QR 읽기').last);
      await tester.pumpAndSettle();
      expect(camera.analyzed, ['one', 'two', 'empty']);
      expect(find.text('등록 대기 3장'), findsOneWidget);
      expect(find.text('3장 추가 · 중복 1건 제외 · 1건 확인 필요'), findsOneWidget);
      expect(camera.stops, greaterThan(0));
      expect(camera.starts, greaterThan(1));
      expect(returned, false);
    },
  );

  testWidgets('safe but unparseable QR offers optional result lookup', (
    tester,
  ) async {
    Uri? viewed;
    await openPage(
      tester,
      openResult: (_, uri) async {
        viewed = uri;
      },
    );
    await emit(tester, ['1230m010101010101']);
    await tester.tap(find.text('동행복권에서 결과 보기'));
    await tester.pumpAndSettle();
    expect(viewed!.scheme, 'https');
    expect(viewed!.host, 'qr.dhlottery.co.kr');
    expect(find.text('등록 대기 0장'), findsOneWidget);
    expect(camera.stops, greaterThan(0));
    expect(returned, false);
  });

  testWidgets('save failure retains batch for retry', (tester) async {
    var attempts = 0;
    await openPage(
      tester,
      onSave: (_) async {
        if (++attempts == 1) throw StateError('temporary storage failure');
      },
    );
    await emit(tester, [first, third]);
    await tester.tap(find.byKey(const Key('qr-save')));
    await tester.pumpAndSettle();
    expect(returned, false);
    expect(find.text('등록 대기 2장'), findsOneWidget);
    expect(find.textContaining('목록은 그대로'), findsOneWidget);
    await tester.tap(find.byKey(const Key('qr-save')));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(result, hasLength(2));
  });

  testWidgets('saving disables camera input, remove, photos and back', (
    tester,
  ) async {
    final saving = Completer<void>();
    await openPage(tester, onSave: (_) => saving.future);
    await emit(tester, [first]);
    await tester.tap(find.byKey(const Key('qr-save')));
    await tester.pump();
    camera.onDetected!([third]);
    await tester.pump();
    expect(find.text('등록 대기 1장'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '뒤로',
            ),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is IconButton &&
                  widget.tooltip == '1230회 복권을 대기 목록에서 제외',
            ),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('qr-save'))).onPressed,
      isNull,
    );
    saving.complete();
    await tester.pumpAndSettle();
    expect(result, hasLength(1));
  });

  testWidgets('back keeps queue unless user confirms discard', (tester) async {
    await openPage(tester);
    await emit(tester, [first]);
    await tester.tap(find.byTooltip('뒤로'));
    await tester.pumpAndSettle();
    expect(find.textContaining('아직 저장되지 않았습니다'), findsOneWidget);
    await tester.tap(find.text('계속 스캔'));
    await tester.pumpAndSettle();
    expect(returned, false);
    expect(find.text('등록 대기 1장'), findsOneWidget);
    await tester.tap(find.byTooltip('뒤로'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('나가기'));
    await tester.pumpAndSettle();
    expect(returned, true);
    expect(result, isNull);
  });

  testWidgets(
    'camera pauses in background and late callbacks after dispose are ignored',
    (tester) async {
      await openPage(tester);
      final callback = camera.onDetected!;
      final before = camera.stops;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(camera.stops, greaterThan(before));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      callback([first]);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(camera.disposed, true);
    },
  );

  testWidgets('late photo analysis after route disposal cannot mutate UI', (
    tester,
  ) async {
    camera.analysisGate = Completer<List<String>>();
    await openPage(tester, pickImages: () async => ['pending']);
    await tester.tap(find.byTooltip('사진 여러 장에서 QR 읽기').last);
    await tester.pump();
    await tester.pump();
    expect(camera.analyzed, ['pending']);
    await tester.pumpWidget(const SizedBox.shrink());
    camera.analysisGate!.complete([first]);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'narrow dark large-text layout and lookup notice have no overflow',
    (tester) async {
      await openPage(
        tester,
        size: const Size(320, 568),
        textScale: 2,
        brightness: Brightness.dark,
      );
      await emit(tester, [first, second, third]);
      await emit(tester, ['1230m010101010101']);
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -350));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('export optional visual QA previews', (tester) async {
    const previewPath = String.fromEnvironment('QR_PREVIEW_PATH');
    if (previewPath.isEmpty) return;
    await openPage(tester);
    await emit(tester, [first, third, '1231m0915192733450000000004']);
    Future<void> capture(String path) async {
      await tester.runAsync(() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(path).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture(previewPath);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    camera = FakeCamera();
    await openPage(
      tester,
      size: const Size(320, 568),
      textScale: 2,
      brightness: Brightness.dark,
    );
    await emit(tester, [first, third]);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -170));
    await tester.pumpAndSettle();
    await capture(previewPath.replaceFirst('.png', '-dark-large.png'));
  });
}
