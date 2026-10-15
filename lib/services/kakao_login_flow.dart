import 'package:flutter/services.dart';

/// Kakao recommends account login when Talk is unavailable or fails.
/// An explicit cancellation must never open another sign-in flow.
Future<T> loginWithKakaoFallback<T>({
  required Future<bool> Function() isTalkInstalled,
  required Future<T> Function() loginWithTalk,
  required Future<T> Function() loginWithAccount,
}) async {
  if (await isTalkInstalled()) {
    try {
      return await loginWithTalk();
    } on PlatformException catch (error) {
      if (error.code == 'CANCELED') rethrow;
    } catch (_) {
      // Kakao SDK errors also use the account flow as the fallback.
    }
  }
  return loginWithAccount();
}
