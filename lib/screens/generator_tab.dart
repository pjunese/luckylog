import '../widgets/app_snack_bar.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../core/lotto_palette.dart';

class NumberGeneratorTab extends StatefulWidget {
  const NumberGeneratorTab({super.key, required this.onSaveSet});

  final Future<void> Function(List<List<int>>) onSaveSet;

  @override
  State<NumberGeneratorTab> createState() => _NumberGeneratorTabState();
}

class _NumberGeneratorTabState extends State<NumberGeneratorTab>
    with TickerProviderStateMixin {
  // 슬롯 상태
  List<int?> _numbers = List.filled(6, null);
  final List<int> _rollingDisplay = List.generate(6, (_) => 1);
  bool _isRolling = false;
  List<bool> _locked = List.filled(6, false);
  final List<Timer?> _rollTimers = List.filled(6, null);
  final List<Timer?> _stopTimers = List.filled(6, null);

  // 생성 모드
  bool _photoMode = false;
  bool _analyzingPhoto = false;
  bool _photoGenerated = false;
  Uint8List? _photoBytes; // 메모리에만 유지 (파일 삭제 후)
  Color? _photoColorA;
  Color? _photoColorB;
  Color? _photoColorC;

  // 세션 저장 목록
  final List<List<int>> _generatedGames = [];

  // 조건 설정
  // 연번: 0=없음, 2=2연번제외, 3=3연번제외
  int _consecutiveMode = 0;
  // 홀짝: 0=자유, 2=2홀4짝, 3=3홀3짝, 4=4홀2짝
  int _oddEvenMode = 0;
  // 합계: 0=자유, 1=~110(낮음), 2=111~150(보통), 3=151~175(높음), 4=176~(매우높음)
  int _sumMode = 0;
  // 특정수 제외/포함
  final Set<int> _excludedNumbers = {};
  final Set<int> _includedNumbers = {};

  int get _activeConditionCount {
    int c = 0;
    if (_consecutiveMode > 0) c++;
    if (_oddEvenMode > 0) c++;
    if (_sumMode > 0) c++;
    if (_excludedNumbers.isNotEmpty) c++;
    if (_includedNumbers.isNotEmpty) c++;
    return c;
  }

  @override
  void dispose() {
    for (final t in _rollTimers) {
      t?.cancel();
    }
    for (final t in _stopTimers) {
      t?.cancel();
    }
    super.dispose();
  }

  // 조건 검사
  bool _checkConditions(List<int> nums) {
    final List<int> sorted = [...nums]..sort();

    // 연번 제외
    if (_consecutiveMode == 2) {
      for (int i = 0; i < sorted.length - 1; i++) {
        if (sorted[i + 1] - sorted[i] == 1) return false;
      }
    } else if (_consecutiveMode == 3) {
      for (int i = 0; i < sorted.length - 2; i++) {
        if (sorted[i + 1] - sorted[i] == 1 &&
            sorted[i + 2] - sorted[i + 1] == 1) {
          return false;
        }
      }
    }

    // 홀짝 비율
    if (_oddEvenMode > 0) {
      final int oddCount = nums.where((n) => n % 2 == 1).length;
      if (oddCount != _oddEvenMode) return false;
    }

    // 합계 구간
    if (_sumMode > 0) {
      final int sum = nums.fold(0, (a, b) => a + b);
      if (_sumMode == 1 && sum > 110) return false;
      if (_sumMode == 2 && (sum < 111 || sum > 150)) return false;
      if (_sumMode == 3 && (sum < 151 || sum > 175)) return false;
      if (_sumMode == 4 && sum < 176) return false;
    }

    return true;
  }

  void _openFilterSheet() {
    int tempConsecutiveMode = _consecutiveMode;
    int tempOddEvenMode = _oddEvenMode;
    int tempSumMode = _sumMode;
    final Set<int> tempExcludedNumbers = Set<int>.from(_excludedNumbers);
    final Set<int> tempIncludedNumbers = Set<int>.from(_includedNumbers);
    bool tempShowExcludeGrid = _excludedNumbers.isNotEmpty;
    bool tempShowIncludeGrid = _includedNumbers.isNotEmpty;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void update(VoidCallback fn) {
            setSheet(fn);
          }

          int activeConditionCount() {
            int c = 0;
            if (tempConsecutiveMode > 0) c++;
            if (tempOddEvenMode > 0) c++;
            if (tempSumMode > 0) c++;
            if (tempExcludedNumbers.isNotEmpty) c++;
            if (tempIncludedNumbers.isNotEmpty) c++;
            return c;
          }

          void saveAndClose() {
            setState(() {
              _consecutiveMode = tempConsecutiveMode;
              _oddEvenMode = tempOddEvenMode;
              _sumMode = tempSumMode;
              _excludedNumbers
                ..clear()
                ..addAll(tempExcludedNumbers);
              _includedNumbers
                ..clear()
                ..addAll(tempIncludedNumbers);
            });
            Navigator.pop(ctx);
          }

          Widget sectionTitle(String title) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.black54,
              ),
            ),
          );

          Widget optionChip(
            String label,
            bool selected,
            VoidCallback onTap,
          ) => GestureDetector(
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0xFFFBC400)
                    : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: selected
                      ? const Color(0xFFFBC400)
                      : Colors.grey.shade300,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  color: selected ? Colors.black : Colors.grey.shade600,
                ),
              ),
            ),
          );

          return Container(
            decoration: BoxDecoration(
              color: Theme.of(ctx).colorScheme.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
            ),
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 헤더
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '조건 설정',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (activeConditionCount() > 0)
                        GestureDetector(
                          onTap: () => update(() {
                            tempConsecutiveMode = 0;
                            tempOddEvenMode = 0;
                            tempSumMode = 0;
                            tempExcludedNumbers.clear();
                          }),
                          child: Text(
                            '초기화',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.red.shade400,
                            ),
                          ),
                        ),
                      const SizedBox(width: 12),
                      TextButton(
                        onPressed: saveAndClose,
                        style: TextButton.styleFrom(
                          minimumSize: const Size(52, 34),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          foregroundColor: const Color(0xFF0F766E),
                          textStyle: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        child: const Text('저장'),
                      ),
                      const SizedBox(width: 2),
                      GestureDetector(
                        onTap: () => Navigator.pop(ctx),
                        child: Icon(Icons.close, color: Colors.grey.shade400),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // ── 연번 제외 ──
                  sectionTitle('연번 제외'),
                  Wrap(
                    spacing: 8,
                    children: [
                      optionChip(
                        '없음',
                        tempConsecutiveMode == 0,
                        () => update(() => tempConsecutiveMode = 0),
                      ),
                      optionChip(
                        '2연번 제외',
                        tempConsecutiveMode == 2,
                        () => update(
                          () => tempConsecutiveMode = tempConsecutiveMode == 2
                              ? 0
                              : 2,
                        ),
                      ),
                      optionChip(
                        '3연번 제외',
                        tempConsecutiveMode == 3,
                        () => update(
                          () => tempConsecutiveMode = tempConsecutiveMode == 3
                              ? 0
                              : 3,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tempConsecutiveMode == 2
                        ? '연속된 두 번호가 포함되지 않습니다'
                        : tempConsecutiveMode == 3
                        ? '연속된 세 번호가 포함되지 않습니다 (두 연번은 허용)'
                        : '',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                  ),
                  const SizedBox(height: 20),

                  // ── 홀짝 비율 ──
                  sectionTitle('홀짝 비율'),
                  Wrap(
                    spacing: 8,
                    children: [
                      optionChip(
                        '자유',
                        tempOddEvenMode == 0,
                        () => update(() => tempOddEvenMode = 0),
                      ),
                      optionChip(
                        '2홀 4짝',
                        tempOddEvenMode == 2,
                        () => update(
                          () => tempOddEvenMode = tempOddEvenMode == 2 ? 0 : 2,
                        ),
                      ),
                      optionChip(
                        '3홀 3짝',
                        tempOddEvenMode == 3,
                        () => update(
                          () => tempOddEvenMode = tempOddEvenMode == 3 ? 0 : 3,
                        ),
                      ),
                      optionChip(
                        '4홀 2짝',
                        tempOddEvenMode == 4,
                        () => update(
                          () => tempOddEvenMode = tempOddEvenMode == 4 ? 0 : 4,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // ── 합계 구간 ──
                  sectionTitle('번호 합계 구간'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      optionChip(
                        '자유',
                        tempSumMode == 0,
                        () => update(() => tempSumMode = 0),
                      ),
                      optionChip(
                        '낮음 (~110)',
                        tempSumMode == 1,
                        () => update(
                          () => tempSumMode = tempSumMode == 1 ? 0 : 1,
                        ),
                      ),
                      optionChip(
                        '보통 (111~150)',
                        tempSumMode == 2,
                        () => update(
                          () => tempSumMode = tempSumMode == 2 ? 0 : 2,
                        ),
                      ),
                      optionChip(
                        '높음 (151~175)',
                        tempSumMode == 3,
                        () => update(
                          () => tempSumMode = tempSumMode == 3 ? 0 : 3,
                        ),
                      ),
                      optionChip(
                        '매우 높음 (176~)',
                        tempSumMode == 4,
                        () => update(
                          () => tempSumMode = tempSumMode == 4 ? 0 : 4,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // ── 특정수 제외 ──
                  _NumberFilterToggleSection(
                    title: '특정수 제외',
                    isActive: tempShowExcludeGrid,
                    selectedNumbers: tempExcludedNumbers,
                    conflictNumbers: tempIncludedNumbers,
                    activeColor: Colors.red.shade400,
                    onToggle: (v) => update(() {
                      tempShowExcludeGrid = v;
                      if (!v) tempExcludedNumbers.clear();
                    }),
                    onNumberTap: (n) => update(() {
                      if (tempExcludedNumbers.contains(n)) {
                        tempExcludedNumbers.remove(n);
                      } else {
                        tempIncludedNumbers.remove(n);
                        tempExcludedNumbers.add(n);
                      }
                    }),
                    onApply: () => update(() => tempShowExcludeGrid = false),
                    onClear: () => update(() => tempExcludedNumbers.clear()),
                  ),
                  const SizedBox(height: 12),

                  // ── 특정수 포함 ──
                  _NumberFilterToggleSection(
                    title: '특정수 포함',
                    isActive: tempShowIncludeGrid,
                    selectedNumbers: tempIncludedNumbers,
                    conflictNumbers: tempExcludedNumbers,
                    activeColor: const Color(0xFF2A75F3),
                    onToggle: (v) => update(() {
                      tempShowIncludeGrid = v;
                      if (!v) tempIncludedNumbers.clear();
                    }),
                    onNumberTap: (n) => update(() {
                      if (tempIncludedNumbers.contains(n)) {
                        tempIncludedNumbers.remove(n);
                      } else {
                        tempExcludedNumbers.remove(n);
                        tempIncludedNumbers.add(n);
                      }
                    }),
                    onApply: () => update(() => tempShowIncludeGrid = false),
                    onClear: () => update(() => tempIncludedNumbers.clear()),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 카오스 이론 기반 난수 생성 (sin 함수 활용)
  /// seed: 마이크로초 기반, 반복적으로 sin을 적용해 예측 불가능한 값 생성
  double _chaosNext(double prev) {
    return (sin(prev * 99991.0 + pi) * 1e9).abs() % 1.0;
  }

  void _generate() {
    if (_isRolling) return;

    // 카오스 시드: 하위 비트만 사용해 정밀도 손실 방지
    final int ts = DateTime.now().microsecondsSinceEpoch;
    double chaosVal = ((ts % 999983) / 999983.0) + ((ts % 997) / 997000.0);
    chaosVal = chaosVal % 1.0;
    // 초기 워밍업 (예측 불가능성 강화)
    for (int w = 0; w < 13; w++) {
      chaosVal = _chaosNext(chaosVal);
    }

    // 잠금 슬롯 번호 수집
    final List<int> lockedNums = [];
    for (int i = 0; i < 6; i++) {
      if (_locked[i] && _numbers[i] != null) lockedNums.add(_numbers[i]!);
    }
    // 언락 슬롯 인덱스
    final List<int> unlockedSlots = List.generate(
      6,
      (i) => i,
    ).where((i) => !_locked[i] || _numbers[i] == null).toList();
    final int needCount = unlockedSlots.length;

    // 포함 번호 (잠금/제외 번호와 중복 제거)
    final List<int> includedValid = _includedNumbers
        .where((n) => !lockedNums.contains(n) && !_excludedNumbers.contains(n))
        .toList();

    // 조건에 맞는 언락 슬롯 번호 생성 (최대 500번 시도)
    List<int> newUnlocked = [];
    int attempts = 0;
    while (attempts < 500) {
      attempts++;
      final List<int> pool = List.generate(45, (i) => i + 1);
      pool.removeWhere(
        (n) => lockedNums.contains(n) || _excludedNumbers.contains(n),
      );
      if (pool.length < needCount) break;

      // 카오스 기반 셔플 (Fisher-Yates + sin chaos)
      for (int i = pool.length - 1; i > 0; i--) {
        chaosVal = _chaosNext(chaosVal);
        final int j = (chaosVal * (i + 1)).floor().clamp(0, i);
        final int tmp = pool[i];
        pool[i] = pool[j];
        pool[j] = tmp;
      }

      // 포함 번호 우선 배치 후 나머지 채움
      final List<int> chosen = [];
      for (final n in includedValid) {
        if (pool.contains(n) && chosen.length < needCount) {
          chosen.add(n);
          pool.remove(n);
        }
      }
      for (final n in pool) {
        if (chosen.length >= needCount) break;
        chosen.add(n);
      }

      // 전체 조건 검사 (잠금 + 언락)
      final List<int> candidate = [...lockedNums, ...chosen]..sort();
      if (_checkConditions(candidate)) {
        newUnlocked = chosen;
        break;
      }
    }

    if (newUnlocked.isEmpty && needCount > 0) {
      showAppSnackBar(
        context,
        content: Text('조건이 너무 엄격해서 번호를 생성할 수 없습니다. 조건을 완화해주세요.'),
        duration: Duration(seconds: 2),
      );
      return;
    }

    // 슬롯별 번호 배정 (잠금 슬롯은 유지, 언락 슬롯에 새 번호)
    final List<int> newNumbers = List.filled(6, 0);
    for (int i = 0; i < 6; i++) {
      if (_locked[i] && _numbers[i] != null) {
        newNumbers[i] = _numbers[i]!;
      }
    }
    for (int j = 0; j < unlockedSlots.length; j++) {
      newNumbers[unlockedSlots[j]] = newUnlocked[j];
    }

    setState(() {
      _isRolling = true;
    });

    // 마지막 언락 슬롯 인덱스 찾기
    final int lastUnlocked = List.generate(
      6,
      (i) => i,
    ).lastWhere((i) => !(_locked[i] && _numbers[i] != null), orElse: () => -1);

    // 슬롯별로 순서대로 멈춤
    for (int i = 0; i < 6; i++) {
      if (_locked[i] && _numbers[i] != null) continue;

      // 롤링 타이머 - 빠르게 숫자 변경
      _rollTimers[i] = Timer.periodic(const Duration(milliseconds: 60), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() {
          _rollingDisplay[i] =
              (sin(
                            DateTime.now().microsecondsSinceEpoch *
                                pi *
                                (i + 1) *
                                0.0001,
                          ) *
                          1e9)
                      .abs()
                      .toInt() %
                  45 +
              1;
        });
      });

      // 멈춤 타이머 - i번째 슬롯은 (i+1)*400ms 후 멈춤
      _stopTimers[i] = Timer(Duration(milliseconds: 400 + i * 350), () {
        _rollTimers[i]?.cancel();
        if (!mounted) return;
        setState(() {
          _rollingDisplay[i] = newNumbers[i];
          _numbers[i] = newNumbers[i];
        });

        // 마지막 언락 슬롯이 멈추면 isRolling 종료
        if (i == lastUnlocked) {
          setState(() {
            _isRolling = false;
          });
        }
      });
    }

    // 잠긴 슬롯은 롤링 없이 기존 번호 유지 + isRolling 보정
    final bool anyUnlocked = _locked.any((l) => !l);
    if (!anyUnlocked) {
      setState(() {
        _isRolling = false;
      });
    }
  }

  Future<void> _saveToVault() async {
    if (_numbers.any((n) => n == null)) return;
    final List<int> nums = _numbers.cast<int>();
    setState(() {
      _generatedGames.add([...nums]);
      _numbers = List.filled(6, null);
      _locked = List.filled(6, false);
    });
    await widget.onSaveSet([
      [...nums]..sort(),
    ]);
    if (mounted) {
      showAppSnackBar(
        context,
        content: Text('번호 세트에 저장됐습니다'),
        duration: Duration(seconds: 2),
      );
    }
  }

  void _reset() {
    if (_isRolling) return;
    setState(() {
      _numbers = List.filled(6, null);
      _locked = List.filled(6, false);
    });
  }

  Future<void> _pickPhotoAndGenerate() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 80,
      maxWidth: 400,
      maxHeight: 400,
    );
    if (picked == null) return;

    setState(() {
      _analyzingPhoto = true;
      _photoGenerated = false;
    });

    final file = File(picked.path);

    // 파일 삭제 전에 bytes를 메모리에 로드 (표시용)
    Uint8List? imageBytes;
    try {
      imageBytes = await file.readAsBytes();
    } catch (e) {
      // 미리보기용이라 실패해도 번호 생성은 계속 진행
      debugPrint('[Generator] 사진 바이트 로드 실패: $e');
    }

    final result = await _extractSeedFromPhoto(file);

    // 분석 완료 즉시 파일 삭제 (프라이버시 보호 — 메모리에만 유지)
    try {
      await file.delete();
    } catch (e) {
      // 프라이버시: 임시 사진 삭제 실패는 추적 가능해야 한다
      debugPrint('[Generator] 임시 사진 삭제 실패: $e');
    }

    if (!mounted) return;
    setState(() {
      _analyzingPhoto = false;
      _photoGenerated = true;
      _photoBytes = imageBytes;
      _photoColorA = result.colorA;
      _photoColorB = result.colorB;
      _photoColorC = result.colorC;
    });
    _generateWithSeed(result.seed);
  }

  Future<_PhotoSeedResult> _extractSeedFromPhoto(File file) async {
    final fallback = _PhotoSeedResult(
      seed: DateTime.now().microsecondsSinceEpoch,
      colorA: Colors.grey.shade400,
      colorB: Colors.grey.shade600,
      colorC: Colors.grey.shade800,
    );
    try {
      final bytes = await file.readAsBytes();
      final codec = await instantiateImageCodec(
        bytes,
        targetWidth: 60,
        targetHeight: 60,
      );
      final frame = await codec.getNextFrame();
      final byteData = await frame.image.toByteData(
        format: ImageByteFormat.rawRgba,
      );
      if (byteData == null) return fallback;

      final pixels = byteData.buffer.asUint8List();
      int sumR = 0, sumG = 0, sumB = 0, varSum = 0;
      int count = 0;

      for (int i = 0; i < pixels.length; i += 4) {
        sumR += pixels[i];
        sumG += pixels[i + 1];
        sumB += pixels[i + 2];
        count++;
      }
      if (count == 0) return fallback;

      final avgR = sumR ~/ count;
      final avgG = sumG ~/ count;
      final avgB = sumB ~/ count;

      for (int i = 0; i < pixels.length; i += 4) {
        varSum +=
            (pixels[i] - avgR).abs() +
            (pixels[i + 1] - avgG).abs() +
            (pixels[i + 2] - avgB).abs();
      }
      final variance = varSum ~/ count;

      // 사진에서 추출한 3가지 대표 색상 (상단/중간/하단 영역 평균)
      final third = pixels.length ~/ 3;
      int r1 = 0,
          g1 = 0,
          b1 = 0,
          r2 = 0,
          g2 = 0,
          b2 = 0,
          r3 = 0,
          g3 = 0,
          b3 = 0,
          c = 0;
      for (int i = 0; i < third; i += 4) {
        r1 += pixels[i];
        g1 += pixels[i + 1];
        b1 += pixels[i + 2];
        c++;
      }
      final n1 = c == 0 ? 1 : c;
      c = 0;
      for (int i = third; i < third * 2; i += 4) {
        r2 += pixels[i];
        g2 += pixels[i + 1];
        b2 += pixels[i + 2];
        c++;
      }
      final n2 = c == 0 ? 1 : c;
      c = 0;
      for (int i = third * 2; i < pixels.length; i += 4) {
        r3 += pixels[i];
        g3 += pixels[i + 1];
        b3 += pixels[i + 2];
        c++;
      }
      final n3 = c == 0 ? 1 : c;

      return _PhotoSeedResult(
        seed: avgR * 1000000 + avgG * 10000 + avgB * 100 + variance,
        colorA: Color.fromARGB(255, r1 ~/ n1, g1 ~/ n1, b1 ~/ n1),
        colorB: Color.fromARGB(255, r2 ~/ n2, g2 ~/ n2, b2 ~/ n2),
        colorC: Color.fromARGB(255, r3 ~/ n3, g3 ~/ n3, b3 ~/ n3),
      );
    } catch (_) {
      return fallback;
    }
  }

  Widget _buildPhotoArea(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // 분석 중 상태
    if (_analyzingPhoto) {
      return Container(
        height: 160,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: cs.primary,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '색상 분석 중...',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    // 분석 완료 상태 (사진 + 색상 팔레트)
    if (_photoGenerated) {
      return GestureDetector(
        onTap: _isRolling ? null : _pickPhotoAndGenerate,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            children: [
              // 배경: 사진 (bytes로 표시)
              SizedBox(
                height: 180,
                width: double.infinity,
                child: _photoBytes != null
                    ? Image.memory(_photoBytes!, fit: BoxFit.cover)
                    : Container(color: cs.surfaceContainerHighest),
              ),
              // 어두운 오버레이
              Container(
                height: 180,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.1),
                      Colors.black.withValues(alpha: 0.55),
                    ],
                  ),
                ),
              ),
              // 하단 정보
              Positioned(
                left: 16,
                right: 16,
                bottom: 14,
                child: Row(
                  children: [
                    // 색상 스워치
                    if (_photoColorA != null) ...[
                      _ColorSwatch(_photoColorA!, size: 22),
                      const SizedBox(width: 5),
                      _ColorSwatch(_photoColorB!, size: 22),
                      const SizedBox(width: 5),
                      _ColorSwatch(_photoColorC!, size: 22),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        '이 색감으로 번호를 뽑았어요',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    // 다시 찍기 버튼
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.4),
                          width: 1,
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.camera_alt_outlined,
                            size: 12,
                            color: Colors.white,
                          ),
                          SizedBox(width: 4),
                          Text(
                            '다시 찍기',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
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

    // 초기 상태 (카메라 버튼)
    return GestureDetector(
      onTap: _isRolling ? null : _pickPhotoAndGenerate,
      child: Container(
        height: 160,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: cs.outlineVariant,
            width: 1.5,
            style: BorderStyle.solid,
          ),
          color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.add_a_photo_outlined,
                size: 26,
                color: cs.primary,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '사진 찍어서 번호 뽑기',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 5),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock_outline, size: 11, color: Colors.grey.shade500),
                const SizedBox(width: 3),
                Text(
                  '사진은 저장되지 않아요',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _generateWithSeed(int seed) {
    if (_isRolling) return;

    // 시드 기반 Fisher-Yates 셔플
    double chaosVal = ((seed % 999983) / 999983.0) + ((seed % 997) / 997000.0);
    chaosVal = chaosVal % 1.0;
    for (int w = 0; w < 13; w++) {
      chaosVal = _chaosNext(chaosVal);
    }

    final List<int> pool = List.generate(45, (i) => i + 1);
    for (int i = pool.length - 1; i > 0; i--) {
      chaosVal = _chaosNext(chaosVal);
      final int j = (chaosVal * (i + 1)).floor().clamp(0, i);
      final int tmp = pool[i];
      pool[i] = pool[j];
      pool[j] = tmp;
    }
    final List<int> newNumbers = pool.take(6).toList();

    setState(() => _isRolling = true);

    for (int i = 0; i < 6; i++) {
      _rollTimers[i] = Timer.periodic(const Duration(milliseconds: 60), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() {
          _rollingDisplay[i] =
              (sin(
                            DateTime.now().microsecondsSinceEpoch *
                                pi *
                                (i + 1) *
                                0.0001,
                          ) *
                          1e9)
                      .abs()
                      .toInt() %
                  45 +
              1;
        });
      });

      _stopTimers[i] = Timer(Duration(milliseconds: 400 + i * 350), () {
        _rollTimers[i]?.cancel();
        if (!mounted) return;
        setState(() {
          _rollingDisplay[i] = newNumbers[i];
          _numbers[i] = newNumbers[i];
        });
        if (i == 5) setState(() => _isRolling = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool hasNumbers = _numbers.any((n) => n != null);
    final int condCount = _activeConditionCount;

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          children: [
            // 상단 타이틀
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
              child: Column(
                children: [
                  Text(
                    '번호 생성',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  // 모드 선택
                  Container(
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.all(4),
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() {
                              _photoMode = false;
                              _photoGenerated = false;
                              _photoBytes = null;
                              _photoColorA = _photoColorB = _photoColorC = null;
                              _reset();
                            }),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              decoration: BoxDecoration(
                                color: !_photoMode
                                    ? Theme.of(context).colorScheme.surface
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(9),
                                boxShadow: !_photoMode
                                    ? [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.08,
                                          ),
                                          blurRadius: 4,
                                        ),
                                      ]
                                    : null,
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.casino_outlined,
                                    size: 16,
                                    color: !_photoMode
                                        ? Theme.of(context).colorScheme.primary
                                        : Colors.grey,
                                  ),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      '랜덤',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13,
                                        color: !_photoMode
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.primary
                                            : Colors.grey,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() {
                              _photoMode = true;
                              _photoGenerated = false;
                              _photoBytes = null;
                              _photoColorA = _photoColorB = _photoColorC = null;
                              _reset();
                            }),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              decoration: BoxDecoration(
                                color: _photoMode
                                    ? Theme.of(context).colorScheme.surface
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(9),
                                boxShadow: _photoMode
                                    ? [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.08,
                                          ),
                                          blurRadius: 4,
                                        ),
                                      ]
                                    : null,
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.camera_alt_outlined,
                                    size: 16,
                                    color: _photoMode
                                        ? Theme.of(context).colorScheme.primary
                                        : Colors.grey,
                                  ),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      '사진으로 뽑기',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13,
                                        color: _photoMode
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.primary
                                            : Colors.grey,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 32),

            // 슬롯 6개
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final ballSize = min(50.0, (constraints.maxWidth - 30) / 6);
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: List.generate(6, (i) {
                      final int? num = _numbers[i];
                      final bool rolling =
                          _isRolling && (!_locked[i] || num == null);
                      final int display = rolling
                          ? _rollingDisplay[i]
                          : (num ?? _rollingDisplay[i]);
                      final bool confirmed = num != null;

                      return GestureDetector(
                        onTap: confirmed && !_isRolling
                            ? () => setState(() => _locked[i] = !_locked[i])
                            : null,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              width: ballSize,
                              height: ballSize,
                              decoration: BoxDecoration(
                                color: confirmed
                                    ? lottoBallColor(display)
                                    : Colors.grey.shade200,
                                shape: BoxShape.circle,
                                boxShadow: confirmed
                                    ? [
                                        BoxShadow(
                                          color: lottoBallColor(
                                            display,
                                          ).withValues(alpha: 0.4),
                                          blurRadius: 8,
                                          offset: const Offset(0, 3),
                                        ),
                                      ]
                                    : null,
                              ),
                              child: Center(
                                child: rolling
                                    ? Text(
                                        '$display',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: lottoBallTextColor(display),
                                        ),
                                      )
                                    : confirmed
                                    ? Text(
                                        '$num',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: lottoBallTextColor(num),
                                        ),
                                      )
                                    : Text(
                                        '?',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.grey.shade400,
                                        ),
                                      ),
                              ),
                            ),
                            if (_locked[i] && confirmed)
                              Positioned(
                                top: -4,
                                right: -4,
                                child: Container(
                                  width: 18,
                                  height: 18,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.amber.shade600,
                                      width: 1.5,
                                    ),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Colors.black26,
                                        blurRadius: 3,
                                        offset: Offset(0, 1),
                                      ),
                                    ],
                                  ),
                                  child: const Icon(
                                    Icons.lock,
                                    size: 11,
                                    color: Colors.amber,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    }),
                  );
                },
              ),
            ),

            if (hasNumbers && !_isRolling) ...[
              const SizedBox(height: 10),
              Text(
                '번호를 탭하면 고정됩니다 🔒',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
            ],

            const SizedBox(height: 20),

            // 조건 설정 버튼 (랜덤 모드만)
            if (!_photoMode)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: GestureDetector(
                  onTap: _openFilterSheet,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: condCount > 0
                          ? const Color(0xFFFBC400).withValues(alpha: 0.12)
                          : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: condCount > 0
                            ? const Color(0xFFFBC400)
                            : Colors.grey.shade300,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.tune,
                          size: 18,
                          color: condCount > 0
                              ? const Color(0xFFA0800A)
                              : Colors.grey.shade500,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '조건 설정',
                          style: TextStyle(
                            fontWeight: FontWeight.w500,
                            color: condCount > 0
                                ? const Color(0xFFA0800A)
                                : Colors.grey.shade700,
                          ),
                        ),
                        if (condCount > 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFBC400),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '$condCount개 적용중',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.black,
                              ),
                            ),
                          ),
                        ],
                        const Spacer(),
                        Icon(Icons.chevron_right, color: Colors.grey.shade400),
                      ],
                    ),
                  ),
                ),
              ),

            const SizedBox(height: 16),

            // 사진 모드: 사진 미리보기 + 안내
            if (_photoMode) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: _buildPhotoArea(context),
              ),
              const SizedBox(height: 16),
            ],

            // 생성 버튼 (랜덤 모드만)
            if (!_photoMode)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _isRolling ? null : _generate,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFBC400),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 4,
                    ),
                    child: _isRolling
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.black,
                            ),
                          )
                        : Text(
                            hasNumbers ? '다시 생성' : '번호 생성하기',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
              ),

            const SizedBox(height: 12),

            // 저장 / 초기화
            if (hasNumbers && !_isRolling)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _reset,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('초기화'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _saveToVault,
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('내 번호에 저장'),
                      ),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 32),

            // 이번 세션 생성 목록
            if (_generatedGames.isNotEmpty) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '이번에 저장한 번호',
                        style: Theme.of(
                          context,
                        ).textTheme.titleSmall?.copyWith(color: Colors.grey),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${_generatedGames.length}세트',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: List.generate(_generatedGames.length, (idx) {
                    final List<int> game =
                        _generatedGames[_generatedGames.length - 1 - idx];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 20,
                            child: Text(
                              '${_generatedGames.length - idx}',
                              style: const TextStyle(
                                color: Colors.grey,
                                fontSize: 12,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          const SizedBox(width: 8),
                          ...game.map(
                            (n) => Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: lottoBallColor(n),
                                  shape: BoxShape.circle,
                                ),
                                child: Center(
                                  child: Text(
                                    '$n',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: lottoBallTextColor(n),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────
// 특정수 제외/포함 토글 섹션 위젯
// ─────────────────────────────────────────
class _NumberFilterToggleSection extends StatelessWidget {
  const _NumberFilterToggleSection({
    required this.title,
    required this.isActive,
    required this.selectedNumbers,
    required this.conflictNumbers,
    required this.activeColor,
    required this.onToggle,
    required this.onNumberTap,
    required this.onApply,
    required this.onClear,
  });

  final String title;
  final bool isActive;
  final Set<int> selectedNumbers;
  final Set<int> conflictNumbers;
  final Color activeColor;
  final ValueChanged<bool> onToggle;
  final ValueChanged<int> onNumberTap;
  final VoidCallback onApply;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.black54,
              ),
            ),
            const SizedBox(width: 8),
            // 적용 중 배지
            if (selectedNumbers.isNotEmpty && !isActive)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: activeColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${selectedNumbers.length}개 적용중',
                  style: TextStyle(
                    fontSize: 11,
                    color: activeColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            const Spacer(),
            if (isActive && selectedNumbers.isNotEmpty)
              GestureDetector(
                onTap: onClear,
                child: Text(
                  '전체 해제',
                  style: TextStyle(fontSize: 12, color: Colors.red.shade400),
                ),
              ),
            const SizedBox(width: 10),
            Switch(
              value: isActive,
              activeThumbColor: activeColor,
              onChanged: onToggle,
            ),
          ],
        ),
        // 그리드 (토글 ON일 때만 표시)
        if (isActive) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: List.generate(45, (i) {
              final int n = i + 1;
              final bool selected = selectedNumbers.contains(n);
              final bool conflict = conflictNumbers.contains(n);
              return GestureDetector(
                onTap: conflict ? null : () => onNumberTap(n),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: selected
                        ? activeColor
                        : conflict
                        ? Colors.grey.shade300
                        : lottoBallColor(n).withValues(alpha: 0.85),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: selected
                        ? const Icon(Icons.check, size: 15, color: Colors.white)
                        : Text(
                            '$n',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: conflict
                                  ? Colors.grey.shade500
                                  : lottoBallTextColor(n),
                            ),
                          ),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 12),
          // 적용 버튼
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: selectedNumbers.isEmpty ? null : onApply,
              style: FilledButton.styleFrom(
                backgroundColor: activeColor,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(
                selectedNumbers.isEmpty
                    ? '번호를 선택하세요'
                    : '${selectedNumbers.length}개 적용',
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch(this.color, {this.size = 36});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.6),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.4),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
    );
  }
}

class _PhotoSeedResult {
  const _PhotoSeedResult({
    required this.seed,
    required this.colorA,
    required this.colorB,
    required this.colorC,
  });
  final int seed;
  final Color colorA;
  final Color colorB;
  final Color colorC;
}
