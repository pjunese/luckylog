import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/notification_router.dart';

RemoteMessage msg(Map<String, String> data) => RemoteMessage(data: data);

void main() {
  setUp(NotificationRouter.reset);

  group('parse - 개인 결과 알림', () {
    test('당첨 알림은 번호세트 > 구매내역으로 이동', () {
      final t = NotificationRouter.parse(
        msg({'type': 'win_result', 'round': '1230', 'grade': '5'}),
      );
      expect(t, isNotNull);
      expect(t!.mainTab, 1);
      expect(t.vaultSubTab, 1);
      expect(t.round, 1230);
    });

    test('낙첨 알림도 동일하게 구매내역으로 이동', () {
      final t = NotificationRouter.parse(
        msg({'type': 'lose_result', 'round': '1230', 'grade': '0'}),
      );
      expect(t!.mainTab, 1);
      expect(t.vaultSubTab, 1);
    });
  });

  group('parse - 당첨번호 발표 알림', () {
    test('type이 명시된 경우 당첨결과 탭으로 이동', () {
      final t = NotificationRouter.parse(
        msg({'type': 'draw_result', 'round': '1230'}),
      );
      expect(t!.vaultSubTab, 2);
      expect(t.round, 1230);
    });

    test('type이 없어도 (기존 토픽 알림) 당첨결과 탭으로 이동', () {
      final t = NotificationRouter.parse(msg({'round': '1230'}));
      expect(t, isNotNull);
      expect(t!.mainTab, 1);
      expect(t.vaultSubTab, 2);
    });

    test('round 없이 type도 없으면 이동하지 않음', () {
      expect(NotificationRouter.parse(msg({})), isNull);
    });
  });

  group('parse - 이동하지 않아야 하는 경우', () {
    test('null 메시지', () {
      expect(NotificationRouter.parse(null), isNull);
    });

    test('관리자용 파싱 실패 알림은 사용자 화면을 바꾸지 않음', () {
      final t = NotificationRouter.parse(
        msg({'type': 'parsing_failed', 'round': '1230'}),
      );
      expect(t, isNull);
    });

    test('알 수 없는 type은 무시', () {
      expect(
        NotificationRouter.parse(msg({'type': 'promo_event'})),
        isNull,
      );
    });

    test('round가 숫자가 아니면 null로 처리하되 개인알림은 이동은 유지', () {
      final t = NotificationRouter.parse(
        msg({'type': 'win_result', 'round': 'abc'}),
      );
      expect(t, isNotNull);
      expect(t!.round, isNull);
    });
  });

  group('pending 보관/소비', () {
    test('보관한 목적지는 한 번만 소비된다', () {
      NotificationRouter.capturePending(
        msg({'type': 'win_result', 'round': '1230'}),
      );
      expect(NotificationRouter.consumePending(), isNotNull);
      expect(NotificationRouter.consumePending(), isNull);
    });

    test('이동 대상이 아닌 알림은 보관하지 않는다', () {
      NotificationRouter.capturePending(msg({'type': 'parsing_failed'}));
      expect(NotificationRouter.consumePending(), isNull);
    });

    test('null 메시지는 보관하지 않는다', () {
      NotificationRouter.capturePending(null);
      expect(NotificationRouter.consumePending(), isNull);
    });
  });
}
