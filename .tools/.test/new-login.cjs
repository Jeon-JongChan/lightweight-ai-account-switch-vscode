const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');

/** 실제 인증과 파일 잠금에 접근하지 않고 빌드된 모듈을 읽는다. */
function load(relative, replacements = {}) {
  const filename = path.resolve(__dirname, '../../', relative);
  const loaded = new Module(filename, module);
  loaded.filename = filename;
  loaded.paths = Module._nodeModulePaths(path.dirname(filename));
  const original = loaded.require.bind(loaded);
  loaded.require = id => Object.hasOwn(replacements, id) ? replacements[id] : original(id);
  loaded._compile(fs.readFileSync(filename, 'utf8'), filename);
  return loaded.exports;
}

/** 인증 파일 분리는 예상값 검증을 통과한 가짜 파일에만 적용되어야 한다. */
function checkClearAuth() {
  let content = 'first:latest';
  let removed = false;
  const stat = { isFile: () => true, nlink: 1, size: Buffer.byteLength(content), ino: 1, dev: 1, mtimeMs: 1 };
  const { clearAuth } = load('out/auth-file.js', { 'node:fs': {
    ...fs,
    lstatSync: () => stat,
    openSync: () => 1,
    fstatSync: () => stat,
    /** 가짜 파일 내용만 읽어 실제 인증에 접근하지 않는다. */
    readSync: (fd, buffer, offset, length, position) => {
      const part = Buffer.from(content).subarray(position, position + length);
      part.copy(buffer, offset);
      return part.length;
    },
    closeSync() {},
    unlinkSync: () => { removed = true; }
  } });
  assert.throws(() => clearAuth('fake-auth', 'first:old'), { code: 'changed' });
  assert.equal(removed, false);
  stat.nlink = 2;
  assert.throws(() => clearAuth('fake-auth', content), { code: 'unsafeFile' });
  assert.equal(removed, false);
  stat.nlink = 1;
  clearAuth('fake-auth', content);
  assert.equal(removed, true);
}

/** 기존 창에서 백업·분리하고 새 확장 호스트에서 로그인 뷰를 여는 연결을 확인한다. */
async function checkLoginUi() {
  const commands = new Map();
  const state = new Map();
  const steps = [];
  const selections = [];
  const errors = [];
  const agent = { id: 'codex', label: 'Codex', importFile: true };
  const accounts = {
    agent, list: async () => [], ownsSecret: () => false,
    /** UI는 새 창을 열기 전에 공통 백업·분리 흐름을 거쳐야 한다. */
    startLogin: async open => { steps.push('backup', 'clear'); await open(); }
  };
  const globalState = { get: key => state.get(key), update: async (key, value) => state.set(key, value) };
  const vscode = {
    env: { appName: 'Visual Studio Code' }, StatusBarAlignment: { Left: 1 }, QuickPickItemKind: { Separator: -1 },
    commands: {
      registerCommand: (key, action) => { commands.set(key, action); return { dispose() {} }; },
      /** 새 창은 이전 창 재사용 없이 열고 인계용 에이전트 ID만 전달한다. */
      executeCommand: async (key, options) => {
        if (key === 'vscode.newWindow') {
          assert.deepEqual(options, { reuseWindow: false });
          assert.equal(state.get('pendingLogin'), 'codex');
        }
        steps.push(key);
      }
    },
    extensions: { all: [{ packageJSON: { contributes: { views: { sidebar: [{ id: 'chatgpt.sidebar' }] } } } }] },
    workspace: { onDidChangeConfiguration: () => ({ dispose() {} }) },
    window: {
      createStatusBarItem: () => ({ show() {}, dispose() {} }),
      showQuickPick: async items => {
        assert.ok(items.some(item => item.action === 'import'), '파일·붙여넣기 가져오기는 유지해야 한다');
        return selections.shift();
      },
      showInformationMessage: async text => { steps.push(text); },
      showErrorMessage: text => errors.push(text)
    }
  };
  const extension = load('out/extension.js', {
    vscode, './accounts': { /** 실제 저장소 없이 UI 연결만 검사하는 계정 대역이다. */ Accounts: class {
      /** 실제 인증 대신 가짜 계정 흐름만 반환한다. */
      constructor() { return accounts; }
    } },
    './registry': { discoverAgents: () => [agent] },
    './messages': { message: key => key, errorMessage: key => key, setLanguageSection() {} }
  });
  const context = { extension: { packageJSON: { name: 'test' } }, subscriptions: [], globalState,
    secrets: { onDidChange: () => ({ dispose() {} }) } };
  await extension.activate(context);
  selections.push({ action: 'add' });
  await commands.get('test.pick')('codex');
  assert.deepEqual(steps, ['backup', 'clear', 'vscode.newWindow']);
  await extension.activate({ ...context, subscriptions: [] });
  assert.deepEqual(steps.slice(3), ['chatgpt.sidebar.focus', 'loginReady']);
  assert.equal(state.get('pendingLogin'), undefined);
  assert.deepEqual(errors, []);
}

/** 인증 파일 분리는 예상값 검증을 통과한 가짜 파일에만 적용되어야 한다. */
function checkClearAuth() {
  let content = 'first:latest';
  let removed = false;
  const stat = { isFile: () => true, nlink: 1, size: Buffer.byteLength(content), ino: 1, dev: 1, mtimeMs: 1 };
  const { clearAuth } = load('out/auth-file.js', { 'node:fs': {
    ...fs,
    lstatSync: () => stat,
    openSync: () => 1,
    fstatSync: () => stat,
    /** 가짜 파일 내용만 읽어 실제 인증에 접근하지 않는다. */
    readSync: (fd, buffer, offset, length, position) => {
      const part = Buffer.from(content).subarray(position, position + length);
      part.copy(buffer, offset);
      return part.length;
    },
    closeSync() {},
    unlinkSync: () => { removed = true; }
  } });
  assert.throws(() => clearAuth('fake-auth', 'first:old'), { code: 'changed' });
  assert.equal(removed, false);
  stat.nlink = 2;
  assert.throws(() => clearAuth('fake-auth', content), { code: 'unsafeFile' });
  assert.equal(removed, false);
  stat.nlink = 1;
  clearAuth('fake-auth', content);
  assert.equal(removed, true);
}

/** 기존 창에서 백업·분리하고 새 확장 호스트에서 로그인 뷰를 여는 연결을 확인한다. */
async function checkLoginUi() {
  const commands = new Map();
  const state = new Map();
  const steps = [];
  const selections = [];
  const errors = [];
  const agent = { id: 'codex', label: 'Codex', importFile: true };
  const accounts = {
    agent, list: async () => [], ownsSecret: () => false,
    /** UI는 새 창을 열기 전에 공통 백업·분리 흐름을 거쳐야 한다. */
    startLogin: async open => { steps.push('backup', 'clear'); await open(); }
  };
  const globalState = { get: key => state.get(key), update: async (key, value) => state.set(key, value) };
  const vscode = {
    env: { appName: 'Visual Studio Code' }, StatusBarAlignment: { Left: 1 }, QuickPickItemKind: { Separator: -1 },
    commands: {
      registerCommand: (key, action) => { commands.set(key, action); return { dispose() {} }; },
      /** 새 창은 이전 창 재사용 없이 열고 인계용 에이전트 ID만 전달한다. */
      executeCommand: async (key, options) => {
        if (key === 'vscode.newWindow') {
          assert.deepEqual(options, { reuseWindow: false });
          assert.equal(state.get('pendingLogin'), 'codex');
        }
        steps.push(key);
      }
    },
    extensions: { all: [{ packageJSON: { contributes: { views: { sidebar: [{ id: 'chatgpt.sidebar' }] } } } }] },
    workspace: { onDidChangeConfiguration: () => ({ dispose() {} }) },
    window: {
      createStatusBarItem: () => ({ show() {}, dispose() {} }),
      showQuickPick: async items => {
        assert.ok(items.some(item => item.action === 'import'), '파일·붙여넣기 가져오기는 유지해야 한다');
        return selections.shift();
      },
      showInformationMessage: async text => { steps.push(text); },
      showErrorMessage: text => errors.push(text)
    }
  };
  const extension = load('out/extension.js', {
    vscode, './accounts': { Accounts: class {
      /** 실제 인증 대신 가짜 계정 흐름만 반환한다. */
      constructor() { return accounts; }
    } },
    './registry': { discoverAgents: () => [agent] },
    './messages': { message: key => key, errorMessage: key => key, setLanguageSection() {} }
  });
  const context = { extension: { packageJSON: { name: 'test' } }, subscriptions: [], globalState,
    secrets: { onDidChange: () => ({ dispose() {} }) } };
  await extension.activate(context);
  selections.push({ action: 'add' });
  await commands.get('test.pick')('codex');
  assert.deepEqual(steps, ['backup', 'clear', 'vscode.newWindow']);
  await extension.activate({ ...context, subscriptions: [] });
  assert.deepEqual(steps.slice(3), ['chatgpt.sidebar.focus', 'loginReady']);
  assert.equal(state.get('pendingLogin'), undefined);
  assert.deepEqual(errors, []);
}

/** 새 로그인 준비의 보존 순서와 실패·충돌 시 인증 보호를 확인한다. */
async function main() {
  checkClearAuth();
  checkClearAuth();
  const { Accounts } = load('out/accounts.js', { './auth-file': {
    ...require('../../out/auth-file'), withFileLock: async (key, action) => action()
  } });
  let live = 'first:latest';
  let failSave = false;
  const values = new Map();
  const steps = [];
  const secrets = {
    get: async key => values.get(key),
    /** 암호화 저장 성공 전에는 인증이 지워지면 안 된다. */
    store: async (key, value) => {
      if (failSave) throw new Error('가짜 저장 실패');
      steps.push('save');
      values.set(key, value);
    }
  };
  const agent = {
    id: 'test', label: 'Test', authPath: path.join(__dirname, 'new-login', 'auth'),
    /** 토큰 갱신과 관계없이 같은 계정을 식별한다. */
    identify: raw => { if (!raw.includes(':')) throw new Error('가짜 잘못된 인증'); return raw.split(':')[0]; },
    read: async () => live,
    /** 외부 로그인 결과를 덮어쓰지 않고 로컬 인증만 교체한다. */
    replace: async (raw, expected) => { assert.equal(live, expected); live = raw; },
    /** 백업과 예상값 검증 후에만 로컬 인증을 비운다. */
    clear: async expected => { assert.equal(live, expected); steps.push('clear'); live = undefined; }
  };
  const accounts = new Accounts(secrets, agent);
  assert.equal(typeof accounts.startLogin, 'function', '새 로그인은 백업과 로컬 인증 분리를 공통으로 처리해야 한다');
  await accounts.add('첫 계정', 'first:old');
  steps.length = 0;
  await accounts.startLogin(async () => {
    steps.push('window');
    assert.equal(live, undefined);
    assert.equal((await accounts.list())[0].raw, 'first:latest');
  });
  assert.deepEqual(steps, ['save', 'clear', 'window']);
  assert.equal((await accounts.list())[0].name, '첫 계정');
  await accounts.switchTo((await accounts.list())[0].id);
  assert.equal(live, 'first:latest', '로그인 취소 후 저장 계정을 복원할 수 있어야 한다');
  failSave = true;
  steps.length = 0;
  await assert.rejects(accounts.startLogin(async () => steps.push('window')));
  assert.equal(live, 'first:latest');
  assert.deepEqual(steps, []);
  await assert.rejects(accounts.switchTo((await accounts.list())[0].id), '일반 전환도 암호화 저장 실패를 삼키면 안 된다');
  failSave = false;
  await assert.rejects(accounts.startLogin(async () => { throw new Error('가짜 창 열기 실패'); }));
  assert.equal(live, 'first:latest', '창 열기 실패 시 기존 인증을 복원해야 한다');
  await assert.rejects(accounts.startLogin(async () => { live = 'second:new'; throw new Error('가짜 창 열기 실패'); }));
  assert.equal(live, 'second:new', '복원은 외부에서 완료된 새 로그인을 덮어쓰면 안 된다');
  live = 'invalid';
  steps.length = 0;
  await assert.rejects(accounts.startLogin(async () => steps.push('window')));
  assert.equal(live, 'invalid');
  assert.deepEqual(steps, []);
  live = undefined;
  steps.length = 0;
  await accounts.startLogin(async () => steps.push('window'));
  assert.deepEqual(steps, ['window'], '이미 비어 있는 인증에는 삭제 요청이 없어야 한다');
  delete agent.clear;
  await assert.rejects(accounts.startLogin(async () => assert.fail('미지원 어댑터에서 창을 열면 안 된다')));
  await checkLoginUi();
  await checkLoginUi();
  console.log('새 로그인 백업·실패 복구·충돌 보호 검증 통과');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
