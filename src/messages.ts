import * as vscode from 'vscode';

let languageSection = 'accountSwitcherLite';

/** 각 VSIX의 고유 설정 이름을 사용해 동시 설치 충돌을 막는다. */
export function setLanguageSection(section: string): void { languageSection = section; }

const en = {
  choose: 'Choose an account', none: 'No account', unknown: 'Unregistered',
  detect: 'Detect Logged-in Account',
  add: 'Add Account', manage: 'Manage Accounts', current: 'Register Current Account',
  importAccount: 'Import Account (file / paste)',
  loginReady: 'The previous account was saved without signing out. Open the agent’s login screen and sign in to another account, then use Detect Logged-in Account to save it. Do not sign out in the old window. If you cancel, select a saved account to restore it.',
  loginUnsupported: 'This adapter cannot prepare a new login without signing out. Existing authentication was kept.',
  loginWindow: 'Could not open a new login window. Select a saved account if you need to restore authentication.',
  file: 'Import auth.json', login: 'Sign in with the agent’s own UI, then register the current account.',
  paste: 'Paste auth.json', pastePrompt: 'Paste the complete contents of auth.json.',
  name: 'Account name', invalidName: 'Enter 1–80 characters without control characters or icon markup.',
  rename: 'Rename Account', remove: 'Delete Account', confirm: 'Delete the saved account? The active authentication file will be kept.',
  delete: 'Delete', switched: 'Account switched. Reload the window if the agent still uses the previous account.',
  reload: 'Reload Window', error: 'The operation failed. Check file access and SecretStorage availability. Select a saved account to restore authentication if needed.',
  invalidAuth: 'Unsupported or invalid authentication. The existing credentials were kept.',
  invalidStore: 'The encrypted account store is invalid. It was not overwritten.',
  missingAuth: 'No supported authentication found. Sign in using the agent’s own UI first.',
  unsafeFile: 'Authentication must be a regular file up to 1 MiB, without symbolic or hard links.',
  changed: 'Authentication changed during the operation. Retry after the agent finishes signing in.',
  locked: 'Another window is changing accounts. If all windows were interrupted, close them and inspect .account-lite.lock in the authentication folder.',
  missingAccount: 'The saved account no longer exists.', busy: 'An account operation is already open.',
  agent: 'Choose an agent', registered: 'Account saved.',
  failed: 'Check authentication',
  unsupported: 'This agent requires Windows and the official Antigravity extension in VS Code. Antigravity standalone IDE is not supported.',
  credential: 'Cannot access the Antigravity Windows credential. Existing credentials were kept if the replacement did not succeed.',
};

const ko: typeof en = {
  choose: '계정을 선택하세요', none: '계정 없음', unknown: '미등록 계정',
  detect: '로그인된 계정 탐색 및 등록',
  add: '계정 추가', manage: '계정 관리', current: '현재 계정 등록',
  importAccount: '계정 가져오기 (파일 / 붙여넣기)',
  loginReady: '기존 계정을 로그아웃 없이 저장했습니다. 에이전트 로그인 화면에서 다른 계정으로 로그인한 뒤 로그인된 계정 탐색 및 등록을 선택하세요. 이전 창에서 로그아웃하지 마세요. 취소하려면 저장한 계정을 선택해 복원하세요.',
  loginUnsupported: '이 어댑터는 로그아웃 없는 새 로그인 준비를 지원하지 않습니다. 기존 인증은 유지했습니다.',
  loginWindow: '새 로그인 창을 열지 못했습니다. 인증 복원이 필요하면 저장한 계정을 선택하세요.',
  file: 'auth.json 가져오기', login: '에이전트의 기본 UI에서 로그인한 뒤 현재 계정을 등록하세요.',
  paste: 'auth.json 붙여넣기', pastePrompt: 'auth.json의 전체 내용을 붙여넣으세요.',
  name: '계정 이름', invalidName: '제어 문자와 아이콘 구문 없이 1~80자로 입력하세요.',
  rename: '계정 이름 변경', remove: '계정 삭제', confirm: '저장한 계정을 삭제할까요? 현재 인증 파일은 유지합니다.',
  delete: '삭제', switched: '계정을 전환했습니다. 에이전트가 이전 계정을 사용하면 창을 다시 로드하세요.',
  reload: '창 다시 로드', error: '작업에 실패했습니다. 파일 접근 권한과 SecretStorage 사용 가능 여부를 확인하세요. 인증 복원이 필요하면 저장한 계정을 선택하세요.',
  invalidAuth: '지원하지 않거나 올바르지 않은 인증 형식입니다. 기존 인증을 유지했습니다.',
  invalidStore: '암호화된 계정 저장소가 올바르지 않습니다. 덮어쓰지 않았습니다.',
  missingAuth: '지원하는 인증 정보가 없습니다. 에이전트의 기본 UI에서 먼저 로그인하세요.',
  unsafeFile: '인증은 심볼릭 링크·하드 링크가 아닌 1 MiB 이하 일반 파일이어야 합니다.',
  changed: '작업 중 인증 파일이 바뀌었습니다. 에이전트 로그인이 끝난 뒤 다시 시도하세요.',
  locked: '다른 창에서 계정을 변경 중입니다. 모든 창이 비정상 종료됐다면 창을 닫고 인증 폴더의 .account-lite.lock을 확인하세요.',
  missingAccount: '저장한 계정이 더 이상 없습니다.', busy: '이미 계정 작업이 열려 있습니다.',
  agent: '에이전트를 선택하세요', registered: '계정을 저장했습니다.',
  failed: '인증 확인 필요',
  unsupported: '이 에이전트는 Windows의 공식 Antigravity VS Code 확장용입니다. Antigravity 독립 IDE는 지원하지 않습니다.',
  credential: 'Antigravity Windows 자격 증명에 접근하지 못했습니다. 교체가 성공하지 않았다면 기존 자격 증명을 유지합니다.',
};

/** 언어 설정을 매번 읽어 재시작 없이 한국어와 영어를 적용한다. */
export function message(key: keyof typeof en): string {
  const preference = vscode.workspace.getConfiguration(languageSection).get<string>('language', 'auto');
  const language = preference === 'auto' ? vscode.env.language : preference;
  return (language.startsWith('ko') ? ko : en)[key];
}

/** 임의 오류 원문은 표시하지 않아 토큰·개인 경로 노출을 방지한다. */
export function errorMessage(code: string): string {
  return Object.hasOwn(en, code) ? message(code as keyof typeof en) : message('error');
}
