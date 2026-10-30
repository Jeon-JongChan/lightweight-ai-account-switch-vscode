#requires -Version 5.1
<#
Go - 독립 실행 스크립트 (Windows x64, PowerShell 5.1+, Facade 4-액션 내장).
이 파일 하나만 프로젝트에 복사해도 설치·환경설정(검증/세션/전역/prime/offline-check)·최신화·초기화가 모두 동작한다.
  대화형 메뉴: .\go.ps1
  비대화형:    .\go.ps1 -Action install | configure -Mode verify|env|global-on|global-off|prime|offline-check|list|run | update | reset -Yes
  세션 적용:   . .\go.ps1 -Action env   (dot-source)
#>
[CmdletBinding()]
param(
 [ValidateSet('menu','install','configure','verify','update','reset','prime','offline-check','env','global-on','global-off','remove','list','run')][string]$Action='menu',
 [ValidateSet('verify','env','global-on','global-off','prime','offline-check','list','run')][string]$Mode='verify',
 [ValidateSet('none','emulator','tauri','vue')][string]$Feature='none',
 [ValidateSet('','install','verify','prime','offline-check','list','start','remove','init')][string]$Operation='',
 [ValidateSet('all','env','tools')][string]$Scope='all',
 [string]$Project='',
 [switch]$AcceptAndroidLicenses,
 [string]$GoVersion='1.27.2',
 [switch]$Yes, [string[]]$CommandArgs=@()
)
$Lang='go'
$Root=$PSScriptRoot
$State=Join-Path $Root "$Lang\_state"
$DefaultProject=if ((Split-Path -Leaf $Root) -ieq '.build') { Split-Path -Parent $Root } else { $Root }
if (-not $Project) { $Project=$DefaultProject }

# dot-source(env)일 때는 호출자 세션의 엄격 모드/오류 설정을 바꾸지 않는다
if ($Action -ne 'env') {
 Set-StrictMode -Version Latest
 $ErrorActionPreference='Stop'
 $global:LASTEXITCODE=0
 [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
 # PS 5.1 진행률 표시는 Invoke-WebRequest 다운로드를 수십 배 느리게 함
 $ProgressPreference='SilentlyContinue'
 if (-not [Environment]::Is64BitOperatingSystem) { throw 'A 64-bit Windows host is required.' }
 if ($env:OS -ne 'Windows_NT') { throw 'Use go.sh on Linux.' }
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

$script:GoVersionSpecified=$PSBoundParameters.ContainsKey('GoVersion')
function EnvMap {
 [ordered]@{
  'GIT_CONFIG_COUNT'='1'; 'GIT_CONFIG_KEY_0'='safe.directory'; 'GIT_CONFIG_VALUE_0'='*'
  'GOROOT'=(Join-Path $Root 'go\sdk'); 'GOPATH'=(Join-Path $Root 'go\path'); 'GOMODCACHE'=(Join-Path $Root 'go\path\pkg\mod')
  'GOCACHE'=(Join-Path $Root 'go\cache'); 'GOENV'=(Join-Path $Root 'go\goenv'); 'GOTOOLCHAIN'='local'
 }
}
function EnvPaths { @('go\sdk\bin') | ForEach-Object { Join-Path $Root $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Container } }
function Activate {
 $map=EnvMap
 foreach ($key in $map.Keys) { [Environment]::SetEnvironmentVariable($key,$map[$key],'Process') }
 Remove-Item Env:UV_MANAGED_PYTHON -ErrorAction SilentlyContinue
 $paths=@(EnvPaths)
 if ($paths.Count -gt 0) { $env:Path=($paths -join ';')+';'+$env:Path }
}
function Install {
 $out=Join-Path $Root 'go\sdk'
 if (Test-Path (Join-Path $out 'bin\go.exe')) { Log 'Go already present'; return }
 $releases=@(Invoke-RestMethod -Uri 'https://go.dev/dl/?mode=json&include=all' | ForEach-Object { $_ })
 $release=$releases | Where-Object { $_.version -eq "go$GoVersion" } | Select-Object -First 1
 if (-not $release) { throw "Go $GoVersion not found" }
 $pkg=$release.files | Where-Object { $_.os -eq 'windows' -and $_.arch -eq 'amd64' -and $_.kind -eq 'archive' -and $_.filename -like '*.zip' } | Select-Object -First 1
 if (-not $pkg) { throw 'Go Windows x64 zip not found' }
 $file=Join-Path $State $pkg.filename
 Download "https://go.dev/dl/$($pkg.filename)" $file; CheckSha $file $pkg.sha256
 Unpack $file $out; Remove-Item $file -Force
}
function Verify { & (Join-Path $Root 'go\sdk\bin\go.exe') version; AssertExit 'Go verification failed' }
function Update {
 $sdk=Join-Path $Root 'go\sdk'; $exe=Join-Path $sdk 'bin\go.exe'
 if (-not (Test-Path $exe)) { throw 'Install Go first' }
 if (-not $script:GoVersionSpecified) {
  $releases=@(Invoke-RestMethod -Uri 'https://go.dev/dl/?mode=json' | ForEach-Object { $_ })
  $script:GoVersion=[string]$releases[0].version -replace '^go',''
 }
 if ((& $exe version) -match ('go'+[regex]::Escape($GoVersion)+'\s')) { Log 'Go already current'; return }
 $backup=Join-Path $State 'update-backup-go'
 if (Test-Path $backup) { throw "Incomplete previous update: $backup" }
 EnsureDir $State
 Move-Item -LiteralPath $sdk -Destination $backup
 try { Install; RemoveTree $backup }
 catch { RemoveTree $sdk; Move-Item -LiteralPath $backup -Destination $sdk; throw }
}
function Prime([bool]$Offline) {
 if (-not (Test-Path (Join-Path $Root 'go\sdk\bin\go.exe'))) { throw 'Go missing' }
 Push-Location $Project
 try {
  if (-not (Test-Path go.mod)) { throw 'go.mod missing' }
  if ($Offline) { $env:GOPROXY='off'; $env:GOSUMDB='off' }
  else { & go mod download; AssertExit 'Go module download failed' }
  & go test ('./' + '...'); AssertExit 'Go tests/build failed'
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
    '8' { throw 'No optional features for this language.' }
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
 if ($Feature -ne 'none') { throw "Unsupported feature for ${Lang}: $Feature" }
 $Action=$Mode
}
switch ($Action) {
 install { Install }
 verify { Activate; Verify }
 update { Update }
 prime { Activate; Prime $false }
 'offline-check' { Activate; Prime $true }
 'global-on' { GlobalOn }
 'global-off' { GlobalOff }
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
