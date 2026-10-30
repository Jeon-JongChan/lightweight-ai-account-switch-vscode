const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const { EventEmitter } = require('node:events');
const { PassThrough, Writable } = require('node:stream');
const { spawn } = require('node:child_process');

/** 다른 모듈에 영향을 주지 않고 이 검증에만 필요한 의존성을 교체한다. */
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

/** 실제 토큰 대신 형식 검증에만 사용하는 가짜 자격 증명을 만든다. */
function fixture() {
  return JSON.stringify({ userName: 'test',
    blobBase64: Buffer.from(JSON.stringify({ id_token_email: 'test@example.invalid',
      token: { refresh_token: 'test-only' } })).toString('base64'), persist: 2 });
}

/** 현재 비동기 갱신이 다음 이벤트 루프까지 진행하도록 한다. */
function tick() {
  return new Promise(resolve => setImmediate(resolve));
}

/** 가짜 프로세스로 직렬화, 응답 분할, 실패 복구와 종료 처리를 확인한다. */
async function checkWorker() {
  const children = [];
  let mode = 'read';
  let writes = 0;
  const adapter = load('out/agents/antigravity.js', { 'node:child_process': {
    /** 표준입출력만 흉내 내고 OS 자격 증명에는 접근하지 않는다. */
    spawn() {
      const child = new EventEmitter();
      child.stdout = new PassThrough();
      child.stderr = new PassThrough();
      child.kill = () => { child.killed = true; return true; };
      child.stdin = new Writable({
        /** 요청당 응답 또는 통신 실패를 다음 이벤트 루프에서 발생시킨다. */
        write(chunk, encoding, done) {
          writes++;
          const action = JSON.parse(chunk.toString()).action;
          const currentMode = mode;
          setImmediate(() => {
            if (currentMode === 'exit') child.emit('exit', 1);
            else if (currentMode === 'hang') return;
            else {
              const output = currentMode === 'malformed' ? 'invalid\n'
                : currentMode === 'oversized' ? 'x'.repeat(1024 * 1024 + 1)
                : JSON.stringify(action === 'clear' && currentMode === 'clearSuccess' ? { ok: true }
                  : action === 'write' || action === 'clear' ? { error: 'changed' } : { value: JSON.parse(fixture()) }) + '\r\n';
              child.stdout.write(output.slice(0, 7));
              child.stdout.write(output.slice(7));
            }
          });
          done();
        }
      });
      children.push(child);
      return child;
    }
  } }).default;
  try {
    assert.deepEqual(await Promise.all([adapter.read(), adapter.read(), adapter.read()]), Array(3).fill(fixture()));
    assert.equal(children.length, 1, '연속·동시 조회는 같은 프로세스를 재사용해야 한다');
    await assert.rejects(adapter.replace(fixture(), fixture()), { code: 'changed' });
    await assert.rejects(adapter.clear(fixture()), { code: 'changed' });
    await adapter.read();
    assert.equal(children.length, 1, '인증 충돌은 프로세스를 종료하면 안 된다');
    mode = 'clearSuccess';
    assert.equal(await adapter.clear(fixture()), undefined, '로컬 분리는 명시적 성공 응답을 확인해야 한다');
    assert.equal(children.length, 1);
    mode = 'read';
    for (const failure of ['exit', 'malformed', 'oversized']) {
      mode = failure;
      const before = writes;
      await assert.rejects(adapter.read(), { code: 'credential' });
      assert.equal(writes, before + 1, '실패 요청은 자동 재실행하면 안 된다');
      assert.equal(children.at(-1).killed, true);
      mode = 'read';
      assert.equal(await adapter.read(), fixture(), '다음 요청은 새 프로세스로 복구해야 한다');
    }
    mode = 'hang';
    const beforeTimeout = writes;
    await assert.rejects(adapter.replace(fixture(), fixture()), { code: 'credential' });
    assert.equal(writes, beforeTimeout + 1, '시간 초과 쓰기는 자동 재실행하면 안 된다');
    assert.equal(children.at(-1).killed, true, '시간 초과 프로세스는 종료해야 한다');
    mode = 'read';
    await adapter.read();
    mode = 'hang';
    const count = children.length;
    const pending = [adapter.read(), adapter.read()];
    const rejected = pending.map(result => assert.rejects(result, { code: 'credential' }));
    await tick();
    adapter.dispose();
    await Promise.all(rejected);
    assert.equal(children.length, count, '종료 후 대기 요청이 프로세스를 다시 시작하면 안 된다');
  } finally { adapter.dispose(); }
}

/** 실제 PowerShell은 테스트 전용 대상만 조회하여 반복 요청과 충돌 검사를 확인한다. */
async function checkPowerShell() {
  let starts = 0;
  const durations = [];
  const target = 'AccountSwitcherLite-Test-' + require('node:crypto').randomUUID();
  const adapter = load('out/agents/antigravity.js', { 'node:child_process': {
    /** 메모리 안에서 대상 이름만 교체하여 실제 로그인에 접근하지 않는다. */
    spawn(executable, args, options) {
      starts++;
      const copied = [...args];
      const script = Buffer.from(copied.at(-1), 'base64').toString('utf16le');
      copied[copied.length - 1] = Buffer.from(script.replaceAll('gemini:antigravity', target), 'utf16le').toString('base64');
      return spawn(executable, copied, options);
    }
  } }).default;
  try {
    for (let index = 0; index < 3; index++) {
      const start = performance.now();
      assert.equal(await adapter.read(), undefined);
      durations.push(Math.round(performance.now() - start));
    }
    // 실제 대상은 비어 있으므로 expected 불일치 검사에서 쓰기 전에 중단된다.
    await assert.rejects(adapter.replace(fixture(), fixture()), { code: 'changed' });
    await assert.rejects(adapter.clear(fixture()), { code: 'changed' });
    assert.equal(await adapter.read(), undefined);
    assert.equal(starts, 1);
    console.log('PowerShell 최초·재사용 조회(ms): ' + durations.join(', '));
  } finally { adapter.dispose(); }
}

/** 실제 Accounts와 가짜 VS Code로 에이전트별 갱신 및 메뉴 취소를 확인한다. */
async function checkRefresh() {
  const commands = new Map();
  const values = new Map();
  const reads = { codex: 0, antigravity: 0 };
  const secretListeners = [];
  const selections = [];
  let release;
  let holdNext = false;
  const agents = Object.keys(reads).map(id => ({ id, label: id,
    authPath: path.join(__dirname, id, 'auth'), identify: raw => raw,
    /** 읽기 횟수를 세고 후속 상태 조회를 선택적으로 지연시킨다. */
    read: async () => {
      reads[id]++;
      if (id === 'codex' && holdNext) {
        holdNext = false;
        await new Promise(resolve => { release = resolve; });
      }
      return id;
    }, replace: () => {} }));
  const secrets = {
    get: async key => values.get(key),
    /** 실제 VS Code처럼 저장소 변경 이벤트를 전달한다. */
    store: async (key, value) => {
      values.set(key, value);
      for (const listener of secretListeners) listener({ key });
    },
    onDidChange: listener => { secretListeners.push(listener); return { dispose() {} }; }
  };
  const accountsModule = load('out/accounts.js', { './auth-file': {
    ...require('../../out/auth-file'), withFileLock: async (key, action) => action()
  } });
  let codexAccountId;
  for (const agent of agents) {
    const accounts = new accountsModule.Accounts(secrets, agent);
    await accounts.add(agent.id, agent.id);
    if (agent.id === 'codex') codexAccountId = (await accounts.list())[0].id;
  }
  const errors = [];
  const vscode = {
    env: { appName: 'Visual Studio Code' }, StatusBarAlignment: { Left: 1 }, QuickPickItemKind: { Separator: -1 },
    commands: { registerCommand: (name, command) => { commands.set(name, command); return { dispose() {} }; } },
    workspace: { onDidChangeConfiguration: () => ({ dispose() {} }) },
    window: {
      createStatusBarItem: () => ({ show() {}, dispose() {} }),
      showQuickPick: async () => selections.shift(),
      showInformationMessage: async () => undefined,
      showErrorMessage: text => errors.push(text)
    }
  };
  const extension = load('out/extension.js', { vscode, './accounts': accountsModule,
    './registry': { discoverAgents: () => agents }, './messages': {
      message: key => key, errorMessage: key => key, setLanguageSection() {}
    } });
  await extension.activate({ extension: { packageJSON: { name: 'test' } }, subscriptions: [], secrets,
    globalState: { get: () => undefined } });
  reads.codex = reads.antigravity = 0;
  selections.push({ id: codexAccountId });
  await commands.get('test.pick')('codex');
  await tick();
  assert.equal(reads.antigravity, 0, 'Codex 전환은 Antigravity를 조회하면 안 된다');
  assert.equal(reads.codex, 3, '메뉴·전환 검증·후속 갱신은 선택한 에이전트만 조회한다');
  reads.codex = 0;
  await commands.get('test.pick')('codex');
  await tick();
  assert.equal(reads.codex, 1, '메뉴 취소 뒤 상태 재조회는 없어야 한다');
  secretListeners[0]({ key: 'unrelated-secret' });
  await tick();
  assert.equal(reads.codex, 1, '무관한 SecretStorage 변경은 조회하면 안 된다');
  // 전환은 그대로 두고 후속 조회만 대기시켜 busy 해제를 검사한다.
  const originalRead = agents[0].read;
  let calls = 0;
  agents[0].read = async () => { if (++calls === 3) holdNext = true; return originalRead(); };
  selections.push({ id: codexAccountId });
  await commands.get('test.pick')('codex');
  await tick();
  assert.equal(typeof release, 'function');
  await commands.get('test.pick')('codex');
  release();
  await tick();
  assert.equal(calls, 4, '상태 조회 중에도 다음 메뉴를 열 수 있어야 한다');
  assert.deepEqual(errors, []);
}

/** 빌드된 제품 코드의 핵심 회귀 검증을 순서대로 실행한다. */
async function main() {
  await checkWorker();
  await checkPowerShell();
  await checkRefresh();
  console.log('계정 전환 성능·안전성 검증 통과');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
