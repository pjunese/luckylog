/// 번호 하나의 통계 데이터
class NumberStat {
  const NumberStat({
    required this.number,
    required this.freq,
    required this.lastAppeared,
    required this.absenceCount,
    required this.avgFreq,
  });

  final int number;        // 번호 (1~45)
  final int freq;          // 해당 구간 출현 횟수
  final int lastAppeared;  // 마지막 출현 회차
  final int absenceCount;  // 현재 연속 미출현 횟수
  final double avgFreq;    // 해당 구간 평균 출현 횟수

  /// 평균 대비 출현 비율 (1.0 = 평균)
  double get freqRatio => avgFreq == 0 ? 0 : freq / avgFreq;

  /// 핫 넘버: 평균보다 25% 이상 많이 나온 번호
  bool get isHot => freqRatio >= 1.25;

  /// 콜드 넘버: 평균보다 25% 이상 적게 나온 번호
  bool get isCold => freqRatio <= 0.75;

  /// 가중치: 미출현 오래될수록, 빈도 낮을수록 높음
  double get weight {
    final double absenceScore = absenceCount.toDouble();
    final double freqScore = avgFreq == 0 ? 0 : avgFreq / (freq + 0.1);
    return absenceScore * 0.6 + freqScore * 0.4 + 0.1;
  }

  @override
  String toString() =>
      'NumberStat(number: $number, freq: $freq, absence: $absenceCount)';
}

/// 회차 하나의 패턴 분석 데이터
class RoundPattern {
  const RoundPattern({
    required this.round,
    required this.numbers,
    required this.bonus,
  });

  final int round;
  final List<int> numbers;
  final int bonus;

  int get sum => numbers.fold(0, (a, b) => a + b);

  int get oddCount => numbers.where((n) => n.isOdd).length;
  int get evenCount => numbers.where((n) => n.isEven).length;

  /// 연속 번호 쌍 개수
  int get consecutiveCount {
    int count = 0;
    final sorted = List<int>.from(numbers)..sort();
    for (int i = 0; i < sorted.length - 1; i++) {
      if (sorted[i + 1] - sorted[i] == 1) count++;
    }
    return count;
  }

  /// 구간 분포: key='1~10' 등
  Map<String, int> get rangeDistribution {
    final map = {'1~10': 0, '11~20': 0, '21~30': 0, '31~40': 0, '41~45': 0};
    for (final n in numbers) {
      if (n <= 10) {
        map['1~10'] = map['1~10']! + 1;
      } else if (n <= 20) map['11~20'] = map['11~20']! + 1;
      else if (n <= 30) map['21~30'] = map['21~30']! + 1;
      else if (n <= 40) map['31~40'] = map['31~40']! + 1;
      else map['41~45'] = map['41~45']! + 1;
    }
    return map;
  }
}
