import { createHash, randomUUID } from 'node:crypto';
import { resolve } from 'node:path';
import { SafeError, withFileLock } from './auth-file';

/** VS Code SecretStorage의 필요한 부분만 표현한다. */
export interface Secrets {
  /** 암호화된 계정 저장소를 읽는다. */
  get(key: string): Thenable<string | undefined> | Promise<string | undefined>;
  /** 전체 저장소를 한 번에 기록한다. */
  store(key: string, value: string): Thenable<void> | Promise<void>;
}

/** 인증 원문을 암호화된 저장소에만 보관하는 계정이다. */
export interface Account { id: string; name: string; raw: string }

/** 인증 파일의 형식과 계정 식별을 에이전트에 위임하는 전략이다. */
export interface Agent {
  id: string;
  label: string;
  authPath: string;
  /** 에이전트가 파일 가져오기를 지원할 때만 해당 UI를 표시한다. */
  importFile?: boolean;
  /** 지원하는 호스트만 허용할 필요가 있을 때 판별한다. */
  supportsHost?(appName: string): boolean;
  /** 에이전트 고유 저장소의 현재 인증을 읽는다. */
  read(): Promise<string | undefined> | string | undefined;
  /** 예상 원문과 일치할 때 인증을 원자적으로 교체한다. */
  replace(raw: string, expected: string | undefined): Promise<void> | void;
  /** 원문을 검증하고 토큰 갱신에도 유지되는 계정 식별자를 반환한다. */
  identify(raw: string): string;
}

/** 표시 이름에 제어 문자와 VS Code 아이콘 구문이 들어가지 않게 한다. */
export function validName(name: string): boolean {
  return name.trim().length > 0 && name.trim().length <= 80 && !/[\x00-\x1f\x7f-\x9f]|\$\(/.test(name);
}

/** 인증 저장·보존·교체 순서를 공통으로 제공하며 에이전트 형식에는 관여하지 않는다. */
export class Accounts {
  private readonly key: string;
  private readonly identities = new Map<string, { raw: string; identity: string }>();

  /** 에이전트와 실제 인증 경로별로 SecretStorage를 분리한다. */
  constructor(private readonly secrets: Secrets, readonly agent: Agent) {
    const path = resolve(agent.authPath);
    this.key = `accounts-v1:${agent.id}:${createHash('sha256').update(process.platform === 'win32' ? path.toLowerCase() : path).digest('hex')}`;
  }

  /** 잘못된 저장소는 덮어쓰지 않고 복구 가능한 상태로 남긴다. */
  async list(): Promise<Account[]> {
    const raw = await this.secrets.get(this.key);
    if (raw === undefined) {
      this.identities.clear();
      return [];
    }
    try {
      const data: unknown = JSON.parse(raw);
      if (!Array.isArray(data)) throw new Error();
      const ids = new Set<string>();
      const identities = new Set<string>();
      for (const item of data) {
        if (!item || typeof item.id !== 'string' || typeof item.name !== 'string' ||
            typeof item.raw !== 'string' || !item.id || !validName(item.name) || ids.has(item.id)) throw new Error();
        const identity = this.identity(item);
        if (identities.has(identity)) throw new Error();
        ids.add(item.id);
        identities.add(identity);
      }
      for (const id of this.identities.keys()) {
        if (!ids.has(id)) this.identities.delete(id);
      }
      return data;
    } catch { throw new SafeError('invalidStore'); }
  }

  /** 계정 ID와 원문이 그대로면 검증 결과를 재사용하고 원문이 바뀌면 다시 식별한다. */
  identity(account: Account): string {
    const cached = this.identities.get(account.id);
    if (cached?.raw === account.raw) return cached.identity;
    const identity = this.agent.identify(account.raw);
    this.identities.set(account.id, { raw: account.raw, identity });
    return identity;
  }

  /** UI에는 인증 원문 없이 현재 계정의 식별 결과만 전달한다. */
  async current(): Promise<string | undefined> {
    const raw = await this.agent.read();
    return raw === undefined ? undefined : this.agent.identify(raw);
  }

  /** 등록·수정은 하나의 암호화된 값으로 저장해 메타데이터 불일치를 막는다. */
  private async save(accounts: Account[]): Promise<void> {
    await this.secrets.store(this.key, JSON.stringify(accounts));
  }

  /** 이미 등록한 계정은 갱신된 토큰으로 교체하고 중복 계정은 만들지 않는다. */
  private upsert(accounts: Account[], raw: string, name?: string): Account {
    const identity = this.agent.identify(raw);
    let account = accounts.find(item => this.identity(item) === identity);
    if (!account) {
      let defaultName = name;
      if (defaultName === undefined) {
        let number = accounts.length + 1;
        while (accounts.some(item => item.name === `Account ${number}`)) number++;
        defaultName = `Account ${number}`;
      }
      account = { id: randomUUID(), name: defaultName, raw };
      accounts.push(account);
    } else {
      account.raw = raw;
      if (name !== undefined) account.name = name;
    }
    this.identities.set(account.id, { raw, identity });
    return account;
  }

  /** 현재 로그인 또는 사용자가 고른 파일을 등록하며 실제 인증 파일은 변경하지 않는다. */
  async add(name: string, raw?: string): Promise<void> {
    if (!validName(name)) throw new SafeError('invalidName');
    await withFileLock(this.agent.authPath, async () => {
      const content = raw ?? await this.agent.read();
      if (content === undefined) throw new SafeError('missingAuth');
      const accounts = await this.list();
      this.upsert(accounts, content, name.trim());
      await this.save(accounts);
    });
  }

  /** 최신 로그인부터 암호화 보존하고 성공한 경우에만 대상 계정으로 전환한다. */
  async switchTo(id: string): Promise<void> {
    await withFileLock(this.agent.authPath, async () => {
      const accounts = await this.list();
      const target = accounts.find(item => item.id === id);
      if (!target) throw new SafeError('missingAccount');
      const live = await this.agent.read();
      // 이미 같은 인증이면 암호화 저장과 교체를 모두 생략한다.
      if (live === target.raw) return;
      // 외부에서 로그인한 미등록 계정도 자동 보존하여 원래 인증을 잃지 않게 한다.
      if (live !== undefined) this.upsert(accounts, live);
      await this.save(accounts);
      // 같은 계정의 갱신 토큰이면 upsert가 target.raw를 live로 바꾸므로 교체를 생략한다.
      if (live !== target.raw) await this.agent.replace(target.raw, live);
    });
  }

  /** 이름과 계정 삭제만 처리하고 활성 인증 파일은 그대로 둔다. */
  async manage(id: string, name?: string): Promise<void> {
    if (name !== undefined && !validName(name)) throw new SafeError('invalidName');
    await withFileLock(this.agent.authPath, async () => {
      const accounts = await this.list();
      const index = accounts.findIndex(item => item.id === id);
      if (index < 0) throw new SafeError('missingAccount');
      if (name === undefined) accounts.splice(index, 1);
      else {
        const trimmed = name.trim();
        if (accounts[index].name === trimmed) return;
        accounts[index].name = trimmed;
      }
      await this.save(accounts);
    });
  }
}
