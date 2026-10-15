import 'package:flutter/material.dart';

import '../core/lotto_palette.dart';

/// 공유용 당첨 결과 카드.
///
/// 캡처 대신 앱이 직접 그려서 내보내는 이미지라, 화면 테마와 무관하게
/// 항상 동일한 결과가 나오도록 색을 고정한다.
class ResultShareCard extends StatelessWidget {
  const ResultShareCard({
    super.key,
    required this.round,
    required this.numbers,
    required this.winningNumbers,
    required this.bonusNumber,
    required this.rankLabel,
    this.amount = 0,
    this.drawDate,
  });

  final int round;

  /// 사용자가 구매한 번호 6개
  final List<int> numbers;

  /// 해당 회차 당첨번호 6개 (맞은 번호 강조용)
  final List<int> winningNumbers;
  final int bonusNumber;

  /// '1등' ~ '5등' 또는 '낙첨'
  final String rankLabel;

  /// 확정 당첨금. 0이면 표시하지 않는다(1~3등은 회차별 변동).
  final int amount;

  final String? drawDate;

  static const Color _ink = Color(0xFF14161A);
  static const Color _muted = Color(0xFF8A9099);
  static const Color _line = Color(0xFFE8EAED);
  static const Color _accent = Color(0xFF0F766E);

  bool get _isWin => rankLabel != '낙첨';

  int get _matchCount =>
      numbers.where((n) => winningNumbers.contains(n)).length;

  bool get _bonusMatched => numbers.contains(bonusNumber);

  String get _formattedAmount {
    final s = amount.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return '$buf원';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 340,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(28, 30, 28, 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '제 $round회',
            style: const TextStyle(
              fontSize: 13,
              color: _muted,
              fontWeight: FontWeight.w500,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 6),

          // 결과 한 줄 — 카드에서 가장 먼저 읽히는 정보
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                _isWin ? rankLabel : '아쉽게 낙첨',
                style: TextStyle(
                  fontSize: 30,
                  height: 1.1,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1,
                  color: _isWin ? _accent : _ink,
                ),
              ),
              if (_isWin && amount > 0) ...[
                const SizedBox(width: 8),
                Text(
                  _formattedAmount,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: _muted,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _bonusMatched && _matchCount == 5
                ? '5개 + 보너스 적중'
                : '$_matchCount개 적중',
            style: const TextStyle(fontSize: 13, color: _muted),
          ),

          const SizedBox(height: 22),
          _numberRow(),
          const SizedBox(height: 22),

          Container(height: 1, color: _line),
          const SizedBox(height: 12),

          Row(
            children: [
              if (drawDate != null && drawDate!.isNotEmpty)
                Text(
                  drawDate!,
                  style: const TextStyle(fontSize: 11, color: _muted),
                ),
              const Spacer(),
              const Text(
                '럭키로그',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: _ink,
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 맞은 번호는 공식 색, 못 맞은 번호는 회색으로 낮춰 대비를 준다.
  Widget _numberRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: numbers.map((n) {
        final matched = winningNumbers.contains(n);
        return Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: matched ? lottoBallColor(n) : const Color(0xFFF1F3F5),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(
            '$n',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: matched ? lottoBallTextColor(n) : _muted,
            ),
          ),
        );
      }).toList(),
    );
  }
}
