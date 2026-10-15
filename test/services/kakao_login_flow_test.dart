import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/kakao_login_flow.dart';

void main() {
  test('Talk success does not open account login', () async {
    final value = await loginWithKakaoFallback(
      isTalkInstalled: () async => true,
      loginWithTalk: () async => 'talk',
      loginWithAccount: () async => fail('Unexpected account login'),
    );
    expect(value, 'talk');
  });
  test('Missing Talk uses account login', () async {
    final value = await loginWithKakaoFallback(
      isTalkInstalled: () async => false,
      loginWithTalk: () async => fail('Unexpected Talk login'),
      loginWithAccount: () async => 'account',
    );
    expect(value, 'account');
  });
  for (final error in [
    PlatformException(code: 'AUTH_ERROR'),
    StateError('SDK'),
  ]) {
    test('Talk error ${error.runtimeType} falls back once', () async {
      var attempts = 0;
      final value = await loginWithKakaoFallback(
        isTalkInstalled: () async => true,
        loginWithTalk: () async => throw error,
        loginWithAccount: () async {
          attempts++;
          return 'account';
        },
      );
      expect(value, 'account');
      expect(attempts, 1);
    });
  }
  test('User cancellation never opens another login', () async {
    final error = PlatformException(code: 'CANCELED');
    await expectLater(
      loginWithKakaoFallback(
        isTalkInstalled: () async => true,
        loginWithTalk: () async => throw error,
        loginWithAccount: () async => fail('Cancellation must be respected'),
      ),
      throwsA(same(error)),
    );
  });
  test('Account failure propagates without retrying', () async {
    final error = StateError('account failed');
    var attempts = 0;
    await expectLater(
      loginWithKakaoFallback(
        isTalkInstalled: () async => true,
        loginWithTalk: () async => throw StateError('talk failed'),
        loginWithAccount: () async {
          attempts++;
          throw error;
        },
      ),
      throwsA(same(error)),
    );
    expect(attempts, 1);
  });
}
