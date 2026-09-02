/// 특정 회차의 당첨 결과 (당첨번호 6개 + 보너스).
class DrawResult {
  const DrawResult({
    required this.round,
    required this.winningNumbers,
    required this.bonusNumber,
    required this.drawDate,
  });

  final int round;
  final List<int> winningNumbers;
  final int bonusNumber;
  final String drawDate;
}
