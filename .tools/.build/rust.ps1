#requires -Version 5.1
<#
Rust - 독립 실행 스크립트 (Windows x64, PowerShell 5.1+, Facade 4-액션 내장).
이 파일 하나만 프로젝트에 복사해도 설치·환경설정(검증/세션/전역/prime/offline-check/tauri)·최신화·초기화가 모두 동작한다.
  대화형 메뉴: .\rust.ps1
  비대화형:    .\rust.ps1 -Action install | configure -Mode verify|env|global-on|global-off|prime|offline-check|list|run | update | reset -Yes
  세션 적용:   . .\rust.ps1 -Action env   (dot-source)
#>
[CmdletBinding()]
param(
 [ValidateSet('menu','install','configure','verify','update','reset','prime','offline-check','env','global-on','global-off','remove','list','run','tauri-install','tauri-verify','tauri-prime','tauri-offline-check','tauri-remove')][string]$Action='menu',
 [ValidateSet('verify','env','global-on','global-off','prime','offline-check','list','run')][string]$Mode='verify',
 [ValidateSet('none','emulator','tauri','vue')][string]$Feature='none',
 [ValidateSet('','install','verify','prime','offline-check','list','start','remove','init')][string]$Operation='',
 [ValidateSet('all','env','tools')][string]$Scope='all',
 [string]$Project='',
 [switch]$AcceptAndroidLicenses, [switch]$WithNdk, [switch]$WithAdb,
 [int]$NodeMajor=24,
 [ValidateSet('msvc','gnu')][string]$RustAbi='msvc',
 [switch]$Yes, [string[]]$CommandArgs=@()
)
$Lang='rust'
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
 if ($env:OS -ne 'Windows_NT') { throw 'Use rust.sh on Linux.' }
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
function RustTargetDir { return (Join-Path $Root ("rust\targets\"+(ProjectKey))) }

function EnvMap {
 [ordered]@{
  'GIT_CONFIG_COUNT'='1'; 'GIT_CONFIG_KEY_0'='safe.directory'; 'GIT_CONFIG_VALUE_0'='*'
  'RUSTUP_HOME'=(Join-Path $Root 'rust\rustup'); 'CARGO_HOME'=(Join-Path $Root 'rust\cargo')
  'npm_config_cache'=(Join-Path $Root 'nodejs\npm-cache'); 'npm_config_prefix'=(Join-Path $Root 'nodejs\npm-global'); 'npm_config_userconfig'=(Join-Path $Root 'nodejs\npmrc')
  'COREPACK_HOME'=(Join-Path $Root 'nodejs\corepack'); 'npm_config_update_notifier'='false'; 'npm_config_unsafe_perm'='true'
 }
}
function EnvPaths { @('rust\cargo\bin','nodejs\node') | ForEach-Object { Join-Path $Root $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Container } }
function Activate {
 $map=EnvMap
 foreach ($key in $map.Keys) { [Environment]::SetEnvironmentVariable($key,$map[$key],'Process') }
 Remove-Item Env:UV_MANAGED_PYTHON -ErrorAction SilentlyContinue
 $paths=@(EnvPaths)
 if ($paths.Count -gt 0) { $env:Path=($paths -join ';')+';'+$env:Path }
}
function HasMsvc {
 <# MSVC 링커 존재 여부. 일반 터미널 PATH에는 link.exe가 없으므로 rustup과 같은 vswhere 탐지도 허용 #>
 if (Get-Command link.exe -ErrorAction SilentlyContinue) { return $true }
 $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
 if (-not (Test-Path -LiteralPath $vswhere)) { return $false }
 return [bool](& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
}
function Install {
 $cargo=Join-Path $Root 'rust\cargo\bin\cargo.exe'
 if (Test-Path $cargo) { Log 'Rust already present'; return }
 if ($RustAbi -eq 'msvc' -and -not (HasMsvc)) {
  throw 'Rust MSVC needs an existing Windows SDK/MSVC linker. Run in a Developer Command Prompt or use -RustAbi gnu for minimal standalone Rust; no system-wide Visual Studio install will be attempted.'
 }
 $base='https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe'
 $installer=Join-Path $State 'rustup-init.exe'
 Download ($base+'.sha256') ($installer+'.sha256')
 $hash=([regex]::Match((Get-Content -Raw ($installer+'.sha256')), '[0-9a-fA-F]{64}')).Value
 Download $base $installer; CheckSha $installer $hash
 Activate
 $env:RUSTUP_INIT_SKIP_PATH_CHECK='yes'
 & $installer -y --no-modify-path --profile minimal --default-toolchain stable --default-host "x86_64-pc-windows-$RustAbi"
 AssertExit 'Rustup installation failed'
 Remove-Item $installer,($installer+'.sha256') -Force
 Log 'Rust installed. Windows MSVC linker/SDK is a separate host prerequisite for native Rust linking.'
}
function InstallNodejsShared {
 $node=Join-Path $Root 'nodejs\node\node.exe'
 if (Test-Path $node) { return }
 $nodeScript=Join-Path $Root 'nodejs.ps1'
 if (Test-Path -LiteralPath $nodeScript) { & $nodeScript -Action install -NodeMajor $NodeMajor; return }
 $list=(Invoke-WebRequest -Uri "https://nodejs.org/dist/latest-v$NodeMajor.x/SHASUMS256.txt" -UseBasicParsing).Content
 $match=[regex]::Match($list,"(?m)^([0-9a-fA-F]{64})\s+(node-v$NodeMajor\.[0-9]+\.[0-9]+-win-x64\.zip)\s*$")
 if (-not $match.Success) { throw "Node.js $NodeMajor LTS Windows archive not found" }
 $filename=$match.Groups[2].Value
 $file=Join-Path $State $filename
 Download "https://nodejs.org/dist/latest-v$NodeMajor.x/$filename" $file
 CheckSha $file $match.Groups[1].Value
 Unpack $file (Join-Path $Root 'nodejs\node'); Remove-Item $file -Force
}
function Verify { & (Join-Path $Root 'rust\cargo\bin\rustc.exe') --version; AssertExit 'Rust verification failed' }
function Update {
 if (-not (Test-Path (Join-Path $Root 'rust\cargo\bin\rustup.exe'))) { throw 'Install Rust first' }
 Activate; & rustup set profile minimal; AssertExit 'Rust profile failed'
 & rustup update stable; AssertExit 'Rust update failed'
}
function Prime([bool]$Offline) {
 if (-not (Test-Path (Join-Path $Root 'rust\cargo\bin\cargo.exe'))) { throw 'Rust missing' }
 Push-Location $Project
 try {
  if (-not (Test-Path Cargo.toml)) { throw 'Cargo.toml missing' }
  $env:CARGO_TARGET_DIR=RustTargetDir
  if ($Offline) { & cargo build --offline }
  else { & cargo fetch; AssertExit 'Cargo fetch failed'; & cargo build }
  AssertExit 'Rust build failed'
 } finally { Pop-Location }
}
function InstallTauri {
 Install; InstallNodejsShared
 if ($RustAbi -ne 'msvc') { throw 'Windows Tauri requires Rust MSVC; choose -RustAbi msvc and host MSVC Build Tools' }
 if ($WithNdk) {
  $ktScript=Join-Path $Root 'kotlin.ps1'
  if (Test-Path -LiteralPath $ktScript) { & $ktScript -Action install -WithNdk -AcceptAndroidLicenses:$AcceptAndroidLicenses }
  Activate
  & (Join-Path $Root 'rust\cargo\bin\rustup.exe') target add aarch64-linux-android
  AssertExit 'Cannot add Android Rust target'
 }
 EnsureDir (Join-Path $Root 'rust\tauri')
 Set-Content -LiteralPath (Join-Path $Root 'rust\tauri\README.txt') -Value 'Optional Tauri 2 uses shared Rust and portable Node.js; app dependencies are project-specific.' -Encoding UTF8
 Log 'Tauri requires host MSVC/Windows SDK and WebView2; check -Action tauri-verify.'
}
function VerifyTauri {
 Verify
 & (Join-Path $Root 'nodejs\node\node.exe') --version; AssertExit 'Node verification failed'
 & (Join-Path $Root 'nodejs\node\npm.cmd') --version; AssertExit 'npm verification failed'
 if (-not (HasMsvc)) { throw 'Missing host MSVC C++ Build Tools (link.exe)' }
 Log 'MSVC linker found; Windows SDK/WebView2 packaging require real build verification.'
}
function PrimeTauri([bool]$Offline) {
 if (-not (Test-Path (Join-Path $Project 'src-tauri\Cargo.toml'))) { throw 'src-tauri/Cargo.toml missing' }
 $nodeScript=Join-Path $Root 'nodejs.ps1'
 if (Test-Path -LiteralPath $nodeScript) {
  & $nodeScript -Action $(if ($Offline) {'offline-check'} else {'prime'}) -Project $Project
 } else {
  Push-Location $Project
  try {
   if (-not $Offline) { & npm.cmd ci --include=optional; AssertExit 'npm ci failed' }
   & npm.cmd run build --if-present; AssertExit 'Frontend build failed'
  } finally { Pop-Location }
 }
 Push-Location (Join-Path $Project 'src-tauri')
 try {
  $env:CARGO_TARGET_DIR=RustTargetDir
  if ($Offline) { & cargo build --offline }
  else { & cargo fetch; AssertExit 'Tauri cargo fetch failed'; & cargo build }
  AssertExit 'Tauri native core build failed'
 } finally { Pop-Location }
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
     $script:Feature='tauri'
     Write-Host 'Tauri: 1 install | 2 verify | 3 prime | 4 offline-check | 5 remove | 0 back'
     $v=Read-Host 'Choice'
     $script:Operation=switch ($v) {'1' {'install'} '2' {'verify'} '3' {'prime'} '4' {'offline-check'} '5' {'remove'} '0' {exit 0} default {throw 'Invalid Tauri option'}}
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
 if ($Feature -eq 'tauri') { $Action="tauri-$Operation" }
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
 'tauri-install' { InstallTauri }
 'tauri-verify' { Activate; VerifyTauri }
 'tauri-prime' { Activate; PrimeTauri $false }
 'tauri-offline-check' { Activate; PrimeTauri $true }
 'tauri-remove' { RemoveTree (Join-Path $Root 'rust\tauri'); Log 'Removed optional Tauri marker; shared tools/caches preserved' }
 list { foreach ($l in @('go','rust','kotlin','csharp','nodejs','python')) { Write-Host ("{0,-8} {1}" -f $l,$(if (Test-Path (Join-Path $Root $l)) {'present'} else {'absent'})) } }
 { $_ -in @('reset','remove') } {
  if ($Action -eq 'remove' -and (Test-Path (Join-Path $State 'global-windows.json'))) { throw 'global-on exists; run global-off first' }
  if ($Action -eq 'reset' -and $Scope -ne 'env' -and -not $Yes) { throw 'Reset deletes tools; pass -Yes after reviewing' }
  switch ($Scope) {
   all { GlobalOff }
   env { GlobalOff; return }
   tools { if (Test-Path (Join-Path $State 'global-windows.json')) { throw 'Restore globals first or use -Scope all' } }
  }
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
