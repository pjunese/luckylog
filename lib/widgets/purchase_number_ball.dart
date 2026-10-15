import 'package:flutter/material.dart';
import '../core/lotto_palette.dart';

/// Misses keep full text contrast; a badge distinguishes matches without color.
class PurchaseNumberBall extends StatelessWidget {
  const PurchaseNumberBall({
    super.key,
    required this.number,
    this.matched = false,
    this.bonus = false,
    this.pending = false,
    this.size = 30,
  });
  final int number;
  final bool matched, bonus, pending;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final filled = matched || bonus || pending;
    return Semantics(
      label:
          '$number번, ${pending
              ? '추첨 전'
              : matched
              ? '당첨번호 일치'
              : bonus
              ? '보너스 번호'
              : '불일치'}',
      excludeSemantics: true,
      child: SizedBox(
        width: size + 4,
        height: size + 5,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: filled
                    ? lottoBallColor(number)
                    : colors.surfaceContainerHighest,
                border: Border.all(color: colors.outline, width: 1),
              ),
              child: Text(
                '$number',
                style: TextStyle(
                  fontSize: size * .37,
                  fontWeight: FontWeight.w800,
                  color: filled ? lottoBallTextColor(number) : colors.onSurface,
                ),
              ),
            ),
            if (matched || bonus)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: colors.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.surface),
                  ),
                  alignment: Alignment.center,
                  child: bonus
                      ? Text(
                          'B',
                          style: TextStyle(
                            fontSize: 8,
                            fontWeight: FontWeight.w900,
                            color: colors.onPrimary,
                          ),
                        )
                      : Icon(Icons.check, size: 10, color: colors.onPrimary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
