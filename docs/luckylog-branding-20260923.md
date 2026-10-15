# 럭키로그 브랜드 적용 — 2026-09-23

사용자 승인: 보정한 로고를 앱 아이콘으로 적용하고 앱 이름을 럭키로그로 변경. 로딩 화면에는 새 심볼을 추가하지 않고 기존 랜덤 공 애니메이션을 유지하며 로또노트 문구만 럭키로그로 변경. 실기기 개발 빌드 설치.

변경:
- iOS CFBundleDisplayName 및 Android application label을 럭키로그로 변경.
- Flutter MaterialApp title, 로그인 제목, 결과 공유 카드의 브랜드 문구 변경.
- 공유 이미지 기본 파일 이름을 luckylog로 변경.
- 랜덤 공 로딩 화면은 문자열/주석 외 코드 변경 없음. 애니메이션 시간·레이아웃·부제 유지.
- assets/branding/luckylog_icon.png 및 luckylog_symbol.png는 사용자 승인된 보정본.
- flutter_launcher_icons 0.14.4로 iOS AppIcon 및 Android legacy/adaptive 아이콘 생성.
- Android foreground inset 12%, 흰 배경. 노란 포인트를 포함한 중요 영역의 원형 안전 범위 확인.
- 앱 ID com.pjunese.lottonote, Firebase, Kakao/Apple 로그인 설정 및 로컬 데이터 저장 방식 유지.

검증:
- Flutter analyze: No issues found.
- 기존 공유 카드·홈 구매 흐름·달력 화면 테스트 11개 통과.
- 임시 로딩 화면 검증/렌더링: 공 6개, 새 문구, 심볼 없음, 기존 완료 타이밍 확인.
- iOS 아이콘 슬롯 25개: 크기와 불투명 RGB 확인.
- iOS/Android 아이콘 형태 미리보기와 로딩 화면 시각 확인.
- git diff --check 통과. 백업/해시 기반 47개 변경 파일 적용.
- iPhone 기존 1.0.4(9) 확인 및 Documents 백업 완료.

빌드/설치 결과는 작업 폴더의 ios-build.log, android-build.log, install.json, device-after.json 및 launch.json을 참조. 새 버전은 개발용 1.0.4(10). 스토어 배포는 하지 않음.
