#requires -Version 5.1
<#
Node.js - 독립 실행 스크립트 (Windows x64, PowerShell 5.1+, Facade 4-액션 내장).
이 파일 하나만 프로젝트에 복사해도 설치·환경설정(검증/세션/전역/prime/offline-check/vue-init)·최신화·초기화가 모두 동작한다.
  대화형 메뉴: .\nodejs.ps1
  비대화형:    .\nodejs.ps1 -Action install | configure -Mode verify|env|global-on|global-off|prime|offline-check|list|run | update | reset -Yes | vue-init
  세션 적용:   . .\nodejs.ps1 -Action env   (dot-source)
#>
[CmdletBinding()]
param(
 [ValidateSet('menu','install','configure','verify','update','reset','prime','offline-check','env','global-on','global-off','remove','list','run','vue-init')][string]$Action='menu',
 [ValidateSet('verify','env','global-on','global-off','prime','offline-check','list','run')][string]$Mode='verify',
 [ValidateSet('none','emulator','tauri','vue')][string]$Feature='none',
 [ValidateSet('','install','verify','prime','offline-check','list','start','remove','init')][string]$Operation='',
 [ValidateSet('all','env','tools')][string]$Scope='all',
 [switch]$AcceptAndroidLicenses,
 [int]$NodeMajor=24, [string]$Project='',
 [switch]$Yes, [string[]]$CommandArgs=@()
)
$Lang='nodejs'
$Root=$PSScriptRoot
$State=Join-Path $Root "$Lang\_state"
$DefaultProject=if ((Split-Path -Leaf $Root) -ieq '.build') { Split-Path -Parent $Root } else { $Root }
if (-not $Project) { $Project=$DefaultProject }

if ($Action -ne 'env') {
 Set-StrictMode -Version Latest
 $ErrorActionPreference='Stop'
 $global:LASTEXITCODE=0
 [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
 $ProgressPreference='SilentlyContinue'
 if (-not [Environment]::Is64BitOperatingSystem) { throw 'A 64-bit Windows host is required.' }
 if ($env:OS -ne 'Windows_NT') { throw 'Use nodejs.sh on Linux.' }
 if (-not (Test-Path -LiteralPath $Project -PathType Container)) { throw "Project directory not found: $Project" }
 $Project=(Resolve-Path -LiteralPath $Project).Path
}

function Log([string]$Message) { Write-Host "[build-kit] $Message" }
function AssertExit([string]$Message) { if ($global:LASTEXITCODE) { throw "$Message (exit $global:LASTEXITCODE)" } }
function EnsureDir([string]$Path) {
 if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
 $probe=Join-Path $Path ('.pbk-acl-' + [Guid]::NewGuid().ToString('N'))
 try {
  New-Item -ItemType File -Path $probe -Force -ErrorAction Stop | Out-Null
  Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
 } catch {
  & takeown.exe /F $Path /R /D Y 2>&1 | Out-Null
  & icacls.exe $Path /grant "${env:USERNAME}:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
  $global:LASTEXITCODE=0
 }
}
function RemoveTree([string]$Path) {
 if (-not (Test-Path -LiteralPath $Path)) { return }
 try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
 catch {
  EnsureDir $Path
  Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
   try { if ($_.Attributes -band [IO.FileAttributes]::ReadOnly) { $_.Attributes = $_.Attributes -bxor [IO.FileAttributes]::ReadOnly } } catch {}
  }
  try {
   $rootItem=Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
   if ($rootItem -and ($rootItem.Attributes -band [IO.FileAttributes]::ReadOnly)) { $rootItem.Attributes = $rootItem.Attributes -bxor [IO.FileAttributes]::ReadOnly }
  } catch {}
  Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
 }
}
function Download([string]$Url,[string]$Destination) {
 EnsureDir (Split-Path -Parent $Destination)
 Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -MaximumRedirection 12
 try { Unblock-File -LiteralPath $Destination -ErrorAction SilentlyContinue } catch {}
}
function CheckSha([string]$File,[string]$Expected) {
 if ($Expected -notmatch '^[0-9a-fA-F]{64}$') { throw "Invalid SHA256 for $File" }
 if ((Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash -ine $Expected) { throw "SHA256 mismatch for $File" }
}
function Unpack([string]$Archive,[string]$Destination) {
 $staging=Join-Path $State ("extract-" + [Guid]::NewGuid().ToString('N'))
 EnsureDir $staging; EnsureDir $Destination
 try {
  $global:LASTEXITCODE=0
  & (Join-Path $env:SystemRoot 'System32\tar.exe') --no-same-owner --no-same-permissions -xf $Archive -C $staging; AssertExit 'Cannot extract archive'
  $items=@(Get-ChildItem -LiteralPath $staging -Force)
  $src=$staging
  if ($items.Count -eq 1 -and $items[0].PSIsContainer) { $src=$items[0].FullName }
  foreach ($item in (Get-ChildItem -LiteralPath $src -Force)) {
   $existing=Join-Path $Destination $item.Name
   if (Test-Path -LiteralPath $existing) { Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force }
   else {
    try { Move-Item -LiteralPath $item.FullName -Destination $existing -Force -ErrorAction Stop }
    catch { Copy-Item -LiteralPath $item.FullName -Destination $existing -Recurse -Force }
   }
  }
 } finally { RemoveTree $staging }
}

function ProjectRef {
 $base=$DefaultProject.TrimEnd('\')
 if ($Project -ieq $base) { return '.' }
 if ($Project.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)) { return $Project.Substring($base.Length+1) }
 return $Project
}
function ProjectKey {
 $bytes=[Text.Encoding]::UTF8.GetBytes((ProjectRef).ToLowerInvariant())
 $hash=[Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
 return ([BitConverter]::ToString($hash) -replace '-','').Substring(0,12).ToLowerInvariant()
}
function NodeStore { return (Join-Path $Root ("nodejs\projects\"+(ProjectKey))) }
function NodeLink { return (Join-Path $Project 'node_modules') }
function NodeLockHash { return (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Project 'package-lock.json')).Hash.ToLowerInvariant() }
function TestNodeLink([string]$Store) {
 <# .SYNOPSIS 일반 폴더는 보호하고 관리 기록이 일치하는 이동된 링크와 복사본만 복구합니다. #>
 $link=NodeLink; $target=Join-Path $Store 'node_modules'
 $item=Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
 if ($item) {
  if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
   $actual=[string]($item.Target -join '')
  } else {
   $managed=Join-Path $link '.pbk-managed'
   if (-not (Test-Path -LiteralPath $managed -PathType Leaf)) { throw "Unmanaged node_modules directory exists: $link. Back it up manually." }
   $actual=(Get-Content -Raw -LiteralPath $managed).Trim()
  }
  if (-not [IO.Path]::IsPathRooted($actual)) { throw "Invalid node_modules target: $actual" }
  $actual=[IO.Path]::GetFullPath($actual).TrimEnd('\')
  if ($actual -ieq [IO.Path]::GetFullPath($target).TrimEnd('\')) { return }
  $marker=Join-Path $Store 'project.txt'
  $suffix='\nodejs\projects\'+(Split-Path -Leaf $Store)+'\node_modules'
  # 이전 절대 경로는 같은 프로젝트의 저장소 경로와 관리 기록이 일치할 때만 이전합니다.
  if (-not $actual.EndsWith($suffix,[StringComparison]::OrdinalIgnoreCase) -or
      -not (Test-Path -LiteralPath $marker -PathType Leaf) -or
      (Get-Content -Raw -LiteralPath $marker).Trim() -ine (ProjectRef) -or
      -not (Test-Path -LiteralPath $target -PathType Container)) { throw "Unmanaged node_modules target: $actual" }
  if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
   [IO.Directory]::Delete($link)
   LinkOrCopyNode $target $link
  } else {
   Set-Content -LiteralPath $managed -Value $target -Encoding UTF8
  }
 }
}
function LinkOrCopyNode([string]$Target,[string]$Link) {
 <# .SYNOPSIS 정션을 만들고 지원되지 않는 파일시스템에서는 관리 마커가 있는 복사본을 만듭니다. #>
 try { New-Item -ItemType Junction -Path $Link -Target $Target -ErrorAction Stop | Out-Null }
 catch {
  # exFAT 등 NTFS Junction 미지원 볼륨 폴백: 복사본 생성 후 관리 마커 기록
  Copy-Item -LiteralPath $Target -Destination $Link -Recurse -Force
  Set-Content -LiteralPath (Join-Path $Link '.pbk-managed') -Value $Target -Encoding UTF8
 }
}
function RemoveNodeLink([string]$Store) {
 <# .SYNOPSIS 검증한 관리 링크만 제거하고 링크 대상 디렉터리는 보존합니다. #>
 $link=NodeLink
 TestNodeLink $Store
 $item=Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
 if ($item) {
  if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
   [IO.Directory]::Delete($link)
  } else { RemoveTree $link }
 }
}
function PrepareNodeDependencies([bool]$Offline) {
 <# .SYNOPSIS 프로젝트 의존성 저장소와 관리 연결을 준비하고 오프라인 스냅샷을 검증합니다. #>
 if (-not (Test-Path (Join-Path $Project 'package-lock.json'))) { throw 'package-lock.json required' }
 if (-not (Test-Path (Join-Path $Project 'package.json'))) { throw 'package.json required' }
 $store=NodeStore; $link=NodeLink; $target=Join-Path $store 'node_modules'
 EnsureDir $store
 $marker=Join-Path $store 'project.txt'
 if ((Test-Path $marker) -and ((Get-Content -Raw $marker).Trim() -ine (ProjectRef))) { throw 'Node store hash collision' }
 TestNodeLink $store
 $hash=NodeLockHash
 if ($Offline) {
  $snapshot=Join-Path $store 'package-lock.sha256'
  if (-not (Test-Path $snapshot) -or ((Get-Content -Raw $snapshot).Trim() -ne $hash) -or -not (Test-Path $target)) { throw 'Node dependency snapshot missing/stale; prime while online first.' }
  if (-not (Test-Path $link)) { LinkOrCopyNode $target $link }
  return
 }
 RemoveNodeLink $store
 if (Test-Path -LiteralPath $target) { RemoveTree $target }
 Push-Location $Project
 try { & npm.cmd ci --include=optional; AssertExit 'npm ci failed' }
 finally { Pop-Location }
 if (-not (Test-Path -LiteralPath $link -PathType Container)) { throw 'npm ci did not create node_modules' }
 Move-Item -LiteralPath $link -Destination $target
 Set-Content -LiteralPath $marker -Value (ProjectRef) -Encoding UTF8
 Set-Content -LiteralPath (Join-Path $store 'package-lock.sha256') -Value $hash -Encoding ASCII
 LinkOrCopyNode $target $link
 Log "Node project libraries physically stored in $target"
}
function CleanupNodeLinks {
 <# .SYNOPSIS 이동 후에도 관리되는 프로젝트 연결만 정리합니다. #>
 $base=Join-Path $Root 'nodejs\projects'
 if (-not (Test-Path $base)) { return }
 foreach ($store in (Get-ChildItem -LiteralPath $base -Directory)) {
  $marker=Join-Path $store.FullName 'project.txt'
  if (-not (Test-Path $marker)) { continue }
  $oldProject=$Project; $ref=(Get-Content -Raw $marker).Trim()
  if ([IO.Path]::IsPathRooted($ref)) { $script:Project=$ref }
  elseif ($ref -eq '.') { $script:Project=$DefaultProject }
  else { $script:Project=Join-Path $DefaultProject $ref }
  try { if (Get-Item -LiteralPath (NodeLink) -Force -ErrorAction SilentlyContinue) { RemoveNodeLink $store.FullName } }
  finally { $script:Project=$oldProject }
 }
}

function EnvMap {
 [ordered]@{
  'GIT_CONFIG_COUNT'='1'; 'GIT_CONFIG_KEY_0'='safe.directory'; 'GIT_CONFIG_VALUE_0'='*'
  'npm_config_cache'=(Join-Path $Root 'nodejs\npm-cache'); 'npm_config_prefix'=(Join-Path $Root 'nodejs\npm-global'); 'npm_config_userconfig'=(Join-Path $Root 'nodejs\npmrc')
  'COREPACK_HOME'=(Join-Path $Root 'nodejs\corepack'); 'npm_config_update_notifier'='false'; 'npm_config_unsafe_perm'='true'
 }
}
function EnvPaths { @('nodejs\node') | ForEach-Object { Join-Path $Root $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Container } }
function Activate {
 $map=EnvMap
 foreach ($key in $map.Keys) { [Environment]::SetEnvironmentVariable($key,$map[$key],'Process') }
 Remove-Item Env:UV_MANAGED_PYTHON -ErrorAction SilentlyContinue
 $paths=@(EnvPaths)
 if ($paths.Count -gt 0) { $env:Path=($paths -join ';')+';'+$env:Path }
}
function Install {
 $node=Join-Path $Root 'nodejs\node\node.exe'
 if (Test-Path $node) { Log 'Node.js already present'; return }
 $list=(Invoke-WebRequest -Uri "https://nodejs.org/dist/latest-v$NodeMajor.x/SHASUMS256.txt" -UseBasicParsing).Content
 $match=[regex]::Match($list,"(?m)^([0-9a-fA-F]{64})\s+(node-v$NodeMajor\.[0-9]+\.[0-9]+-win-x64\.zip)\s*$")
 if (-not $match.Success) { throw "Node.js $NodeMajor LTS Windows archive not found" }
 $filename=$match.Groups[2].Value
 $file=Join-Path $State $filename
 Download "https://nodejs.org/dist/latest-v$NodeMajor.x/$filename" $file
 CheckSha $file $match.Groups[1].Value
 Unpack $file (Join-Path $Root 'nodejs\node'); Remove-Item $file -Force
}
function Verify {
 & (Join-Path $Root 'nodejs\node\node.exe') --version; AssertExit 'Node verification failed'
 & (Join-Path $Root 'nodejs\node\npm.cmd') --version; AssertExit 'npm verification failed'
}
function Update {
 $node=Join-Path $Root 'nodejs\node'; $exe=Join-Path $node 'node.exe'
 if (-not (Test-Path $exe)) { throw 'Install Node.js first' }
 $sums=[string](Invoke-WebRequest -Uri "https://nodejs.org/dist/latest-v$NodeMajor.x/SHASUMS256.txt" -UseBasicParsing).Content
 $matched=[regex]::Match($sums,'node-(v[0-9]+\.[0-9]+\.[0-9]+)-win-x64\.zip')
 if (-not $matched.Success) { throw 'Cannot resolve latest Node.js patch' }
 $latest=$matched.Groups[1].Value
 if ((& $exe --version) -eq $latest) { Log "Node.js already at $latest"; return }
 $backup=Join-Path $State 'update-backup-nodejs'
 if (Test-Path $backup) { throw "Incomplete previous update: $backup" }
 EnsureDir $State
 Move-Item -LiteralPath $node -Destination $backup
 try { Install; RemoveTree $backup }
 catch { RemoveTree $node; Move-Item -LiteralPath $backup -Destination $node; throw }
}
function Prime([bool]$Offline) {
 PrepareNodeDependencies $Offline
 Push-Location $Project
 try { & npm.cmd run build --if-present; AssertExit 'Frontend build failed' }
 finally { Pop-Location }
}
function VueInit {
 Install; Activate
 if (@(Get-ChildItem -LiteralPath $Project -Force).Count -gt 0) { throw "Vue target must be an empty directory: $Project" }
 Push-Location $Project
 try { & npm.cmd create vue@latest '--' '--typescript' '.'; AssertExit 'Vue scaffold failed' }
 finally { Pop-Location }
 Log 'Vue files generated. Run nodejs prime to install/capture dependencies.'
}
function SetUserEnv([string]$Name, $Value) {
 $reg='HKCU:\Environment'
 if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null }
 if ($null -eq $Value -or $Value -eq '') {
  Remove-ItemProperty -LiteralPath $reg -Name $Name -ErrorAction SilentlyContinue
 } else {
  $kind=if ($Name -eq 'Path') { 'ExpandString' } else { 'String' }
  New-ItemProperty -LiteralPath $reg -Name $Name -Value ([string]$Value) -PropertyType $kind -Force | Out-Null
 }
}
function GetUserEnv([string]$Name) {
 return (Get-Item -LiteralPath 'HKCU:\Environment').GetValue($Name,$null,'DoNotExpandEnvironmentNames')
}
function GlobalOn {
 EnsureDir $State
 $marker=Join-Path $State 'global-windows.json'
 if (Test-Path $marker) { throw 'global-on already active. Use global-off first.' }
 $values=EnvMap
 $old=@{}; $applied=@{}
 foreach ($k in $values.Keys) {
  $old[$k]=GetUserEnv $k
  $applied[$k]=[string]$values[$k]
 }
 $old['Path']=GetUserEnv 'Path'
 $paths=@(EnvPaths)
 $base=[string]$old['Path']
 foreach ($path in $paths) {
  if (($base -split ';') -notcontains $path) { $base=($base.TrimEnd(';')+';'+$path).TrimStart(';') }
 }
 $applied['Path']=$base
 $record=@{ old=$old; applied=$applied; origin=$Root; utc=[DateTime]::UtcNow.ToString('o') }
 $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $marker -Encoding UTF8
 foreach ($k in $applied.Keys) { SetUserEnv $k $applied[$k] }
 Log 'User-level environment recorded and applied (HKCU).'
}
function GlobalOff {
 $marker=Join-Path $State 'global-windows.json'
 if (-not (Test-Path $marker)) { Log 'No global changes tracked'; return }
 $record=Get-Content -Raw -LiteralPath $marker | ConvertFrom-Json
 $conflicts=@()
 foreach ($prop in $record.applied.PSObject.Properties) {
  $k=$prop.Name
  $current=GetUserEnv $k
  if ($current -cne [string]$prop.Value) { $conflicts += $k }
 }
 if ($conflicts.Count) {
  Log "Externally changed variables were preserved: $($conflicts -join ', ')"
  throw 'Restore stopped without changing settings. Resolve conflicts using the saved global-windows.json.'
 }
 foreach ($prop in $record.applied.PSObject.Properties) {
  $k=$prop.Name
  $previous=$record.old.PSObject.Properties[$k].Value
  SetUserEnv $k $previous
 }
 Remove-Item -LiteralPath $marker -Force
 Log 'Restored original user environment values exactly.'
}
function InteractiveMenu {
 Write-Host "`n=== Portable Build Kit: $Lang ==="
 Write-Host '1. 설치 (Install)'
 Write-Host '2. 환경설정 (Configure)'
 Write-Host '3. 최신화 (Update)'
 Write-Host '4. 초기화 (Reset)'
 Write-Host '0. 종료'
 $choice=Read-Host 'Choice'
 switch ($choice) {
  '1' { $script:Action='install' }
  '2' {
   $script:Action='configure'
   Write-Host 'Configuration: 1 verify | 2 session env | 3 global-on | 4 global-off'
   Write-Host '               5 prime | 6 offline-check | 7 list | 8 optional features | 0 back'
   $choice2=Read-Host 'Choice'
   switch ($choice2) {
    '1' {$script:Mode='verify'} '2' {$script:Mode='env'} '3' {$script:Mode='global-on'}
    '4' {$script:Mode='global-off'} '5' {$script:Mode='prime'}
    '6' {$script:Mode='offline-check'} '7' {$script:Mode='list'}
    '8' {
     $script:Feature='vue'
     Write-Host 'Vue: 1 initialize project (empty folder) | 0 back'
     $v=Read-Host 'Choice'
     $script:Operation=switch ($v) {'1' {'init'} '0' {exit 0} default {throw 'Invalid Vue option'}}
    }
    '0' { exit 0 }
    default { throw 'Invalid configure choice' }
   }
  }
  '3' { $script:Action='update' }
  '4' {
   $script:Action='reset'
   Write-Host 'Reset: 1 restore env + remove tools | 2 restore env | 3 remove tools | 0 back'
   $choice2=Read-Host 'Choice'
   $script:Scope=switch ($choice2) { '1' {'all'} '2' {'env'} '3' {'tools'} '0' {exit 0} default {throw 'Invalid reset scope'} }
   if ((Read-Host "Type RESET to confirm [$Lang/$Scope]") -cne 'RESET') { Log 'Cancelled'; exit 0 }
   $script:Yes=$true
  }
  '0' { exit 0 }
  default { throw 'Invalid menu choice' }
 }
}

if ($Action -eq 'menu') { InteractiveMenu }
if ($Action -eq 'configure') {
 if ($Feature -eq 'vue' -and $Operation -eq 'init') { $Action='vue-init' }
 elseif ($Feature -ne 'none') { throw "Unsupported feature for ${Lang}: $Feature" }
 else { $Action=$Mode }
}
switch ($Action) {
 install { Install }
 verify { Activate; Verify }
 update { Update }
 prime { Activate; Prime $false }
 'offline-check' { Activate; Prime $true }
 'global-on' { GlobalOn }
 'global-off' { GlobalOff }
 'vue-init' { VueInit }
 list { foreach ($l in @('go','rust','kotlin','csharp','nodejs','python')) { Write-Host ("{0,-8} {1}" -f $l,$(if (Test-Path (Join-Path $Root $l)) {'present'} else {'absent'})) } }
 { $_ -in @('reset','remove') } {
  if ($Action -eq 'remove' -and (Test-Path (Join-Path $State 'global-windows.json'))) { throw 'global-on exists; run global-off first' }
  if ($Action -eq 'reset' -and $Scope -ne 'env' -and -not $Yes) { throw 'Reset deletes tools; pass -Yes after reviewing' }
  switch ($Scope) {
   all { GlobalOff }
   env { GlobalOff; return }
   tools { if (Test-Path (Join-Path $State 'global-windows.json')) { throw 'Restore globals first or use -Scope all' } }
  }
  CleanupNodeLinks
  $dir=Join-Path $Root $Lang
  if (Test-Path -LiteralPath $dir) { RemoveTree $dir }
  Log "Removed $Lang"
 }
 env { Activate; Log "$Lang environment active in this session" }
 run {
  Activate
  if ($CommandArgs.Count -eq 0) { throw 'Specify -CommandArgs' }
  $rest=@(); if ($CommandArgs.Count -gt 1) { $rest=@($CommandArgs[1..($CommandArgs.Count-1)]) }
  & $CommandArgs[0] @rest; AssertExit 'Command failed'
 }
 default { throw "Unsupported action: $Action" }
}
