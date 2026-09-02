/// yyyy-MM-dd HH:mm 형식으로 포맷.
String formatDateTime(DateTime value) {
  final String month = value.month.toString().padLeft(2, '0');
  final String day = value.day.toString().padLeft(2, '0');
  final String hour = value.hour.toString().padLeft(2, '0');
  final String minute = value.minute.toString().padLeft(2, '0');
  return '${value.year}-$month-$day $hour:$minute';
}

/// 맞은 개수와 보너스 일치 여부로 등수 라벨을 반환.
/// 6개=1등, 5개+보너스=2등, 5개=3등, 4개=4등, 3개=5등, 그 외 낙첨.
String rankLabel({required int matchCount, required bool bonusMatch}) {
  if (matchCount == 6) {
    return '1등';
  }
  if (matchCount == 5 && bonusMatch) {
    return '2등';
  }
  if (matchCount == 5) {
    return '3등';
  }
  if (matchCount == 4) {
    return '4등';
  }
  if (matchCount == 3) {
    return '5등';
  }
  return '낙첨';
}
