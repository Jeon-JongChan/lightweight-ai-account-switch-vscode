import * as vscode from 'vscode';
import { Account, Accounts, validName } from './accounts';
import { readAuth, SafeError } from './auth-file';
import { discoverAgents } from './registry';
import { message as m, errorMessage, setLanguageSection } from './messages';

/** 등록된 에이전트마다 최소 상태 표시줄을 만들고 공통 명령에 연결한다. */
export async function activate(context: vscode.ExtensionContext): Promise<void> {
  const namespace = context.extension.packageJSON.name;
  const languageSection = context.extension.packageJSON.languageSection ?? 'accountSwitcherLite';
  setLanguageSection(languageSection);
  // 지원하지 않는 호스트의 에이전트는 항상 실패 상태가 되므로 처음부터 제외한다.
  const controllers = discoverAgents().filter(agent => agent.supportsHost?.(vscode.env.appName) ?? true).map(agent => {
    const accounts = new Accounts(context.secrets, agent);
    const bar = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 10);
    bar.name = `${agent.label} Account Switcher Lite`;
    bar.command = { command: `${namespace}.pick`, title: agent.label, arguments: [agent.id] };
    bar.tooltip = `${agent.label}: ${m('choose')}`;
    context.subscriptions.push(bar);
    if (agent.dispose) context.subscriptions.push({ dispose: () => agent.dispose!() });
    return { accounts, bar };
  });
  let busy = false;
  let refreshing: Promise<void> | undefined;
  const refreshAgain = new Set<string>();
  const changedSecrets = new Set<string>();

  /** 겹친 이벤트를 합치되 조회 중 발생한 변경은 마지막에 한 번 더 반영한다. */
  function refresh(id?: string): Promise<void> {
    for (const { accounts } of controllers) {
      if (id === undefined || accounts.agent.id === id) refreshAgain.add(accounts.agent.id);
    }
    if (!refreshing) {
      refreshing = (async () => {
        do {
          const ids = new Set(refreshAgain);
          refreshAgain.clear();
          await updateBars(ids);
        } while (refreshAgain.size);
      })().finally(() => { refreshing = undefined; });
    }
    return refreshing;
  }

  /** 토큰은 UI 항목에 넣지 않고 이름과 내부 ID만 사용한다. */
  async function updateBars(ids: Set<string>): Promise<void> {
    // 느린 OS 자격 증명 조회가 다른 에이전트의 표시를 막지 않게 한다.
    await Promise.all(controllers.filter(({ accounts }) => ids.has(accounts.agent.id)).map(async ({ accounts, bar }) => {
      try {
        const saved = await accounts.list();
        // 등록 전에는 인증 읽기와 OS 보조 프로세스 실행을 생략한다.
        const identity = saved.length ? await accounts.current() : undefined;
        const active = identity === undefined ? undefined : saved.find(item => accounts.identity(item) === identity);
        bar.text = `$(account) ${controllers.length > 1 ? accounts.agent.label + ': ' : ''}${active?.name ?? m(identity ? 'unknown' : 'none')}`;
        bar.tooltip = `${accounts.agent.label}: ${m('choose')}`;
      } catch (error) {
        bar.text = `$(account) ${controllers.length > 1 ? accounts.agent.label + ': ' : ''}${m('failed')}`;
        bar.tooltip = errorMessage(error instanceof SafeError ? error.code : 'error');
      }
      bar.show();
    }));
  }

  /** 사용자가 요청할 때만 활성 인증을 1회 읽어 기존 로그인 계정을 탐색하고 등록한다. */
  async function detect(accounts: Accounts): Promise<void> {
    const raw = await accounts.agent.read();
    if (raw === undefined) throw new SafeError('missingAuth');
    const identity = accounts.agent.identify(raw);
    const saved = await accounts.list();
    const existing = saved.find(item => accounts.identity(item) === identity);
    let defaultName = existing?.name;
    // 새 계정이면 Google 이메일 또는 다음 기본 번호를 부여한다.
    if (!defaultName) {
      try {
        const parsed = JSON.parse(identity);
        if (Array.isArray(parsed) && parsed[0] === 'google' && typeof parsed[1] === 'string' && validName(parsed[1])) {
          defaultName = parsed[1];
        }
      } catch { /* 기본 번호로 대체 */ }
    }
    if (!defaultName) {
      let number = saved.length + 1;
      while (saved.some(item => item.name === `Account ${number}`)) number++;
      defaultName = `Account ${number}`;
    }
    const name = await vscode.window.showInputBox({
      value: defaultName,
      prompt: m('name'),
      validateInput: value => validName(value) ? undefined : m('invalidName')
    });
    if (name === undefined) return;
    await accounts.add(name, raw);
    void vscode.window.showInformationMessage(m('registered'));
  }

  /** 기존 인증을 보존하고 서버 로그아웃 없이 새 로그인 창으로 연결한다. */
  async function add(accounts: Accounts): Promise<void> {
    await accounts.startLogin(async () => {
      await context.globalState.update('pendingLogin', accounts.agent.id);
      try {
        const opened = await vscode.commands.executeCommand('vscode.newWindow', { reuseWindow: false });
        if (opened === false) throw new SafeError('loginWindow');
      } catch (error) {
        await context.globalState.update('pendingLogin', undefined);
        throw error;
      }
    });
  }

  /** 현재 인증, 선택한 파일 또는 직접 붙여넣은 인증을 검증하여 등록한다. */
  async function importAccount(accounts: Accounts): Promise<void> {
    const choices = [{ label: m('current'), action: 'current' }];
    if (accounts.agent.importFile) choices.push({ label: m('file'), action: 'file' },
      { label: m('paste'), action: 'paste' });
    const choice = await vscode.window.showQuickPick(choices, { placeHolder: m('login') });
    if (!choice) return;
    let raw: string | undefined;
    if (choice.action === 'file') {
      const files = await vscode.window.showOpenDialog({ canSelectMany: false, filters: { JSON: ['json'] } });
      if (!files?.length) return;
      raw = readAuth(files[0].fsPath);
      if (raw === undefined) throw new SafeError('missingAuth');
      accounts.agent.identify(raw);
    } else if (choice.action === 'paste') {
      // 인증 원문은 암호 입력으로 받고 클립보드나 임시 파일에 따로 복사하지 않는다.
      raw = await vscode.window.showInputBox({ prompt: m('pastePrompt'), password: true, ignoreFocusOut: true,
        validateInput: value => {
          try { accounts.agent.identify(value); return undefined; }
          catch { return m('invalidAuth'); }
        } });
      if (raw === undefined) return;
      accounts.agent.identify(raw);
    }
    const name = await vscode.window.showInputBox({ prompt: m('name'),
      validateInput: value => validName(value) ? undefined : m('invalidName') });
    if (name === undefined) return;
    await accounts.add(name, raw);
    void vscode.window.showInformationMessage(m('registered'));
  }

  /** 저장소 삭제는 별도 확인을 받고 현재 로그인 파일은 건드리지 않는다. */
  async function manage(accounts: Accounts, saved: Account[]): Promise<void> {
    if (!saved.length) return;
    const selected = await vscode.window.showQuickPick(saved.map(item => ({ label: item.name, id: item.id })),
      { placeHolder: m('manage') });
    if (!selected) return;
    const action = await vscode.window.showQuickPick([
      { label: m('rename'), action: 'rename' }, { label: m('remove'), action: 'delete' }
    ]);
    if (action?.action === 'rename') {
      const name = await vscode.window.showInputBox({ value: selected.label, prompt: m('name'),
        validateInput: value => validName(value) ? undefined : m('invalidName') });
      if (name !== undefined) await accounts.manage(selected.id, name);
    } else if (action?.action === 'delete') {
      const confirmed = await vscode.window.showWarningMessage(m('confirm'), { modal: true }, m('delete'));
      if (confirmed === m('delete')) await accounts.manage(selected.id);
    }
  }

  /** 한 번에 하나의 대화 상자만 열어 오래된 선택으로 덮어쓰는 것을 방지한다. */
  async function pick(id?: string): Promise<void> {
    if (busy) { void vscode.window.showInformationMessage(m('busy')); return; }
    busy = true;
    let changed: string | undefined;
    try {
      let controller = controllers.find(item => item.accounts.agent.id === id);
      if (!controller && controllers.length === 1) controller = controllers[0];
      if (!controller) {
        const agent = await vscode.window.showQuickPick(controllers.map(item => ({
          label: item.accounts.agent.label, id: item.accounts.agent.id
        })), { placeHolder: m('agent') });
        controller = controllers.find(item => item.accounts.agent.id === agent?.id);
      }
      if (!controller) return;
      const { accounts } = controller;
      const saved = await accounts.list();
      // 등록 전에는 인증 읽기와 OS 보조 프로세스 실행을 생략한다.
      let identity: string | undefined;
      try { identity = saved.length ? await accounts.current() : undefined; }
      catch (error) {
        // 활성 인증 오류가 저장 계정 관리까지 막지 않도록 전환 시의 검증은 유지한다.
        void vscode.window.showErrorMessage(errorMessage(error instanceof SafeError ? error.code : 'error'));
      }
      const items: (vscode.QuickPickItem & { id?: string; action?: string })[] = saved.map(item => ({
        label: `${identity !== undefined && accounts.identity(item) === identity ? '✓ ' : '  '}${item.name}`, id: item.id
      }));
      if (saved.length) items.push({ label: '', kind: vscode.QuickPickItemKind.Separator });
      items.push(
        { label: `$(search) ${m('detect')}`, action: 'detect' },
        { label: `$(add) ${m('add')}`, action: 'add' },
        { label: m('manage'), action: 'manage' }
      );
      if (accounts.agent.importFile) items.push({ label: m('importAccount'), action: 'import' });
      const selected = await vscode.window.showQuickPick(items, { placeHolder: m('choose') });
      if (selected?.action || selected?.id) changed = accounts.agent.id;
      if (selected?.action === 'detect') await detect(accounts);
      else if (selected?.action === 'add') await add(accounts);
      else if (selected?.action === 'import') await importAccount(accounts);
      else if (selected?.action === 'manage') await manage(accounts, saved);
      else if (selected?.id) {
        await accounts.switchTo(selected.id);
        void vscode.window.showInformationMessage(m('switched'), m('reload')).then(reload => {
          if (reload) void vscode.commands.executeCommand('workbench.action.reloadWindow');
        });
      }
    } catch (error) {
      void vscode.window.showErrorMessage(errorMessage(error instanceof SafeError ? error.code : 'error'));
    } finally {
      busy = false;
      // 상태 표시 갱신은 실제 전환 완료 뒤의 작업이므로 다음 명령을 막지 않는다.
      if (changed !== undefined) changedSecrets.add(changed);
      for (const id of changedSecrets) void refresh(id);
      changedSecrets.clear();
    }
  }

  context.subscriptions.push(
    vscode.commands.registerCommand(`${namespace}.pick`, pick),
    vscode.commands.registerCommand(`${namespace}.reload`, () => vscode.commands.executeCommand('workbench.action.reloadWindow')),
    vscode.workspace.onDidChangeConfiguration(event => {
      if (event.affectsConfiguration(`${languageSection}.language`)) void refresh();
    }),
    context.secrets.onDidChange(event => {
      const controller = controllers.find(({ accounts }) => accounts.ownsSecret(event.key));
      if (!controller) return;
      const id = controller.accounts.agent.id;
      // 대화 상자 중 다른 창이 변경한 저장소도 종료 후 빠짐없이 반영한다.
      if (busy) changedSecrets.add(id);
      else void refresh(id);
    })
  );
  await refresh();
  // 새 창의 확장 호스트에서 공식 확장 뷰를 열어 이전 메모리 세션을 재사용하지 않는다.
  // shortcut: 인계는 다음에 시작되는 같은 프로필 창이 받으며, 동시 창 생성 지원 시 창 식별자를 추가한다.
  const pendingLogin = context.globalState.get<string>('pendingLogin');
  const loginController = controllers.find(({ accounts }) => accounts.agent.id === pendingLogin);
  if (loginController) {
    await context.globalState.update('pendingLogin', undefined);
    const viewName = pendingLogin === 'codex' ? /chatgpt|codex/i : new RegExp(pendingLogin!, 'i');
    try {
      const views = vscode.extensions.all.flatMap(extension =>
        Object.values(extension.packageJSON.contributes?.views ?? {}).flat() as { id: string }[]);
      const view = views.find(item => typeof item.id === 'string' && viewName.test(item.id));
      if (view) await vscode.commands.executeCommand(`${view.id}.focus`);
    } catch { /* 뷰 명령이 없으면 안내에 따라 공식 확장을 직접 연다. */ }
    void vscode.window.showInformationMessage(m('loginReady'));
  }
}
