import 'package:flutter/material.dart';

import '../core/lotto_palette.dart';

class MiniLottoBall extends StatelessWidget {
  const MiniLottoBall({super.key, required this.number, this.isBonus = false});

  final int number;
  final bool isBonus;

  @override
  Widget build(BuildContext context) {
    final Color bg = lottoBallColor(number);
    final Color fg = lottoBallTextColor(number);
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: isBonus
            ? Border.all(
                color: Theme.of(context).colorScheme.onSurface,
                width: 2,
              )
            : null,
      ),
      alignment: Alignment.center,
      child: Text(
        '$number',
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }
}
