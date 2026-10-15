import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/core/lotto_palette.dart';

void main() {
  group('lottoBallColor - 구간별 공식 색상', () {
    test('1~10 노랑', () {
      for (final n in [1, 5, 10]) {
        expect(lottoBallColor(n), const Color(0xFFFBC400), reason: '$n번');
      }
    });

    test('11~20 파랑', () {
      for (final n in [11, 15, 20]) {
        expect(lottoBallColor(n), const Color(0xFF2A75F3), reason: '$n번');
      }
    });

    test('21~30 빨강', () {
      for (final n in [21, 25, 30]) {
        expect(lottoBallColor(n), const Color(0xFFE74C3C), reason: '$n번');
      }
    });

    test('31~40 검정', () {
      for (final n in [31, 35, 40]) {
        expect(lottoBallColor(n), const Color(0xFF1F1F1F), reason: '$n번');
      }
    });

    test('41~45 초록', () {
      for (final n in [41, 45]) {
        expect(lottoBallColor(n), const Color(0xFF2EAD4C), reason: '$n번');
      }
    });

    test('구간 경계에서 색이 바뀐다', () {
      expect(lottoBallColor(10) == lottoBallColor(11), isFalse);
      expect(lottoBallColor(20) == lottoBallColor(21), isFalse);
      expect(lottoBallColor(30) == lottoBallColor(31), isFalse);
      expect(lottoBallColor(40) == lottoBallColor(41), isFalse);
    });
  });

  group('lottoBallTextColor - 가독성', () {
    test('노란 볼(1~10) 위에는 어두운 글자', () {
      expect(lottoBallTextColor(1), const Color(0xFF1F1F1F));
      expect(lottoBallTextColor(10), const Color(0xFF1F1F1F));
    });

    test('검은 볼은 흰 글자, 밝은 유색 볼은 검은 글자', () {
      for (final n in [11, 25, 35, 45]) {
        expect(
          lottoBallTextColor(n),
          n == 35 ? Colors.white : Colors.black,
          reason: '$n번',
        );
      }
    });
  });
}
