import * as fs from 'node:fs';
import { dirname, join } from 'node:path';
import { randomUUID } from 'node:crypto';

/** 토큰이나 경로를 오류 메시지에 포함하지 않는 안전한 오류다. */
export class SafeError extends Error {
  /** UI에서 번역할 오류 코드만 보관한다. */
  constructor(readonly code: string) { super(code); }
}

/** 일반 파일만 최대 1 MiB까지 읽고 심볼릭 링크와 하드 링크를 거부한다. */
export function readAuth(path: string): string | undefined {
  let stat: fs.Stats;
  try { stat = fs.lstatSync(path); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined;
    throw error;
  }
  if (!stat.isFile() || stat.nlink !== 1 || stat.size > 1024 * 1024) throw new SafeError('unsafeFile');
  let fd: number;
  try { fd = fs.openSync(path, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0)); }
  catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === 'ENOENT') throw new SafeError('changed');
    if (code === 'ELOOP') throw new SafeError('unsafeFile');
    throw error;
  }
  try {
    const opened = fs.fstatSync(fd);
    if (opened.ino !== stat.ino || opened.dev !== stat.dev) throw new SafeError('changed');
    if (!opened.isFile() || opened.nlink !== 1 || opened.size > 1024 * 1024) throw new SafeError('unsafeFile');
    // 실제 크기에 초과 감지용 1바이트만 더하며 읽은 바이트만 잘라 쓰므로 0 초기화를 생략한다.
    const buffer = Buffer.allocUnsafe(opened.size + 1);
    let count = 0;
    while (count < buffer.length) {
      const read = fs.readSync(fd, buffer, count, buffer.length - count, count);
      if (!read) break;
      count += read;
    }
    if (count > 1024 * 1024) throw new SafeError('unsafeFile');
    const after = fs.fstatSync(fd);
    if (count !== opened.size || after.size !== opened.size || after.mtimeMs !== opened.mtimeMs ||
        after.nlink !== 1) throw new SafeError('changed');
    return buffer.subarray(0, count).toString('utf8');
  } finally { fs.closeSync(fd); }
}

/** 같은 디렉터리의 0600 임시 파일을 fsync한 뒤 원본이 바뀌지 않았을 때만 rename한다. */
export function replaceAuth(path: string, raw: string, expected: string | undefined): void {
  const temporary = join(dirname(path), `.account-lite-${randomUUID()}.tmp`);
  const fd = fs.openSync(temporary, 'wx', 0o600);
  try {
    try {
      fs.writeFileSync(fd, raw, 'utf8');
      fs.fchmodSync(fd, 0o600);
      fs.fsyncSync(fd);
    } finally { fs.closeSync(fd); }
    // 닫기 실패도 아래 정리 경로로 보내 인증 원문이 임시 파일에 남지 않게 한다.
    if (readAuth(path) !== expected) throw new SafeError('changed');
    // 같은 프로세스의 이벤트가 검사와 교체 사이에 끼어들지 않게 동기로 수행한다.
    fs.renameSync(temporary, path);
  } catch (error) {
    try { fs.unlinkSync(temporary); } catch {}
    throw error;
  }
}

/** 여러 창의 변경 작업을 배타적으로 직렬화하고 타이머 없이 잠금을 해제한다. */
export async function withFileLock<T>(path: string, action: () => Promise<T>): Promise<T> {
  fs.mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const lock = join(dirname(path), '.account-lite.lock');
  let fd: number;
  try { fd = fs.openSync(lock, 'wx', 0o600); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'EEXIST') throw new SafeError('locked');
    throw error;
  }
  try { return await action(); }
  // 핸들 닫기가 실패해도 잠금 파일은 지워 이후 모든 창이 locked로 막히지 않게 한다.
  finally { try { fs.closeSync(fd); } finally { fs.unlinkSync(lock); } }
}
