# AI Account Switcher Lite 1.0.0 릴리즈 보고서

- **작성 일시**: 2026-10-30
- **상태**: 1.0.0 버전 빌드 및 VSIX 패키징 완료

---

## 1. 개요

- 사용자의 요청에 따라 프로젝트 버전을 `0.1.1`에서 **`1.0.0`**으로 판올림하고 전체 빌드 및 VSIX 패키징을 수행함.

---

## 2. 작업 내역

1. **버전 변경**:
   - `package.json`: `0.1.1` -> `1.0.0`
   - `package-lock.json`: `0.1.1` -> `1.0.0`
   - `README.md`: 설치 파일명 및 안내 `ai-account-switcher-lite-1.0.0.vsix`로 반영
   - `.tools/.build/dependencies.sha256`: `package-lock.json` 변경에 따른 해시 동기화
2. **빌드 및 패키징 검증**:
   - `.\build.ps1 build`: TypeScript 컴파일 성공 (종료 코드 0)
   - `.\build.ps1 package`: `dist/ai-account-switcher-lite-1.0.0.vsix` 패키징 완료 (종료 코드 0, 파일 크기 61.24 KB)

---

## 3. 산출물 안내

- 산출물 경로: [`dist/ai-account-switcher-lite-1.0.0.vsix`](file:///c:/Users/user/Documents/projects/lightweight-ai-account-switch-vscode/dist/ai-account-switcher-lite-1.0.0.vsix)
- 설치 방법: VS Code 명령 팔레트(`Ctrl+Shift+P`) → `Extensions: Install from VSIX...` 선택 후 해당 파일 설치
