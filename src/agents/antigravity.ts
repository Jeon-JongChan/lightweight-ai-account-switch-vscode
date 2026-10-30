import { spawn, ChildProcessWithoutNullStreams } from 'node:child_process';
import { join } from 'node:path';
import { homedir } from 'node:os';
import type { Agent } from '../accounts';
import { SafeError } from '../auth-file';

/** Windows 자격 증명 하나의 손실 없는 스냅샷이다. */
interface Credential { userName: string; blobBase64: string; persist: number }

/** 원문은 유지하고 Google 계정 이메일 또는 ID 토큰으로 계정을 구분한다. */
export function identifyCredential(raw: string): string {
  try {
    if (Buffer.byteLength(raw) > 1024 * 1024) throw new Error();
    const record: Credential = JSON.parse(raw.replace(/^\uFEFF/, ''));
    if (!record || typeof record.userName !== 'string' || record.userName.includes('\0') ||
        ![1, 2, 3].includes(record.persist) || typeof record.blobBase64 !== 'string') throw new Error();
    const bytes = Buffer.from(record.blobBase64, 'base64');
    if (!bytes.length || bytes.length > 2560 || bytes.toString('base64') !== record.blobBase64) throw new Error();
    const data = JSON.parse(bytes.toString('utf8'));
    if (!data?.token || typeof data.token.refresh_token !== 'string' || !data.token.refresh_token.trim()) throw new Error();
    // Antigravity는 이메일(id_token_email) 또는 JWT id_token을 사용한다.
    if (typeof data.id_token_email === 'string' && data.id_token_email.trim()) {
      return JSON.stringify(['google', data.id_token_email.trim().toLowerCase()]);
    }
    if (typeof data.id_token === 'string') {
      const parts = data.id_token.split('.');
      if (parts.length === 3 && parts.every((part: string) => part.trim())) {
        const claims = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
        const sub = typeof claims?.sub === 'string' ? claims.sub.trim() : '';
        if (sub && ['https://accounts.google.com', 'accounts.google.com'].includes(claims?.iss)) {
          return JSON.stringify([claims.iss.replace('https://', ''), sub]);
        }
      }
    }
    throw new Error();
  } catch { throw new SafeError('invalidAuth'); }
}

// 고정 대상만 접근하고 토큰은 명령행·환경변수·임시 파일 없이 표준입력으로만 전달한다.
const script = String.raw`
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::InputEncoding = [Text.Encoding]::UTF8
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
/// <summary>Antigravity 단일 자격 증명에 사용하는 Windows API이다.</summary>
public static class LiteCredential {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct Entry {
    public uint Flags, Type;
    public string TargetName, Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
    public uint CredentialBlobSize;
    public IntPtr CredentialBlob;
    public uint Persist, AttributeCount;
    public IntPtr Attributes;
    public string TargetAlias, UserName;
  }
  /// <summary>지정된 일반 자격 증명만 읽는다.</summary>
  [DllImport("advapi32.dll", EntryPoint="CredReadW", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool Read(string target, uint type, uint flags, out IntPtr entry);
  /// <summary>한 자격 증명을 원자적으로 교체한다.</summary>
  [DllImport("advapi32.dll", EntryPoint="CredWriteW", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool Write(ref Entry entry, uint flags);
  /// <summary>서버 토큰을 취소하지 않고 지정한 로컬 자격 증명만 비운다.</summary>
  [DllImport("advapi32.dll", EntryPoint="CredDeleteW", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool Clear(string target, uint type, uint flags);
  /// <summary>읽기 버퍼만 해제한다.</summary>
  [DllImport("advapi32.dll", EntryPoint="CredFree")]
  public static extern void Free(IntPtr entry);
}
'@
# 한 줄에 한 요청을 처리하고 C# 형식은 시작 시 한 번만 컴파일한다.
while ($null -ne ($line = [Console]::In.ReadLine())) {
try {
  $request = $line | ConvertFrom-Json
  $ptr = [IntPtr]::Zero
  $current = $null
  if ([LiteCredential]::Read('gemini:antigravity', 1, 0, [ref]$ptr)) {
    try {
      $entry = [Runtime.InteropServices.Marshal]::PtrToStructure($ptr, [type][LiteCredential+Entry])
      # 알 수 없는 추가 속성이 있으면 손실 없는 복원을 보장하지 못하므로 거부한다.
      if ($entry.AttributeCount -ne 0 -or $entry.Flags -ne 0 -or $entry.Comment -or $entry.TargetAlias -or
          $entry.CredentialBlobSize -le 0 -or $entry.CredentialBlob -eq [IntPtr]::Zero) { throw 'unsupported' }
      $bytes = New-Object byte[] $entry.CredentialBlobSize
      [Runtime.InteropServices.Marshal]::Copy($entry.CredentialBlob, $bytes, 0, $bytes.Length)
      $current = @{ userName=[string]$entry.UserName; blobBase64=[Convert]::ToBase64String($bytes); persist=$entry.Persist }
    } finally { [LiteCredential]::Free($ptr) }
  } elseif ([Runtime.InteropServices.Marshal]::GetLastWin32Error() -ne 1168) { throw 'read' }
  if ($request.action -eq 'read') {
    [Console]::Out.WriteLine((@{ value=$current } | ConvertTo-Json -Compress -Depth 4))
  } elseif ($request.action -eq 'write' -or $request.action -eq 'clear') {
    $expected = $request.expected
    $same = (($null -eq $current) -and ($null -eq $expected)) -or
      ($current -and $expected -and $current.userName -ceq $expected.userName -and
       $current.blobBase64 -ceq $expected.blobBase64 -and $current.persist -eq $expected.persist)
    if (-not $same) { [Console]::Out.WriteLine('{"error":"changed"}'); continue }
    if ($request.action -eq 'clear') {
      if (-not [LiteCredential]::Clear('gemini:antigravity', 1, 0)) { throw 'clear' }
      [Console]::Out.WriteLine('{"ok":true}')
      continue
    }
    $data = $request.value
    $bytes = [Convert]::FromBase64String($data.blobBase64)
    $buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
    try {
      [Runtime.InteropServices.Marshal]::Copy($bytes, 0, $buffer, $bytes.Length)
      $entry = New-Object LiteCredential+Entry
      $entry.Type=1; $entry.TargetName='gemini:antigravity'; $entry.UserName=$data.userName
      $entry.CredentialBlobSize=$bytes.Length; $entry.CredentialBlob=$buffer; $entry.Persist=$data.persist
      if (-not [LiteCredential]::Write([ref]$entry, 0)) { throw 'write' }
    } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer) }
    [Console]::Out.WriteLine('{"ok":true}')
  } else { throw 'action' }
} catch { [Console]::Out.WriteLine('{"error":"credential"}') }
finally { [Console]::Out.Flush(); $request = $null; $current = $null; $line = $null; $bytes = $null }
}
`;

const encodedScript = Buffer.from(script, 'utf16le').toString('base64');
let worker: ChildProcessWithoutNullStreams | undefined;
let disposed = false;
let queued: Promise<unknown> = Promise.resolve();
let pending: { resolve: (output: string) => void; reject: (error: SafeError) => void } | undefined;

/** 실패 요청은 재실행하지 않고 종료하여 불확실한 쓰기를 반복하지 않는다. */
function stopWorker(): void {
  const child = worker;
  worker = undefined;
  const request = pending;
  pending = undefined;
  child?.kill();
  request?.reject(new SafeError('credential'));
}

/** 재사용하는 프로세스에서 응답 크기와 요청 대기 시간을 제한한다. */
function exchange(request: string): Promise<string> {
  return new Promise((resolve, reject) => {
    if (disposed) { reject(new SafeError('credential')); return; }
    if (!worker) {
      const executable = join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
      const child = spawn(executable, ['-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', encodedScript],
        { windowsHide: true, stdio: 'pipe' });
      worker = child;
      let output = '';
      child.stdout.setEncoding('utf8');
      child.stdout.on('data', (chunk: string) => {
        if (worker !== child) return;
        output += chunk;
        if (Buffer.byteLength(output) > 1024 * 1024) { stopWorker(); return; }
        const end = output.indexOf('\n');
        if (end < 0) return;
        // 순차 요청이므로 대기 요청 없는 응답이나 추가 응답은 통신 오류다.
        if (!pending || output.slice(end + 1).trim()) { stopWorker(); return; }
        const response = pending;
        pending = undefined;
        const line = output.slice(0, end);
        output = '';
        response.resolve(line);
      });
      child.stderr.resume(); // 인증을 포함할 수 있는 오류 원문은 수집하거나 기록하지 않는다.
      child.on('error', () => { if (worker === child) stopWorker(); });
      child.on('exit', () => { if (worker === child) stopWorker(); });
      child.stdin.on('error', () => { if (worker === child) stopWorker(); });
    }
    const timer = setTimeout(stopWorker, 15000);
    pending = {
      resolve: output => { clearTimeout(timer); resolve(output); },
      reject: error => { clearTimeout(timer); reject(error); }
    };
    try { worker.stdin.write(request + '\n', 'utf8'); }
    catch { stopWorker(); }
  });
}

/** 조회와 쓰기를 직렬화하여 요청별 응답이 섞이지 않게 한다. */
function requestCredential(request: string): Promise<string> {
  const result = queued.then(() => exchange(request));
  queued = result.then(() => undefined, () => undefined);
  return result;
}

/** OS 기본 PowerShell을 호출하며 출력과 실패 원문은 로그에 기록하지 않는다. */
async function credential(action: 'read' | 'write' | 'clear', raw?: string, expected?: string): Promise<string | undefined> {
  if (process.platform !== 'win32') throw new SafeError('unsupported');
  if (raw !== undefined) identifyCredential(raw);
  if (expected !== undefined) identifyCredential(expected);
  const request = JSON.stringify({ action, value: raw === undefined ? null : JSON.parse(raw.replace(/^\uFEFF/, '')),
    expected: expected === undefined ? null : JSON.parse(expected.replace(/^\uFEFF/, '')) });
  const output = await requestCredential(request);
  try {
    const result = JSON.parse(output.replace(/^\uFEFF/, '').trim());
    if (!result || typeof result !== 'object' || Array.isArray(result)) throw new Error();
    if (result.error) throw new SafeError(result.error === 'changed' ? 'changed' : 'credential');
    // 쓰기는 명시적 성공 확인이 있어야 하며 읽기 실패를 빈 자격 증명으로 취급하지 않는다.
    if (action !== 'read') {
      if (result.ok !== true) throw new Error();
      return undefined;
    }
    if (result.value === null) return undefined;
    const value: Credential = result.value;
    const raw = JSON.stringify({ userName: value.userName, blobBase64: value.blobBase64, persist: value.persist });
    identifyCredential(raw);
    return raw;
  } catch (error) {
    if (!(error instanceof SafeError)) stopWorker();
    if (error instanceof SafeError) throw error;
    throw new SafeError('credential');
  }
}

/** Windows의 공식 Antigravity VS Code 확장에 쓰이는 자격 증명만 전환한다. */
const agent: Agent = {
  id: 'antigravity', label: 'Antigravity',
  /** 독립 IDE의 SQLite 인증과 혼동하지 않도록 지원 호스트를 제한한다. */
  supportsHost: appName => process.platform === 'win32' && !/antigravity/i.test(appName),
  // 잠금 파일용 경로이며 토큰 파일은 만들지 않는다.
  authPath: join(process.env.LOCALAPPDATA || homedir(), 'AccountSwitcherLite', 'antigravity', 'credential'),
  identify: identifyCredential,
  /** 종료 대기 중인 요청도 새 프로세스를 생성하지 못하게 한다. */
  dispose: () => { disposed = true; stopWorker(); },
  /** OS 저장소의 현재 자격 증명을 읽는다. */
  read: () => credential('read'),
  /** 예상 값과 일치할 때만 OS 자격 증명을 교체한다. */
  replace: async (raw, expected) => { await credential('write', raw, expected); },
  /** 서버 로그아웃 없이 예상값과 일치하는 로컬 자격 증명만 비운다. */
  clear: async expected => { await credential('clear', undefined, expected); }
};
export default agent;
