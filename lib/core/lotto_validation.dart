bool isValidLottoGame(Iterable<int> numbers) {
  final values = numbers.toList(growable: false);
  return values.length == 6 &&
      values.toSet().length == 6 &&
      values.every((number) => number >= 1 && number <= 45);
}
