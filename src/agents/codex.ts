import { createHash } from 'node:crypto';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import type { Agent } from '../accounts';
import { readAuth, replaceAuth, SafeError } from '../auth-file';

/** 인증 JSON 전체를 유지하며 API 키 또는 사용자·워크스페이스 조합으로 식별한다. */
export function parseAuth(raw: string): string {
  try {
    if (Buffer.byteLength(raw) > 1024 * 1024) throw new Error();
    // Windows 편집기의 UTF-8 BOM만 파싱에서 제외하고 저장 원문은 유지한다.
    const data = JSON.parse(raw.replace(/^\uFEFF/, ''));
    if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error();
    const apiKey = typeof data.OPENAI_API_KEY === 'string' ? data.OPENAI_API_KEY.trim() : '';
    if (apiKey) {
      return `key:${createHash('sha256').update(apiKey).digest('hex')}`;
    }
    const tokens = data.tokens;
    if (!tokens || !['id_token', 'access_token', 'refresh_token'].every(
      key => typeof tokens[key] === 'string' && tokens[key].trim())) throw new Error();
    const parts = tokens.id_token.split('.');
    if (parts.length !== 3 || parts.some((part: string) => !part.trim())) throw new Error();
    const claims = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
    const rawAccount = typeof tokens.account_id === 'string' && tokens.account_id.trim()
      ? tokens.account_id
      : claims?.['https://api.openai.com/auth']?.chatgpt_account_id;
    const sub = typeof claims?.sub === 'string' ? claims.sub.trim() : '';
    const account = typeof rawAccount === 'string' ? rawAccount.trim() : '';
    if (!sub || !account) throw new Error();
    // JWT는 로컬 계정 비교에만 쓰며 서명 검증이나 로그인 성공으로 간주하지 않는다.
    return JSON.stringify([sub, account]);
  } catch { throw new SafeError('invalidAuth'); }
}

/** Codex의 파일 기반 인증만 지원하며 CLI나 네트워크를 호출하지 않는다. */
const authPath = join(resolve(process.env.CODEX_HOME || join(homedir(), '.codex')), 'auth.json');
const agent: Agent = {
  id: 'codex', label: 'Codex',
  importFile: true,
  authPath,
  identify: parseAuth,
  /** 보호 검사와 함께 현재 인증 파일을 읽는다. */
  read: () => readAuth(authPath),
  /** 같은 디렉터리의 rename으로 교체한다. */
  replace: (raw, expected) => replaceAuth(authPath, raw, expected)
};
export default agent;
