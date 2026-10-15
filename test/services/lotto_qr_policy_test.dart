import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/lotto_qr_policy.dart';

void main() {
  const token = '1230m010203040506';
  const official =
      '1230q010203040506s071321293845m031418273344n000000000000n0000000000001234567890';
  test(
    'official printed root URLs support auto, semi-auto, manual and empty slots',
    () {
      for (final host in [
        'qr.dhlottery.co.kr',
        'm.dhlottery.co.kr',
        'www.dhlottery.co.kr',
      ]) {
        for (final scheme in ['http', 'https']) {
          final uri = LottoQrPolicy.fromScan('$scheme://$host/?v=$official');
          expect(uri?.host, 'qr.dhlottery.co.kr');
          expect(uri?.scheme, 'https');
          expect(LottoQrPolicy.games(uri!), [
            [1, 2, 3, 4, 5, 6],
            [7, 13, 21, 29, 38, 45],
            [3, 14, 18, 27, 33, 44],
          ]);
        }
      }
    },
  );
  test('a corrupt or unknown game slot never produces a partial ticket', () {
    for (final value in [
      '1230q010203040506q0101010101011234567890',
      '1230q010203040506q010203',
      '1230q010203040506x0713212938451234567890',
      '1230q010203040506junk',
      '1230n0000000000001234567890',
      '1230${List.filled(6, 'q010203040506').join()}',
    ]) {
      expect(
        LottoQrPolicy.games(LottoQrPolicy.fromScan(value)!),
        isNull,
        reason: value,
      );
    }
  });
  test(
    'printed HTTP ticket is upgraded and unrelated parameters are removed',
    () {
      final uri = LottoQrPolicy.fromScan(
        'http://m.dhlottery.co.kr/qr.do?method=winQr&v=$token&redirect=https://evil.invalid',
      );
      expect(uri.toString(), 'https://qr.dhlottery.co.kr/?v=$token');
      expect(LottoQrPolicy.round(uri!), 1230);
      expect(LottoQrPolicy.games(uri), [
        [1, 2, 3, 4, 5, 6],
      ]);
    },
  );

  test(
    'rejects deceptive hosts, schemes, credentials, ports and duplicate tokens',
    () {
      for (final input in [
        'https://dhlottery.co.kr.attacker.invalid/qr.do?method=winQr&v=$token',
        'https://attacker-dhlottery.co.kr/qr.do?method=winQr&v=$token',
        'https://user@m.dhlottery.co.kr/qr.do?method=winQr&v=$token',
        'javascript://m.dhlottery.co.kr/qr.do?method=winQr&v=$token',
        'https://m.dhlottery.co.kr:8443/qr.do?method=winQr&v=$token',
        'https://m.dhlottery.co.kr/redirect?v=$token',
        'https://m.dhlottery.co.kr/qr.do?method=winQr&v=$token&v=$token',
        '//m.dhlottery.co.kr/qr.do?method=winQr&v=$token',
        'https://m.dhlottery.co.kr/qr.do?method=winQr&v=%zz',
      ]) {
        expect(LottoQrPolicy.fromScan(input), isNull, reason: input);
      }
    },
  );

  test('navigation policy also rejects external redirects and subframes', () {
    expect(
      LottoQrPolicy.allowsNavigation(
        Uri.parse('https://www.dhlottery.co.kr/result'),
      ),
      isTrue,
    );
    for (final url in [
      'http://m.dhlottery.co.kr/',
      'https://evil.invalid/',
      'https://m.dhlottery.co.kr:444/',
      'https://user@m.dhlottery.co.kr/',
      'file:///tmp/a',
    ]) {
      expect(
        LottoQrPolicy.allowsNavigation(Uri.parse(url)),
        isFalse,
        reason: url,
      );
    }
  });

  test('raw tokens work but invalid numbers are never offered for saving', () {
    expect(LottoQrPolicy.fromScan(token), isNotNull);
    expect(LottoQrPolicy.fromScan('v=$token'), isNotNull);
    for (final invalid in [
      '1230m010101010101',
      '1230m000203040506',
      '1230m460203040506',
    ]) {
      expect(LottoQrPolicy.games(LottoQrPolicy.fromScan(invalid)!), isNull);
    }
    expect(
      LottoQrPolicy.round(LottoQrPolicy.fromScan('0000m010203040506')!),
      isNull,
    );
  });
}
