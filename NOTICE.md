# 원본 고지

현재 프로젝트 작성자·배포자: lightweight. 아래 참고 프로젝트의 저작권·MIT 고지는 유지합니다.

## Codex Switch

- 원본: https://github.com/WoozyMasta/codex-switch
- 분석한 커밋: `05b243315afacfa451f33068e946f4fe266b998c`
- Copyright (c) 2026 Maxim Levchenko (WoozyMasta)
- MIT License 전문은 이 배포물의 `LICENSE` 첫 부분에 포함합니다.

Codex 홈 경로 해석, 계정 식별, 전환 전 활성 인증 보존 동작을 참고했습니다. 사용량·갱신 서비스·CLI·외부 통신 코드는 가져오지 않았으며 저장 계층·UI는 작은 별도 구현입니다. 원본의 저장소와 호환되거나 원본 프로필을 자동 가져온다고 주장하지 않습니다.

## Antigravity Account Switcher

- 참고 구현: https://github.com/BoyGR/antigravity-account-switcher
- 분석한 커밋: `bb8a965b7e8b7bb6c14e6c756ab23a64166fe899`
- Copyright (c) 2026 Boy Gilang Ramadhan (https://boygr.com)
- Project: Antigravity Account Switcher
- MIT License 전문은 이 배포물의 `LICENSE` 두 번째 부분에 포함합니다.

Windows의 `gemini:antigravity` 자격 증명 대상과 `token`·`id_token` 형식, Win32 자격 증명 API 연동을 참고했습니다. 다른 구현의 OAuth·할당량·백엔드 제어·SQLite 주입 코드는 포함하지 않습니다. Google 또는 OpenAI의 공식 계정 전환 확장이 아닙니다.

## 개발 시 확인한 문서

- VS Code SecretStorage: https://code.visualstudio.com/api/references/vscode-api#SecretStorage
- Codex 인증 저장: https://learn.chatgpt.com/docs/auth
- Google Antigravity IDE 확장 인증: https://antigravity.google/docs/ide/extensions/

빌드 도구는 사용자가 제공한 `.tools/.build/`를 사용하며 VSIX에 포함하지 않습니다.
