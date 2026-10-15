# 럭키로그 1.1.0 (14) — TestFlight 배포 순서

## 준비된 설정

- `pubspec.yaml`: `version: 1.1.0+14`
- iOS 표시 버전: `1.1.0`, 빌드 번호: `14`
- 앱 표시 이름: 럭키로그
- 기존 Bundle ID 유지: `com.pjunese.lottonote`
- Xcode 생성 설정 갱신 완료. 새 배포 아카이브 생성 및 업로드는 아직 하지 않음.
- 기존 휴대폰 개발 앱과 이전 빌드 산출물은 1.0.4(13). 아래 Archive부터 새 1.1.0(14)가 생성됨.

## Xcode에서 배포

1. `/Users/pjunese/Lotto/my_app/ios/Runner.xcworkspace`를 엽니다. `.xcodeproj` 대신 `.xcworkspace`를 사용합니다.
2. 상단 Scheme은 `Runner`, 실행 대상은 `Any iOS Device (arm64)` 또는 현재 Xcode의 일반 iOS 기기 대상을 선택합니다. 시뮬레이터 대상은 사용하지 않습니다.
3. Runner 타깃의 Signing & Capabilities에서 기존 개발팀과 자동 서명을 확인합니다. Bundle Identifier는 유지합니다.
4. `Product → Archive`를 실행합니다.
5. Organizer에서 **새로 생성된 럭키로그 1.1.0 (14)** 아카이브를 선택합니다. 예전 1.0.4 아카이브를 선택하지 않습니다.
6. `Distribute App → App Store Connect → Upload` 경로로 진행합니다. Xcode 버전에 따라 App Store Connect 선택 후 바로 업로드 단계로 이어질 수 있습니다. 외부 테스터에게도 배포할 예정이면 `TestFlight Internal Only`를 선택하지 않습니다.
7. 서명/업로드 요약에서 앱 ID와 버전·빌드 번호를 확인한 뒤 Upload합니다. Xcode의 자동 빌드 번호 관리가 번호를 변경하는 경우 최종 업로드 번호를 확인합니다.
8. App Store Connect → 기존 앱 → TestFlight에서 Apple의 빌드 처리가 완료될 때까지 기다립니다. 새 앱을 만들지 않습니다.
9. 빌드에 수출 규정 정보가 필요하다고 표시되면 실제 암호화 사용 내용에 맞게 질문에 답변합니다. 아래 테스트 내용을 입력합니다.
10. 기존 내부 테스트 그룹에 빌드를 추가합니다. 외부 테스트 그룹은 필요한 TestFlight 베타 심사를 제출하고 승인 후 배포합니다.
11. iPhone의 **TestFlight 앱에서** 1.1.0 새 빌드를 설치/업데이트합니다. Xcode Run으로 설치하는 개발 앱과 구분합니다.

앱의 홈 화면 이름과 스토어 등록 이름은 별도입니다. App Store Connect의 앱 정보에 표시되는 이름도 `럭키로그`로 변경 가능한 상태인지 확인하고, 정식 출시 시 이름·설명·스크린샷을 맞춰주세요. TestFlight 업로드만으로 App Store 정식 출시가 이루어지지는 않습니다.

## TestFlight ‘테스트할 내용’ 복사용

럭키로그 1.1.0 업데이트

- 앱 이름 및 아이콘 변경
- 구매 캘린더와 월별 구매·당첨 기록
- 날짜별 구매 등록 및 구매일 수정
- 번호 세트와 구매내역 삭제·복원
- QR 등록, 다크모드 번호 표시 및 알림 설정 개선
- 사용하지 않는 해석보조 탭 정리

확인 부탁드립니다:
- 기존 구매내역과 번호 세트가 유지되는지
- 카카오·Apple 로그인이 정상 동작하는지
- 실제 복권 QR 등록과 중복 판별이 정상 동작하는지
- 캘린더에서 구매일 수정 후 월별 금액이 반영되는지
- 삭제 후 휴지통에서 정상 복원되는지
- 홈 화면 아이콘과 로딩 화면의 럭키로그 문구가 정상 표시되는지

## 이후 수정 빌드

같은 1.1.0을 다시 업로드할 때는 빌드 번호만 `1.1.0+15`, `1.1.0+16`처럼 올립니다. 다른 곳에서 이미 사용한 빌드 번호가 있다면 미사용 번호를 선택합니다. 버전 수정 후 Xcode Archive 전에 아래 명령으로 Flutter 설정을 갱신할 수 있습니다.

```sh
cd /Users/pjunese/Lotto/my_app
/Users/pjunese/flutter/bin/flutter build ios --config-only --release --no-pub
```

## 공식 안내

- Flutter iOS 배포: https://docs.flutter.dev/deployment/ios
- Apple 빌드 업로드: https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds
- Apple TestFlight: https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/
- 외부 테스터 초대: https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers
