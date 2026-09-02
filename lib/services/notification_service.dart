import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 알림 권한 요청과 추첨결과 토픽 구독을 한 곳에서 관리.
///
/// 첫 진입 시 1회 자동 요청([requestOnFirstLaunch])과
/// 마이페이지 설정 토글([setEnabled])이 같은 구현을 공유한다.
class NotificationService {
  NotificationService._();

  /// 추첨결과 알림 수신 여부 (마이페이지 토글 상태)
  static const String _kEnabledKey = 'notif_draw_result';

  /// 첫 진입 권한 요청을 이미 했는지 (중복 요청 방지)
  static const String _kAskedKey = 'notif_permission_asked';

  static const String _kTopic = 'draw_result';

  /// 알림 수신 상태. 설정 화면이 이 값을 구독해서 표시한다.
  ///
  /// 첫 진입 권한 요청은 설정 화면이 만들어진 "뒤에" 끝나므로,
  /// 단순히 initState에서 한 번 읽으면 항상 옛 값(false)을 보게 된다.
  /// 상태를 여기 한 곳에 두고 알려주는 방식으로 그 순서 문제를 없앤다.
  static final ValueNotifier<bool> enabledNotifier = ValueNotifier<bool>(false);

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getBool(_kEnabledKey) ?? false;
    enabledNotifier.value = value;
    return value;
  }

  /// 앱 첫 진입 시 딱 한 번 알림 권한을 요청한다.
  /// 사용자가 허용하면 추첨결과 토픽을 자동 구독한다.
  ///
  /// 이미 물어봤거나 이미 켜져 있으면 아무 것도 하지 않는다.
  static Future<void> requestOnFirstLaunch() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kAskedKey) ?? false) return;

    // 다시 묻지 않도록 먼저 기록 (요청 도중 종료돼도 반복 요청 방지)
    await prefs.setBool(_kAskedKey, true);

    try {
      final granted = await _requestPermission();
      if (!granted) {
        debugPrint('[Notification] 첫 진입 권한 거부됨');
        return;
      }
      await FirebaseMessaging.instance.subscribeToTopic(_kTopic);
      await prefs.setBool(_kEnabledKey, true);
      enabledNotifier.value = true;
      debugPrint('[Notification] 첫 진입 권한 허용 → 토픽 구독 완료');
    } catch (e) {
      debugPrint('[Notification] 첫 진입 권한 요청 실패: $e');
    }
  }

  /// 마이페이지 토글. 실제로 반영된 상태를 반환한다.
  /// (권한이 거부되면 켜달라고 해도 false가 돌아온다)
  static Future<bool> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();

    if (value) {
      final granted = await _requestPermission();
      if (!granted) return false;
      await FirebaseMessaging.instance.subscribeToTopic(_kTopic);
    } else {
      await FirebaseMessaging.instance.unsubscribeFromTopic(_kTopic);
    }

    await prefs.setBool(_kEnabledKey, value);
    // 토글을 직접 건드렸다면 첫 진입 요청은 더 이상 필요 없다
    await prefs.setBool(_kAskedKey, true);
    enabledNotifier.value = value;
    return value;
  }

  static Future<bool> _requestPermission() async {
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    final status = settings.authorizationStatus;
    return status == AuthorizationStatus.authorized ||
        status == AuthorizationStatus.provisional;
  }
}
