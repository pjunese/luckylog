import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// 알림을 눌렀을 때 이동할 화면 좌표.
/// [mainTab]은 하단 네비게이션 인덱스, [vaultSubTab]은 번호세트 탭의 서브탭 인덱스.
@immutable
class NotificationTarget {
  const NotificationTarget({
    required this.mainTab,
    this.vaultSubTab,
    this.round,
  });

  final int mainTab;
  final int? vaultSubTab;
  final int? round;

  @override
  bool operator ==(Object other) =>
      other is NotificationTarget &&
      other.mainTab == mainTab &&
      other.vaultSubTab == vaultSubTab &&
      other.round == round;

  @override
  int get hashCode => Object.hash(mainTab, vaultSubTab, round);

  @override
  String toString() =>
      'NotificationTarget(mainTab: $mainTab, vaultSubTab: $vaultSubTab, round: $round)';
}

/// FCM 알림 탭 → 화면 이동 규칙을 담당.
///
/// 앱이 완전히 종료된 상태에서 알림으로 실행되면 화면이 아직 없으므로,
/// [capturePending]으로 보관했다가 메인 화면이 준비된 뒤 [consumePending]으로 꺼내 쓴다.
class NotificationRouter {
  NotificationRouter._();

  // 하단 탭 인덱스 (main.dart의 탭 순서와 일치해야 함)
  static const int _tabVault = 1;

  // 번호세트 화면의 서브탭 인덱스
  static const int _vaultPurchaseHistory = 1; // 구매내역
  static const int _vaultDrawResult = 2; // 당첨결과

  static NotificationTarget? _pending;

  /// 알림 payload를 화면 좌표로 변환. 이동할 필요가 없으면 null.
  static NotificationTarget? parse(RemoteMessage? message) {
    if (message == null) return null;
    final Map<String, dynamic> data = message.data;
    final String type = (data['type'] as String?)?.trim() ?? '';
    final int? round = int.tryParse('${data['round'] ?? ''}');

    switch (type) {
      // 개인 당첨/낙첨 결과 → 내 구매내역에서 결과 확인
      case 'win_result':
      case 'lose_result':
        return NotificationTarget(
          mainTab: _tabVault,
          vaultSubTab: _vaultPurchaseHistory,
          round: round,
        );

      // 관리자용 파싱 실패 알림은 일반 사용자 화면 이동 대상이 아님
      case 'parsing_failed':
        return null;

      // type이 없는 알림은 당첨번호 발표(draw_result 토픽) → 당첨결과 탭
      case '':
      case 'draw_result':
        if (round == null) return null;
        return NotificationTarget(
          mainTab: _tabVault,
          vaultSubTab: _vaultDrawResult,
          round: round,
        );

      default:
        debugPrint('[NotificationRouter] 알 수 없는 type: $type');
        return null;
    }
  }

  /// 종료 상태에서 알림으로 실행된 경우를 대비해 목적지를 보관.
  static void capturePending(RemoteMessage? message) {
    final target = parse(message);
    if (target != null) {
      _pending = target;
      debugPrint('[NotificationRouter] 대기 중인 이동: $target');
    }
  }

  /// 보관된 목적지를 꺼내고 비운다. (한 번만 소비됨)
  static NotificationTarget? consumePending() {
    final target = _pending;
    _pending = null;
    return target;
  }

  /// 테스트용: 보관 상태 초기화.
  @visibleForTesting
  static void reset() => _pending = null;
}
