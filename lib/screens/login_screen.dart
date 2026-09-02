import 'package:flutter/material.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../services/apple_auth_service.dart';
import '../services/kakao_auth_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onLoginSuccess});
  final Future<void> Function() onLoginSuccess;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _loading = false;
  final bool _kakaoSupported = KakaoAuthService.isSupportedPlatform;
  final bool _appleSupported = AppleAuthService.isSupportedPlatform;

  Future<void> _loginWithKakao() async {
    setState(() => _loading = true);
    final success = await KakaoAuthService.login();
    if (!mounted) return;
    setState(() => _loading = false);

    if (success) {
      await widget.onLoginSuccess();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('로그인에 실패했습니다. 다시 시도해주세요.')),
      );
    }
  }

  Future<void> _loginWithApple() async {
    setState(() => _loading = true);
    final success = await AppleAuthService.login();
    if (!mounted) return;
    setState(() => _loading = false);

    if (success) {
      await widget.onLoginSuccess();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Apple 로그인에 실패했습니다. 다시 시도해주세요.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.casino_rounded,
                size: 72,
                color: Color(0xFFFBC400),
              ),
              const SizedBox(height: 16),
              const Text(
                '로또노트',
                style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                '통계 기반 로또 분석 앱',
                style: TextStyle(
                  fontSize: 15,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 64),

              // 카카오 로그인 버튼
              if (_kakaoSupported)
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _loginWithKakao,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFEE500),
                      foregroundColor: Colors.black87,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                    child: _loading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black54,
                            ),
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Image.asset(
                                'assets/kakao_logo.png',
                                width: 20,
                                height: 20,
                                errorBuilder: (_, __, ___) => const Icon(Icons.chat_bubble, size: 20),
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                '카카오 로그인',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),

              if (_kakaoSupported && _appleSupported)
                const SizedBox(height: 12),

              // Sign in with Apple 버튼
              if (_appleSupported)
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: SignInWithAppleButton(
                    onPressed: _loading ? () {} : _loginWithApple,
                    style: isDark
                        ? SignInWithAppleButtonStyle.white
                        : SignInWithAppleButtonStyle.black,
                    borderRadius: const BorderRadius.all(Radius.circular(12)),
                    text: 'Apple로 로그인',
                  ),
                ),

              const SizedBox(height: 16),

              // 비로그인 계속하기
              TextButton(
                onPressed: _loading ? null : () => widget.onLoginSuccess(),
                child: Text(
                  '로그인 없이 계속하기',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
