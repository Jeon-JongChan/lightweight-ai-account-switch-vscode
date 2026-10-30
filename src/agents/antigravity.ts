import { execFile } from 'node:child_process';
import { join } from 'node:path';
import { homedir } from 'node:os';
import type { Agent } from '../accounts';
import { SafeError } from '../auth-file';

/** Windows 자격 증명 하나의 손실 없는 스냅샷이다. */
interface Credential { userName: string; blobBase64: string; persist: number }

/** 원문은 유지하고 Google ID 토큰의 subject로 계정을 구분한다. */
export function identifyCredential(raw: string): string {
  try {
    if (Buffer.byteLength(raw) > 1024 * 1024) throw new Error();
    const record: Credential = JSON.parse(raw.replace(/^\uFEFF/, ''));
    if (!record || typeof record.userName !== 'string' || record.userName.includes('\0') ||
        ![1, 2, 3].includes(record.persist) || typeof record.blobBase64 !== 'string') throw new Error();
    const bytes = Buffer.from(record.blobBase64, 'base64');
    if (!bytes.length || bytes.length > 2560 || bytes.toString('base64') !== record.blobBase64) throw new Error();
    const data = JSON.parse(bytes.toString('utf8'));
    if (!data?.token || typeof data.token.refresh_token !== 'string' || !data.token.refresh_token.trim() ||
        typeof data.id_token !== 'string') throw new Error();
    const parts = data.id_token.split('.');
    if (parts.length !== 3 || parts.some((part: string) => !part.trim())) throw new Error();
    const claims = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
    const sub = typeof claims?.sub === 'string' ? claims.sub.trim() : '';
    if (!sub || !['https://accounts.google.com', 'accounts.google.com'].includes(claims?.iss)) throw new Error();
    return JSON.stringify([claims.iss.replace('https://', ''), sub]);
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
  /// <summary>읽기 버퍼만 해제한다.</summary>
  [DllImport("advapi32.dll", EntryPoint="CredFree")]
  public static extern void Free(IntPtr entry);
}
'@
try {
  $request = [Console]::In.ReadToEnd() | ConvertFrom-Json
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
    @{ value=$current } | ConvertTo-Json -Compress -Depth 4
  } elseif ($request.action -eq 'write') {
    $expected = $request.expected
    $same = (($null -eq $current) -and ($null -eq $expected)) -or
      ($current -and $expected -and $current.userName -ceq $expected.userName -and
       $current.blobBase64 -ceq $expected.blobBase64 -and $current.persist -eq $expected.persist)
    if (-not $same) { @{ error='changed' } | ConvertTo-Json -Compress; exit }
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
    '{"ok":true}'
  } else { throw 'action' }
} catch { '{"error":"credential"}' }
`;

const encodedScript = Buffer.from(script, 'utf16le').toString('base64');

/** OS 기본 PowerShell을 호출하며 출력과 실패 원문은 로그에 기록하지 않는다. */
async function credential(action: 'read' | 'write', raw?: string, expected?: string): Promise<string | undefined> {
  if (process.platform !== 'win32') throw new SafeError('unsupported');
  if (raw !== undefined) identifyCredential(raw);
  if (expected !== undefined) identifyCredential(expected);
  const request = JSON.stringify({ action, value: raw === undefined ? null : JSON.parse(raw.replace(/^\uFEFF/, '')),
    expected: expected === undefined ? null : JSON.parse(expected.replace(/^\uFEFF/, '')) });
  const executable = join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  const output = await new Promise<string>((resolve, reject) => {
    const child = execFile(executable, ['-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand',
      encodedScript], { windowsHide: true, maxBuffer: 1024 * 1024, timeout: 15000 },
    (error, stdout) => error ? reject(new SafeError('credential')) : resolve(stdout));
    child.stdin?.on('error', () => { /* 자식 프로세스 종료는 콜백에서 토큰 없이 보고한다. */ });
    child.stdin?.end(request, 'utf8');
  });
  try {
    const result = JSON.parse(output.replace(/^\uFEFF/, '').trim());
    if (!result || typeof result !== 'object' || Array.isArray(result)) throw new Error();
    if (result.error) throw new SafeError(result.error === 'changed' ? 'changed' : 'credential');
    // 쓰기는 명시적 성공 확인이 있어야 하며 읽기 실패를 빈 자격 증명으로 취급하지 않는다.
    if (action === 'write') {
      if (result.ok !== true) throw new Error();
      return undefined;
    }
    if (result.value === null) return undefined;
    const value: Credential = result.value;
    const raw = JSON.stringify({ userName: value.userName, blobBase64: value.blobBase64, persist: value.persist });
    identifyCredential(raw);
    return raw;
  } catch (error) {
    if (error instanceof SafeError && error.code === 'changed') throw error;
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
  /** OS 저장소의 현재 자격 증명을 읽는다. */
  read: () => credential('read'),
  /** 예상 값과 일치할 때만 OS 자격 증명을 교체한다. */
  replace: async (raw, expected) => { await credential('write', raw, expected); }
};
export default agent;
