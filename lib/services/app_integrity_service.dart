import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show appFlavor;

class AppIntegrityService {
  AppIntegrityService._();

  static Future<void> initialize() async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.iOS &&
            defaultTargetPlatform != TargetPlatform.android)) {
      return;
    }
    // Debug bypasses must never be embedded in a production Release build.
    final debug = appFlavor == 'dev' && kDebugMode;
    try {
      await FirebaseAppCheck.instance
          .activate(
            providerAndroid: debug
                ? const AndroidDebugProvider()
                : const AndroidPlayIntegrityProvider(),
            providerApple: debug
                ? const AppleDebugProvider()
                : const AppleAppAttestProvider(),
          )
          .timeout(const Duration(seconds: 5));
    } catch (error) {
      // Existing authentication and private data remain in monitoring mode.
      // The new nearby endpoint separately requires a valid attestation.
      debugPrint('[AppCheck] initialization deferred: ${error.runtimeType}');
    }
  }
}
