import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 위젯을 이미지로 만들어 공유한다.
///
/// 화면에 실제로 배치하지 않고 렌더링해야 하므로, 별도의 렌더 트리를 만들어
/// 한 프레임만 그린 뒤 픽셀을 뽑아낸다. (사용자에게는 아무 것도 보이지 않는다)
class ShareService {
  ShareService._();

  /// [widget]을 PNG로 렌더링해 공유 시트를 띄운다.
  ///
  /// [pixelRatio]가 높을수록 선명하지만 용량이 커진다. 3이면 카톡/인스타에
  /// 올려도 깨지지 않는 수준.
  static Future<bool> shareWidget({
    required Widget widget,
    required Size size,
    String? text,
    String fileName = 'luckylog',
    double pixelRatio = 3.0,
  }) async {
    try {
      final bytes = await _renderToPng(
        widget: widget,
        size: size,
        pixelRatio: pixelRatio,
      );
      if (bytes == null) return false;

      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/${fileName}_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(bytes);

      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: text),
      );
      return true;
    } catch (e, st) {
      debugPrint('[Share] 공유 실패: $e');
      debugPrint('$st');
      return false;
    }
  }

  /// 화면 밖에서 위젯 한 장을 그려 PNG 바이트로 돌려준다.
  static Future<Uint8List?> _renderToPng({
    required Widget widget,
    required Size size,
    required double pixelRatio,
  }) async {
    final repaintBoundary = RenderRepaintBoundary();
    final view = WidgetsBinding.instance.platformDispatcher.views.first;

    final renderView = RenderView(
      view: view,
      child: RenderPositionedBox(
        alignment: Alignment.center,
        child: repaintBoundary,
      ),
      configuration: ViewConfiguration(
        logicalConstraints: BoxConstraints.tight(size),
        devicePixelRatio: pixelRatio,
      ),
    );

    final pipelineOwner = PipelineOwner()..rootNode = renderView;
    renderView.prepareInitialFrame();

    final buildOwner = BuildOwner(focusManager: FocusManager());
    final rootElement =
        RenderObjectToWidgetAdapter<RenderBox>(
          container: repaintBoundary,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: MediaQuery(
              // 사용자의 시스템 글꼴 크기 설정이 카드 레이아웃을 깨뜨리지 않도록 고정
              data: const MediaQueryData(textScaler: TextScaler.noScaling),
              child: widget,
            ),
          ),
        ).attachToRenderTree(buildOwner);

    buildOwner
      ..buildScope(rootElement)
      ..finalizeTree();
    pipelineOwner
      ..flushLayout()
      ..flushCompositingBits()
      ..flushPaint();

    final image = await repaintBoundary.toImage(pixelRatio: pixelRatio);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();

    return byteData?.buffer.asUint8List();
  }
}
