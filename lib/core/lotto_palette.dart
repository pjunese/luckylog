import 'package:flutter/material.dart';

/// 로또 번호 구간별 공식 볼 색상.
/// 1~10 노랑 / 11~20 파랑 / 21~30 빨강 / 31~40 검정 / 41~45 초록
Color lottoBallColor(int number) {
  if (number <= 10) {
    return const Color(0xFFFBC400);
  }
  if (number <= 20) {
    return const Color(0xFF2A75F3);
  }
  if (number <= 30) {
    return const Color(0xFFE74C3C);
  }
  if (number <= 40) {
    return const Color(0xFF1F1F1F);
  }
  return const Color(0xFF2EAD4C);
}

/// 볼 배경색 위에 올릴 숫자 색상 (명도 대비 확보용).
Color lottoBallTextColor(int number) {
  if (number <= 10) {
    return const Color(0xFF1F1F1F);
  }
  return number >= 31 && number <= 40 ? Colors.white : Colors.black;
}
