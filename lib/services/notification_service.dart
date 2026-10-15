import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_preference_controller.dart';
import 'user_service.dart';

class NotificationService {
  NotificationService._();
  static const _kAskedKey = 'notif_permission_asked';
  static bool _userChanged = false;
  static Future<void>? _firstLaunch;
  static final _controller = NotificationPreferenceController(
    read: () async =>
        (await SharedPreferences.getInstance()).getBool(
          UserService.notificationEnabledKey,
        ) ??
        false,
    save: (value) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAskedKey, true);
      await prefs.setBool(UserService.notificationEnabledKey, value);
    },
    requestPermission: _requestPermission,
    sync: UserService.setPersonalNotificationsEnabled,
    onSyncError: (error, stack) =>
        debugPrint('[Notification] 설정 저장 완료, 서버 반영 대기: ${error.runtimeType}'),
  );
  static ValueNotifier<bool> get enabledNotifier => _controller.enabled;
  static final pendingNotifier = UserService.notificationPendingNotifier;
  static Future<bool> isEnabled() => _controller.load();

  static Future<void> requestOnFirstLaunch() =>
      _firstLaunch ??= _requestFirstLaunch();
  static Future<void> _requestFirstLaunch() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_userChanged || (prefs.getBool(_kAskedKey) ?? false)) return;
      await prefs.setBool(_kAskedKey, true);
      if (_userChanged) return;
      await _controller.setEnabled(true);
    } catch (error) {
      debugPrint('[Notification] 첫 진입 알림 설정 실패: ${error.runtimeType}');
    }
  }

  static Future<bool> setEnabled(bool value) {
    _userChanged = true;
    return _controller.setEnabled(value);
  }

  static Future<bool> _requestPermission() async {
    final current = await FirebaseMessaging.instance.getNotificationSettings();
    final settings =
        current.authorizationStatus == AuthorizationStatus.notDetermined
        ? await FirebaseMessaging.instance.requestPermission(
            alert: true,
            badge: true,
            sound: true,
          )
        : current;
    return settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }
}
