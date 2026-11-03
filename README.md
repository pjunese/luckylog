# 럭키로그 (LuckyLog)

로또 번호와 구매·당첨 기록을 관리하는 Flutter 앱입니다. Android와 iOS를 대상으로 개발하며, 이전 이름은 로또노트입니다.

## 주요 기능

- QR 연속 스캔·사진 인식과 수동 구매 등록
- 번호 생성, 번호세트 저장, 삭제 내역 복원
- 구매·당첨 기록 달력과 월별 요약
- 회차별 당첨 결과, 번호 통계, 명당지도와 외부 지도 연결
- 카카오·Apple 로그인, 계정별 데이터 동기화, 추첨 결과 알림
- 다크 모드와 화면 크기·글씨 크기에 따른 배치 조정

## 개발 환경

- Flutter / Dart: `pubspec.yaml`의 SDK 조건과 `pubspec.lock`을 기준으로 사용
- iOS: Xcode, CocoaPods, 개발자 서명 설정
- Android: Android SDK, JDK 17, 배포 시 별도 서명키
- 서버: Firebase Cloud Functions, Node.js 22

의존성 설치:

```sh
flutter pub get
```

서버 의존성은 `functions` 폴더에서 `npm ci`로 설치합니다. iOS 네이티브 의존성은 Flutter 빌드에서 설치되며, 필요하면 `ios` 폴더에서 `pod install`을 실행합니다.

## 개발용 앱 실행

실제 iPhone에서 앱 아이콘으로 직접 열어 테스트하는 방식:

```sh
./tool/run_dev.sh --release --no-resident
```

코드 수정 중 hot reload를 사용하는 방식:

```sh
./tool/run_dev.sh
```

위 스크립트는 기본적으로 개발자의 실제 iPhone을 대상으로 합니다. 다른 기기나 시뮬레이터는 기기 ID를 직접 지정합니다.

```sh
./tool/run_dev.sh -d <기기-ID>
```

| 구분 | 앱 이름 | iOS 번들 ID / Android 패키지명 |
| --- | --- | --- |
| 개발 | 럭키로그 DEV | `com.pjunese.lottonote.dev` |
| 배포 | 럭키로그 | `com.pjunese.lottonote` |

두 앱은 함께 설치할 수 있습니다. Firebase 서버는 공유하므로 개발용에는 별도 테스트 계정을 사용합니다. 같은 계정으로 로그인하면 서버 데이터도 공유됩니다.

자세한 서명·서비스 연결·무선 실행 절차는 [개발용 앱 안내](docs/development-builds.md)를 참고하세요.

## 검증

```sh
flutter analyze
flutter test
```

서버 단위 테스트는 `functions` 폴더에서 `npm test`로 실행합니다. `npm run test:emulator`는 별도의 Firebase 에뮬레이터 검증입니다.

## 배포

- iOS: `ios/Runner.xcworkspace`에서 **Runner** 스킴으로 Archive 후 App Store Connect에 업로드
- Android: `flutter build appbundle --flavor prod --release`
- 현재 소스 버전은 `pubspec.yaml`에 기록합니다. 기존 TestFlight 빌드 번호는 새 업로드에 재사용하지 않습니다.
- GitHub 업로드와 앱 스토어·Firebase 배포는 별개입니다. 이 저장소에 push하는 것만으로 배포되지는 않습니다.

## 저장소에 포함하지 않는 파일

빌드 결과물, 패키지 캐시, CocoaPods, 환경변수 파일, Android 서명키·`key.properties`, Apple 개인키·인증서·프로비저닝 프로파일, 서버 서비스 계정 인증 파일은 Git에서 제외합니다. 새 개발 환경에는 필요한 서명 및 서버 인증 정보를 별도로 준비해야 합니다.

Firebase 클라이언트 설정과 앱에 내장되는 SDK 식별자는 앱 구성에 포함되어 있습니다. 서버 관리자 인증정보와는 별도로 관리합니다. 서버의 `ADMIN_SECRET`은 Firebase Secret Manager에서 관리합니다.

## 작업 기록

- [개발·화면 호환성 점검](docs/development-builds.md)
- [추첨 결과 수집 및 지연 대응](docs/draw-collection.md)
- [계정 데이터 동기화와 보안](docs/security-sync-rollout.md)
- [구매 기록 달력](docs/purchase-calendar-20260922.md)
- [QR 일괄 등록](docs/qr-batch-and-summary.md)
- [럭키로그 브랜딩](docs/luckylog-branding-20260923.md)
- [TestFlight 배포 안내](docs/testflight-1.1.0.md)


## 공개 저장소의 인증정보 관리

- `.env`, 서명키, 서비스 계정 개인키, 서버 REST 키는 Git에 넣지 않습니다.
- 주변 판매점 검색은 App Check로 보호하는 `searchNearbyStores` 함수를 호출합니다. 카카오 REST 키는 Firebase Secret Manager의 `KAKAO_LOCAL_REST_KEY`에만 보관하며 앱이나 `--dart-define`에 넣지 않습니다.
- 별도 프로젝트에서 실행하려면 Firebase 앱 설정과 `functions/nearby_search.js`의 허용 앱 ID를 자신의 환경에 맞추고, App Check 제공자 및 서버 비밀값을 설정해야 합니다.
- 개발용 debug token도 비밀정보입니다. `.env` 예시나 Git 기록에 포함하지 않습니다.
- Firebase 클라이언트 설정은 서버 관리자 자격증명이 아닙니다. 데이터 권한은 Firebase Security Rules와 서버 인증 검증으로 제한합니다.
