import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// The page owns this adapter, including its disposal. Tests can supply a
/// camera-free implementation while exercising the actual registration UI.
abstract interface class QrCamera {
  Widget buildPreview(
    BuildContext context,
    ValueChanged<List<String>> onDetect,
  );
  Future<void> start();
  Future<void> stop();
  Future<List<String>> analyzeImage(String path);
  Future<void> dispose();
}

class DeviceQrCamera implements QrCamera {
  final _controller = MobileScannerController(
    autoStart: false,
    formats: const [BarcodeFormat.qrCode],
  );

  @override
  Widget buildPreview(
    BuildContext context,
    ValueChanged<List<String>> onDetect,
  ) => MobileScanner(
    controller: _controller,
    useAppLifecycleState: false,
    onDetect: (capture) => onDetect([
      for (final barcode in capture.barcodes)
        if (barcode.rawValue case final String raw) raw,
    ]),
    errorBuilder: (context, error) => const ColoredBox(
      color: Color(0xFF162523),
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            '카메라를 사용할 수 없어요.\n아래 사진 버튼으로 QR을 읽어 주세요.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white),
          ),
        ),
      ),
    ),
  );

  @override
  Future<void> start() => _controller.start();
  @override
  Future<void> stop() => _controller.stop();
  @override
  Future<void> dispose() => _controller.dispose();

  @override
  Future<List<String>> analyzeImage(String path) async {
    final capture = await _controller.analyzeImage(
      path,
      formats: const [BarcodeFormat.qrCode],
    );
    return [
      for (final barcode in capture?.barcodes ?? <Barcode>[])
        if (barcode.rawValue case final String raw) raw,
    ];
  }
}
