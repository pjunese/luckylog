# 럭키로그 개발용 앱 실행

개발 앱은 `럭키로그 DEV`, 앱 식별자는 iOS와 Android 모두 `com.pjunese.lottonote.dev`입니다. 배포 앱은 `럭키로그` / `com.pjunese.lottonote`를 유지합니다. 두 앱의 기기 내 데이터는 분리되며 동시에 설치할 수 있습니다.

Firebase 프로젝트는 `lottonote-prod`를 공유합니다. 개발용에는 별도의 테스트 계정을 사용하세요. 같은 계정으로 로그인하면 서버의 구매내역·번호세트는 공유됩니다. 앱을 나눴다고 서버 데이터가 자동 분리되는 것은 아닙니다.

## 개발 실행

프로젝트 루트에서:

```sh
./tool/run_dev.sh  # 기본 대상: pjunese의 실제 iPhone 16 Pro
# 시뮬레이터 또는 다른 기기를 지정할 때
./tool/run_dev.sh -d <기기-ID>
# Flutter 디버거 연결 없이 실행할 실기기 개발 빌드
./tool/run_dev.sh --release -d <기기-ID>
```

기본 명령은 실기기 `00008140-000904901E7B001C`를 지정합니다. 실기기가 연결되지 않으면 시뮬레이터로 자동 전환하지 않습니다. 다른 기기는 `-d <기기-ID>` 또는 `LUCKYLOG_DEVICE_ID` 환경변수로 지정할 수 있습니다.

직접 Flutter를 사용하는 경우:

```sh
flutter run --flavor dev
flutter build ios --flavor dev --release
flutter build apk --flavor dev --debug
```

VS Code에서는 `럭키로그 DEV`, Xcode에서는 `ios/Runner.xcworkspace`의 `dev` 스킴을 선택합니다. Debug/Profile/Release-dev는 모두 개발용 식별자·아이콘·카카오 콜백을 사용합니다. 앱 아이콘 하단과 앱 화면에 DEV 표시가 있습니다.

iOS debug 빌드는 Flutter/Xcode에서 실행해야 합니다. 홈 화면에서 독립 실행하며 테스트하려면 개발용 release 빌드를 사용하세요. 개발자 서명으로 설치한 앱은 개발자 모드가 필요합니다.

## 배포 빌드

- iOS: 기존과 같이 Xcode의 **Runner** 스킴 → Archive → App Store Connect 업로드.
- Android: `flutter build appbundle --flavor prod --release`.
- 기존 버전 `1.1.0+14`는 이번 개발 환경 분리 작업에서 올리지 않았습니다. 다음 TestFlight 업로드 시 사용하지 않은 빌드 번호로 올려야 합니다.
- 개발 빌드를 만들었던 Generated.xcconfig가 남아도 Runner의 FLAVOR는 prod로, dev 스킴은 dev로 고정됩니다.
- 개발 앱 설치를 위해 배포 앱을 삭제할 필요가 없습니다.

## 연결한 서비스

- Firebase iOS DEV: `1:172162771888:ios:4dba0f22a90b06858f8475`
- Firebase Android DEV: `1:172162771888:android:d5f1f2ab138eba0b8f8475`
- iOS 개발 Firebase 설정: `ios/config/dev/GoogleService-Info.plist`
- Android 개발 Firebase 설정: `android/app/src/dev/google-services.json`
- 카카오: 기존 카카오 앱(ID 1423423)의 별도 네이티브 키 `luckylog_dev`. 배포 키와 콜백 스킴을 공유하지 않습니다.
- 카카오 Android 개발 서명 해시: `hxGnf07eLCXHGxFA2oW4DAOoqDc=`. 다른 Mac의 debug.keystore를 쓰면 해당 키 해시도 추가해야 합니다.
- 개발용 키를 교체할 경우 `python3 tool/configure_dev_kakao.py <새-네이티브-앱-키>`로 Dart/iOS/Android를 함께 갱신합니다. 어드민 키나 클라이언트 시크릿을 넣지 마세요.
- Apple 로그인 인증 함수는 기존 배포 식별자와 정확한 개발 식별자만 허용합니다. 2026-09-30 createAuthToken 함수만 선택 배포했습니다.

## 검증과 실기기 확인

2026-09-30: iOS 개발 빌드·개발 서명 빌드, Android 개발/배포 debug 빌드 성공. Flutter 정적 분석 성공. Flutter 테스트 184개는 전체 실행 중 2개 타임아웃 후 해당 파일 단독 재검증에서 통과했으며, 선택 테스트 1개는 건너뛰었습니다. 서버 테스트 11개 통과.

2026-10-04: 개발용 카카오 키와 Android 키 해시 연결 완료. 정적 분석, Android 개발 debug 빌드, iOS 시뮬레이터 빌드 성공. 시뮬레이터에서 DEV 표시·홈 화면·카카오 계정 로그인 페이지 진입·명당지도와 당첨 지점 표시를 확인했습니다. 실제 계정 자격증명은 입력하지 않았습니다.

Android signingReport에서 devDebug/devProfile/devRelease는 debug 서명, prodRelease는 기존 release 서명을 사용하는 것을 확인했습니다. Xcode Runner/Release의 실제 빌드 설정도 prod 환경·기존 번들 ID·카카오 키·AppIcon을 유지합니다. 로그인 시스템 안내에 쓰이는 CFBundleName도 럭키로그/럭키로그 DEV로 연결했습니다.

네이버 지도는 개발용 iOS 시뮬레이터에서 별도 콘솔 수정 없이 정상 표시되었습니다. Android·실기기에서 지도 인증 오류가 나면 기존 Naver Maps 애플리케이션에 개발 식별자를 추가 등록해야 하는지 확인하세요. 실제 콘솔 등록 목록은 이번에 변경하지 않았습니다.

실기기에서 남는 확인: 별도 테스트 계정의 카카오/Apple 로그인, 두 앱 동시 설치, 푸시 수신. 개발 iOS 서명에 Apple 로그인과 development APNs 권한이 포함되어 있는 것은 확인했습니다. 실제 푸시 수신은 Firebase의 개발 앱 APNs 연결과 테스트 기기에서 별도 확인해야 합니다.

최종 실기기용 개발 서명 빌드도 성공했고 `codesign --verify --deep --strict`를 통과했습니다. 결과물은 `build/dev/ios/Runner.app`에 보관했습니다. 번들 ID, 앱 이름, Firebase 앱 ID, 카카오 URL 스킴이 모두 개발용인 것을 결과물에서 확인했습니다. 실기기에는 아직 설치하지 않았습니다.

## 2026-10-06 Android·화면 호환성 점검

Android 출시용 AAB와 개발용 APK, iOS 개발용 시뮬레이터 빌드에 성공했습니다. Android 설정은 최소 API 24(7.0), 대상 API 36입니다. Pixel 7 / Android 16 에뮬레이터에는 `.dev` 앱을 별도로 설치·실행했습니다. iPhone 16e / iOS 26 시뮬레이터에서 로그인, 홈, 마이페이지 달력과 가로 방향 배치를 확인했습니다.

수정한 사항:

- Android 주변 판매점 검색에 필요한 `ACCESS_COARSE_LOCATION`, `ACCESS_FINE_LOCATION` 선언 누락 보완. 백그라운드 위치 권한은 추가하지 않았습니다.
- 작은 화면·큰 글씨에서 로그인 버튼, 홈 회차/추첨 안내, 번호 생성·저장 목록, 구매내역 헤더와 당첨회차 목록이 넘치던 배치 수정.
- 통계 정렬/연번 필터와 연속 번호 그리드가 화면 폭과 글씨 크기에 맞춰 배치되도록 수정.
- 달력 셀 높이의 글씨 크기 반영, 설정의 테마 버튼 배치, 키보드가 열린 의견 입력창 스크롤 보완.
- 번호 선택창은 제목과 번호 목록을 함께 스크롤하고 취소·적용 버튼은 고정. 번호 터치 영역 높이는 최소 48로 유지.
- 가로 화면의 노치 영역을 피하고 태블릿·폴더블 크기에서는 본문 최대 폭을 760으로 제한.
- 홈 당첨번호 공 크기를 화면 폭에 맞추고, 보너스 표시와 공이 서로 다른 줄에 떨어지지 않도록 수정.

`test/screens/responsive_layout_test.dart`는 실제 화면 위젯과 임시 SQLite 데이터를 사용합니다. 로그인·홈·번호 생성·번호세트·마이페이지·통계·구매 등록·번호 선택의 8개 화면을 아래 8개 조건에서 검사합니다. 팝업 열기/닫기, 생성/저장, 탭 변경, 스크롤, 연번 필터, 키보드 입력까지 포함합니다.

| 조건 | 논리 화면 크기 | 글씨 배율 |
| --- | --- | --- |
| 작은 iPhone | 320×568 | 1.0 |
| Android 휴대폰 | 360×800 | 1.0 |
| 노치 iPhone | 393×852 | 1.0 |
| 큰 Android 휴대폰 | 430×932 | 1.3 |
| 작은 화면·큰 글씨·다크 모드 | 320×568 | 2.0 |
| 가로 iPhone | 844×390 | 1.3 |
| 폴더블 크기 | 600×800 | 1.3 |
| 태블릿 크기 | 768×1024 | 1.3 |

검증 결과: 전체 Flutter 테스트 248개 통과, 이미지 미리보기 출력용 선택 테스트 1개는 기존 설정대로 제외. 마지막 홈 배치 수정 후 화면 64개 조합과 홈 구매 흐름을 다시 검사하여 66개 통과. 최종 정적 검사도 경고 없이 통과했습니다.

이 결과가 모든 기종·OS에서 실서비스 동작을 보장하지는 않습니다. 실제 로그인 완료, 카메라 QR 인식, 위치 허용/거부, 외부 지도 전환, 백그라운드 푸시 수신은 배포 후보로 추가 확인해야 합니다. iOS 시뮬레이터에서는 APNs 토큰이 없어 알림 재조정 중 `동기화 대기 중` 배너가 표시됐습니다. 이 경고는 화면 검사의 통과 여부와 별개이며 실제 기기 알림 확인이 남아 있습니다. Android 64비트 라이브러리의 LOAD 정렬은 16KB 이상임을 확인했지만 16KB 환경에서의 실행 검증은 수행하지 않았습니다.

새 화면 수정은 앱 업데이트가 필요합니다. 이번 점검에서는 버전 `1.1.0+14`를 유지했으며 스토어에 업로드하지 않았습니다. 이미 올린 TestFlight 빌드를 재사용하지 말고 다음 업로드 전에 빌드 번호를 올리세요.

관련 기준: [Flutter의 SafeArea·화면 크기 대응](https://docs.flutter.dev/ui/adaptive-responsive/safearea-mediaquery), [Android 16KB 호환성 확인](https://developer.android.com/guide/practices/page-sizes).


## 2026-10-09 무선 실기기 디버거 연결 문제

`./tool/run_dev.sh`는 기본적으로 debug 모드입니다. 앱 설치 후 `Dart VM Service was not discovered`, `mDNS query ... failed`로 종료될 수 있으며, 설치 아이콘이 있다고 디버거 연결까지 성공한 것은 아닙니다.

이번 확인에서는 iPhone 16 Pro의 개발자 모드와 CoreDevice 무선 연결이 정상이고, 사용자가 iPhone의 럭키로그 DEV 로컬 네트워크 권한도 켜져 있다고 확인했습니다. 실제 debug 앱에도 `_dartVmService._tcp`와 로컬 네트워크 설명이 포함되어 있어 설정 파일 누락은 아니었습니다. 실패한 이전 실행의 `--start-stopped` 디버거 대기 프로세스가 남아 있어 해당 프로세스만 종료했습니다. 정확한 무선 탐색 차단 지점은 확정하지 않았습니다.

실기기에서 기능을 확인하고 앱 아이콘으로 직접 실행할 때는 다음 명령을 사용합니다.

```sh
cd /Users/pjunese/Lotto/my_app
./tool/run_dev.sh --release --no-resident
```

`release`는 디버거를 연결하지 않는 실행 모드이고, `dev` 앱 식별자와 개발용 설정은 그대로입니다. TestFlight 업로드가 아니며 기존 배포 앱을 덮어쓰지 않습니다. `--no-resident`는 설치·실행 후 명령을 종료합니다. 이후에는 Mac 디버거 연결 없이 홈 화면에서 럭키로그 DEV를 열 수 있습니다. 개발자 모드는 계속 필요하며, 코드 변경 후에는 명령을 다시 실행해야 합니다.

코드를 수정하면서 hot reload가 필요하면 기존 `./tool/run_dev.sh`를 사용합니다. 이 경우 무선 디버거 탐색 문제를 별도로 해결해야 합니다. Mac에서 실행하는 터미널/Xcode의 로컬 네트워크 권한, 같은 네트워크에서의 기기 간 통신과 mDNS 차단 여부, 핫스팟 사용 여부가 확인 대상입니다. 앱 삭제 없이 먼저 연결 경로를 확인하세요.

개발용 release 빌드·무선 설치·실행 및 코드 서명 검증에 성공했습니다. 결과물의 식별자는 `com.pjunese.lottonote.dev`, 이름은 럭키로그 DEV이며 디버깅용 Bonjour 서비스가 포함되지 않았습니다. 버전은 1.1.0 (14)을 유지했습니다. `libobjc.A.dylib ... on-disk shared cache` 경고는 LLDB의 디버깅 성능 관련 경고로, 로그에서 실행을 중단한 직접적인 오류는 VM 서비스 탐색 실패였습니다.

참고: [Flutter 공식 iOS 디버깅 안내](https://docs.flutter.dev/platform-integration/ios/ios-debugging).
