import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

// ─── QR 스캔 화면 ──────────────────────────────────────────────
class QRScanPage extends StatefulWidget {
  const QRScanPage({super.key});

  @override
  State<QRScanPage> createState() => _QRScanPageState();
}

class _QRScanPageState extends State<QRScanPage> {
  final MobileScannerController _scannerController = MobileScannerController();
  bool _scanned = false;
  bool _pickingImage = false;

  @override
  void dispose() {
    unawaited(_scannerController.dispose());
    super.dispose();
  }

  Future<void> _pickAndScanQrImage() async {
    if (_pickingImage || _scanned) {
      return;
    }

    setState(() => _pickingImage = true);
    try {
      final XFile? picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
      );
      if (picked == null) {
        return;
      }

      final BarcodeCapture? capture = await _scannerController.analyzeImage(
        picked.path,
      );
      final String? rawValue = capture?.barcodes.firstOrNull?.rawValue;

      if (!mounted) {
        return;
      }

      if (rawValue == null || rawValue.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('이미지에서 QR 코드를 찾지 못했습니다.')));
        return;
      }

      _scanned = true;
      Navigator.of(context).pop(rawValue);
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('이미지 분석 실패: $e')));
    } finally {
      if (mounted) {
        setState(() => _pickingImage = false);
      }
    }
  }

  Widget _buildScannerError(MobileScannerException error) {
    final bool unsupported =
        error.errorCode == MobileScannerErrorCode.unsupported;
    final String message = unsupported
        ? '이 기기(시뮬레이터)에서는 카메라 스캔을 사용할 수 없습니다.\n아래 버튼으로 사진에서 QR을 읽어주세요.'
        : (error.errorDetails?.message ?? error.errorCode.message);

    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 15),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('QR 스캔'),
        actions: [
          IconButton(
            onPressed: _pickingImage ? null : _pickAndScanQrImage,
            tooltip: '사진에서 QR 읽기',
            icon: const Icon(Icons.photo_library_outlined),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _scannerController,
            errorBuilder: (_, error) => _buildScannerError(error),
            onDetect: (capture) {
              if (_scanned) return;
              final barcode = capture.barcodes.firstOrNull;
              if (barcode?.rawValue == null) return;
              _scanned = true;
              Navigator.of(context).pop(barcode!.rawValue);
            },
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: FilledButton.icon(
              onPressed: _pickingImage ? null : _pickAndScanQrImage,
              icon: _pickingImage
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.photo_library_outlined),
              label: Text(_pickingImage ? '분석 중...' : '사진에서 QR 읽기'),
            ),
          ),
        ],
      ),
    );
  }
}
