import '../widgets/app_snack_bar.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/lotto_qr_policy.dart';

class QRResultWebViewPage extends StatefulWidget {
  const QRResultWebViewPage({super.key, required this.initialUri});

  final Uri initialUri;

  @override
  State<QRResultWebViewPage> createState() => _QRResultWebViewPageState();
}

class _QRResultWebViewPageState extends State<QRResultWebViewPage> {
  late final WebViewController _controller;
  bool _isLoading = true;
  String? _lastError;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            return uri != null && LottoQrPolicy.allowsNavigation(uri)
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() {
              _isLoading = true;
              _lastError = null;
            });
          },
          onPageFinished: (_) {
            if (!mounted) return;
            setState(() {
              _isLoading = false;
            });
          },
          onWebResourceError: (error) {
            if (!mounted || error.isForMainFrame == false) return;
            setState(() {
              _isLoading = false;
              _lastError = error.description;
            });
          },
        ),
      );
    if (LottoQrPolicy.allowsNavigation(widget.initialUri)) {
      _controller.loadRequest(widget.initialUri);
    } else {
      _isLoading = false;
      _lastError = '허용되지 않은 주소입니다.';
    }
  }

  Future<void> _openExternal() async {
    if (!LottoQrPolicy.allowsNavigation(widget.initialUri)) return;
    final bool launched = await launchUrl(
      widget.initialUri,
      mode: LaunchMode.externalApplication,
    );
    if (!mounted) return;
    if (!launched) {
      showAppSnackBar(context, content: Text('외부 브라우저를 열지 못했습니다.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('구매복권 당첨결과'),
        actions: [
          IconButton(
            tooltip: '새로고침',
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller.reload(),
          ),
          IconButton(
            tooltip: '외부 브라우저 열기',
            icon: const Icon(Icons.open_in_new),
            onPressed: _openExternal,
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_isLoading) const LinearProgressIndicator(minHeight: 2),
          if (_lastError != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 20,
              child: Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    '페이지 로드 오류: $_lastError',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
