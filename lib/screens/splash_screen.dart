import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

Color _ballColor(int number) {
  if (number <= 10) return const Color(0xFFFBC400);
  if (number <= 20) return const Color(0xFF2A75F3);
  if (number <= 30) return const Color(0xFFE74C3C);
  if (number <= 40) return const Color(0xFF1F1F1F);
  return const Color(0xFF2EAD4C);
}

Color _ballTextColor(int number) {
  if (number <= 10) return const Color(0xFF1F1F1F);
  return Colors.white;
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.onComplete});
  final VoidCallback onComplete;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  final Random _rng = Random();
  final List<int> _display = [1, 1, 1, 1, 1, 1];
  final List<int> _final = [];
  final List<bool> _stopped = [false, false, false, false, false, false];

  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;

  Timer? _rollTimer;

  @override
  void initState() {
    super.initState();

    // 랜덤 6개 번호 생성 (1~45 중복 없이 정렬)
    final pool = List.generate(45, (i) => i + 1)..shuffle(_rng);
    _final.addAll((pool.take(6).toList()..sort()));

    // 텍스트 페이드인 애니메이션
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeIn);

    _startAnimation();
  }

  void _startAnimation() {
    // 롤링 시작
    _rollTimer = Timer.periodic(const Duration(milliseconds: 60), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        for (int i = 0; i < 6; i++) {
          if (!_stopped[i]) _display[i] = _rng.nextInt(45) + 1;
        }
      });
    });

    // 볼 하나씩 순서대로 멈춤
    for (int i = 0; i < 6; i++) {
      Future.delayed(Duration(milliseconds: 1200 + i * 380), () {
        if (!mounted) return;
        setState(() {
          _stopped[i] = true;
          _display[i] = _final[i];
        });

        // 마지막 볼 멈춘 뒤 텍스트 등장 → 완료
        if (i == 5) {
          _rollTimer?.cancel();
          Future.delayed(const Duration(milliseconds: 350), () {
            if (!mounted) return;
            _fadeCtrl.forward();
          });
          Future.delayed(const Duration(milliseconds: 1400), () {
            if (!mounted) return;
            widget.onComplete();
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _rollTimer?.cancel();
    _fadeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEBF5FB),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 볼 2열 배치 (3 + 3)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(3, (i) => _buildBall(i)),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(3, (i) => _buildBall(i + 3)),
            ),
            const SizedBox(height: 48),

            // 로또노트 텍스트 페이드인
            FadeTransition(
              opacity: _fadeAnim,
              child: Column(
                children: [
                  const Text(
                    '로또노트',
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1565C0),
                      letterSpacing: 3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '번호를 기록하다',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.blue.shade400,
                      letterSpacing: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBall(int index) {
    final int num = _display[index];
    final bool stopped = _stopped[index];

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.symmetric(horizontal: 8),
      width: 62,
      height: 62,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: stopped ? _ballColor(num) : const Color(0xFFD0E8F8),
        boxShadow: stopped
            ? [
                BoxShadow(
                  color: _ballColor(num).withValues(alpha: 0.45),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ]
            : [],
      ),
      child: Center(
        child: Text(
          num.toString(),
          style: TextStyle(
            color: stopped ? _ballTextColor(num) : const Color(0xFF90C4E8),
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
