#requires -Version 5.1
<#
Kotlin / Android (JDK + Android SDK) - 독립 실행 스크립트 (Windows x64, PowerShell 5.1+, Facade 4-액션 내장).
이 파일 하나만 프로젝트에 복사해도 설치·환경설정(검증/세션/전역/prime/offline-check/emulator)·최신화·초기화가 모두 동작한다.
  대화형 메뉴: .\kotlin.ps1
  비대화형:    .\kotlin.ps1 -Action install | configure -Mode verify|env|global-on|global-off|prime|offline-check|list|run | update | reset -Yes
  세션 적용:   . .\kotlin.ps1 -Action env   (dot-source)
#>
[CmdletBinding()]
param(
 [ValidateSet('menu','install','configure','verify','update','reset','prime','offline-check','env','global-on','global-off','remove','list','run','emulator-install','emulator-list','emulator-start','emulator-remove')][string]$Action='menu',
 [ValidateSet('verify','env','global-on','global-off','prime','offline-check','list','run')][string]$Mode='verify',
 [ValidateSet('none','emulator','tauri','vue')][string]$Feature='none',
 [ValidateSet('','install','verify','prime','offline-check','list','start','remove','init')][string]$Operation='',
 [ValidateSet('all','env','tools')][string]$Scope='all',
 [string]$Project='', [string]$Task='assembleDebug',
 [int]$AndroidApi=36, [string]$BuildTools='36.0.0', [string]$NdkVersion='27.2.12479018',
 [switch]$WithNdk, [switch]$WithAdb, [switch]$AcceptAndroidLicenses, [int]$JdkMajor=21,
 [ValidateSet('x86_64','arm64-v8a')][string]$EmulatorAbi='x86_64',
 [ValidateSet('default','google_apis')][string]$EmulatorFlavor='google_apis',
 [ValidatePattern('^[A-Za-z][A-Za-z0-9_.-]{0,63}$')][string]$AvdName='pbk_android',
 [switch]$Headless, [switch]$PurgeEmulatorPackages,
 [switch]$Yes, [string[]]$CommandArgs=@()
)
$Lang='kotlin'
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
 if ($env:OS -ne 'Windows_NT') { throw 'Use kotlin.sh on Linux.' }
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
function GradleProjectCache { return (Join-Path $Root ("kotlin\project-caches\"+(ProjectKey))) }

function EnvMap {
 $e=[ordered]@{
  'GIT_CONFIG_COUNT'='1'; 'GIT_CONFIG_KEY_0'='safe.directory'; 'GIT_CONFIG_VALUE_0'='*'
  'JAVA_HOME'=(Join-Path $Root 'kotlin\jdk'); 'ANDROID_HOME'=(Join-Path $Root 'kotlin\android-sdk'); 'ANDROID_SDK_ROOT'=(Join-Path $Root 'kotlin\android-sdk')
  'GRADLE_USER_HOME'=(Join-Path $Root 'kotlin\gradle'); 'ANDROID_USER_HOME'=(Join-Path $Root 'kotlin\android-user'); 'ANDROID_PREFS_ROOT'=(Join-Path $Root 'kotlin\android-user')
  'ANDROID_EMULATOR_HOME'=(Join-Path $Root 'kotlin\android-user'); 'ANDROID_AVD_HOME'=(Join-Path $Root 'kotlin\android-user\avd')
 }
 $ndk=Join-Path $Root 'kotlin\android-sdk\ndk'
 if (Test-Path $ndk) {
  $dir=Get-ChildItem -LiteralPath $ndk -Directory | Select-Object -First 1
  if ($null -ne $dir) { $e['NDK_HOME']=$dir.FullName; $e['ANDROID_NDK_HOME']=$dir.FullName }
 }
 return $e
}
function EnvPaths {
 @('kotlin\jdk\bin','kotlin\android-sdk\cmdline-tools\latest\bin','kotlin\android-sdk\platform-tools','kotlin\android-sdk\emulator') |
  ForEach-Object { Join-Path $Root $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
}
function Activate {
 $map=EnvMap
 foreach ($key in $map.Keys) { [Environment]::SetEnvironmentVariable($key,$map[$key],'Process') }
 Remove-Item Env:UV_MANAGED_PYTHON -ErrorAction SilentlyContinue
 $paths=@(EnvPaths)
 if ($paths.Count -gt 0) { $env:Path=($paths -join ';')+';'+$env:Path }
}
function Install {
 $jdk=Join-Path $Root 'kotlin\jdk'
 $sdk=Join-Path $Root 'kotlin\android-sdk'
 if (-not (Test-Path (Join-Path $jdk 'bin\java.exe'))) {
  $api="https://api.adoptium.net/v3/assets/latest/$JdkMajor/hotspot?architecture=x64&image_type=jdk&os=windows&vendor=eclipse"
  $release=@(Invoke-RestMethod -Uri $api | ForEach-Object { $_ })[0]
  if (-not $release.binary.package.link -or -not $release.binary.package.checksum) { throw 'Temurin JDK metadata unavailable' }
  $file=Join-Path $State 'temurin.zip'
  Download $release.binary.package.link $file
  CheckSha $file $release.binary.package.checksum
  Unpack $file $jdk; Remove-Item $file -Force
 }
 $mgr=Join-Path $sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
 if (-not (Test-Path $mgr)) {
  $file=Join-Path $State 'android-cli.zip'
  Download 'https://dl.google.com/android/repository/commandlinetools-win-15859902_latest.zip' $file
  CheckSha $file '90ae805d20434428bffcb699c290860f19bb5f66a67e6b330067e3de801fb04a'
  Unpack $file (Join-Path $sdk 'cmdline-tools\latest'); Remove-Item $file -Force
 }
 Activate
 if ($AcceptAndroidLicenses) {
  EnsureDir $State
  $answers=Join-Path $State 'android-licenses.txt'
  Set-Content -LiteralPath $answers -Value (@('y') * 80) -Encoding ASCII
  $licCmd = "`"$mgr`" --sdk_root=`"$sdk`" --licenses < `"$answers`""
  cmd.exe /c $licCmd | Out-Null
  AssertExit 'Android SDK license acceptance failed'
  Remove-Item $answers -Force
 } else { Log 'Android SDK licenses not auto-accepted. Rerun with -AcceptAndroidLicenses after reviewing the terms.' }
 $pkgs=@("platforms;android-$AndroidApi","build-tools;$BuildTools")
 if ($WithAdb) { $pkgs+= 'platform-tools' }
 if ($WithNdk) { $pkgs+= "ndk;$NdkVersion" }
 & $mgr "--sdk_root=$sdk" --install @pkgs
 AssertExit 'Android SDK package installation failed'
 $plat=Join-Path $sdk "platforms\android-$AndroidApi"
 $bt=Join-Path $sdk "build-tools\$BuildTools"
 if (-not (Test-Path $plat) -or -not (Test-Path $bt)) {
  throw "Android packages missing after install (licenses may be unaccepted). platforms=$plat build-tools=$bt"
 }
 Log "Installed Android API $AndroidApi + Build Tools $BuildTools only (NDK=$WithNdk, ADB=$WithAdb)."
}
function Verify {
 & (Join-Path $Root 'kotlin\jdk\bin\java.exe') -version; AssertExit 'JDK verification failed'
 & (Join-Path $Root 'kotlin\android-sdk\cmdline-tools\latest\bin\sdkmanager.bat') "--sdk_root=$env:ANDROID_HOME" --list_installed
 AssertExit 'Android SDK verification failed'
}
function Update {
 if (-not (Test-Path (Join-Path $Root 'kotlin\android-sdk\cmdline-tools\latest\bin\sdkmanager.bat'))) { throw 'Install Kotlin SDK first' }
 Install
 Log 'Requested Android SDK pins ensured. JDK/CLI upgrades require explicit tested pins.'
}
function Prime([bool]$Offline) {
 Push-Location $Project
 try {
  if (-not (Test-Path gradlew.bat)) { throw 'gradlew.bat missing' }
  $argsList=@($Task,'--no-daemon','--project-cache-dir',(GradleProjectCache))
  if ($Offline) { $argsList+='--offline' }
  & .\gradlew.bat @argsList; AssertExit 'Gradle build failed'
 } finally { Pop-Location }
}
function ValidateEmulatorArgs {
 if ($AvdName -cnotmatch '^[A-Za-z][A-Za-z0-9_.-]{0,63}$') { throw 'Unsafe AVD name' }
 if ($AndroidApi -lt 21 -or $AndroidApi -gt 99) { throw 'Invalid Android API level' }
 if ($EmulatorFlavor -notin @('default','google_apis')) { throw 'Invalid system image flavor' }
 if ($EmulatorAbi -notin @('x86_64','arm64-v8a')) { throw 'Invalid emulator ABI' }
}
function AndroidImagePackage { ValidateEmulatorArgs; return "system-images;android-$AndroidApi;$EmulatorFlavor;$EmulatorAbi" }
function AndroidEmulatorReady {
 $sdk=Join-Path $Root 'kotlin\android-sdk'
 if (-not (Test-Path (Join-Path $sdk 'cmdline-tools\latest\bin\avdmanager.bat'))) { throw 'Android tools absent: install Kotlin first' }
 Activate
 EnsureDir $env:ANDROID_AVD_HOME; EnsureDir $env:ANDROID_EMULATOR_HOME
 $ini=Join-Path $env:ANDROID_AVD_HOME "$AvdName.ini"
 $avdDir=Join-Path $env:ANDROID_AVD_HOME "$AvdName.avd"
 if ((Test-Path -LiteralPath $ini) -and (Test-Path -LiteralPath $avdDir)) {
  $raw=Get-Content -Raw -LiteralPath $ini
  $updated=$raw -replace '(?m)^path=.*$',("path=" + $avdDir)
  if ($updated -ne $raw) { Set-Content -LiteralPath $ini -Value $updated -Encoding UTF8 -NoNewline }
 }
}
function EmulatorInstall {
 ValidateEmulatorArgs
 Install
 AndroidEmulatorReady
 $sdk=Join-Path $Root 'kotlin\android-sdk'
 $mgr=Join-Path $sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
 $avd=Join-Path $sdk 'cmdline-tools\latest\bin\avdmanager.bat'
 $package=AndroidImagePackage
 & $mgr "--sdk_root=$sdk" --install 'emulator' 'platform-tools' $package
 AssertExit 'Emulator/system image download failed'
 if (-not (Test-Path (Join-Path $sdk 'emulator\emulator.exe'))) { throw 'Emulator executable missing' }
 if (Test-Path (Join-Path $env:ANDROID_AVD_HOME "$AvdName.ini")) { Log "AVD already present: $AvdName"; return }
 'no' | & $avd create avd -n $AvdName -k $package --force
 AssertExit 'AVD creation failed'
 if (-not (Test-Path (Join-Path $env:ANDROID_AVD_HOME "$AvdName.ini"))) { throw 'AVD created outside portable directory or not created' }
 Log "Emulator ready: $AvdName ($package). Requires usable host virtualization."
}
function EmulatorList {
 ValidateEmulatorArgs
 AndroidEmulatorReady
 & (Join-Path $Root 'kotlin\android-sdk\cmdline-tools\latest\bin\avdmanager.bat') list avd
 AssertExit 'Unable to list AVDs'
}
function EmulatorStart {
 ValidateEmulatorArgs
 AndroidEmulatorReady
 if (-not (Test-Path (Join-Path $env:ANDROID_AVD_HOME "$AvdName.ini"))) { throw "AVD not found: $AvdName" }
 $exe=Join-Path $Root 'kotlin\android-sdk\emulator\emulator.exe'
 if (-not (Test-Path $exe)) { throw 'Install emulator package first' }
 $arguments=@('-avd',$AvdName,'-no-snapshot')
 if ($Headless) { $arguments+=@('-no-window','-no-audio') }
 Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $exe) | Out-Null
 Log "Started AVD $AvdName (host hypervisor support is required)."
}
function EmulatorRemove {
 ValidateEmulatorArgs
 AndroidEmulatorReady
 $sdk=Join-Path $Root 'kotlin\android-sdk'
 $avd=Join-Path $sdk 'cmdline-tools\latest\bin\avdmanager.bat'
 $mgr=Join-Path $sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
 if (Test-Path (Join-Path $env:ANDROID_AVD_HOME "$AvdName.ini")) { & $avd delete avd -n $AvdName; AssertExit 'AVD deletion failed'; Log "Removed AVD $AvdName" }
 else { Log "AVD not found: $AvdName" }
 if ($PurgeEmulatorPackages) {
  if (@(Get-ChildItem -LiteralPath $env:ANDROID_AVD_HOME -Filter '*.ini').Count -gt 0) { throw 'Other AVDs remain; shared emulator and system image not removed' }
  & $mgr "--sdk_root=$sdk" --uninstall (AndroidImagePackage) 'emulator'
  AssertExit 'Emulator SDK package removal failed'
  Log 'Removed selected system image and emulator package; platform-tools retained.'
 }
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
  '1' {
   $script:Action='install'
   if ((Read-Host 'Reviewed/accept Android SDK licenses? (yes/no)') -eq 'yes') { $script:AcceptAndroidLicenses=$true }
  }
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
     $script:Feature='emulator'
     Write-Host 'Emulator: 1 install | 2 list | 3 start | 4 remove | 0 back'
     $v=Read-Host 'Choice'
     $script:Operation=switch ($v) {'1' {'install'} '2' {'list'} '3' {'start'} '4' {'remove'} '0' {exit 0} default {throw 'Invalid emulator option'}}
     if ($Operation -eq 'install') {
      $a=Read-Host "Android API [$AndroidApi]"; if ($a) {$script:AndroidApi=[int]$a}
      if ((Read-Host 'Reviewed/accept SDK licenses? (yes/no)') -eq 'yes') {$script:AcceptAndroidLicenses=$true}
     }
     if ($Operation -in @('install','start','remove')) {
      $a=Read-Host "AVD name [$AvdName]"; if ($a) {$script:AvdName=$a}
     }
     if ($Operation -eq 'start' -and (Read-Host 'Headless? (yes/no)') -eq 'yes') {$script:Headless=$true}
     if ($Operation -eq 'remove' -and (Read-Host 'Remove emulator and image if unused? (yes/no)') -eq 'yes') {$script:PurgeEmulatorPackages=$true}
    }
    '0' { exit 0 }
    default { throw 'Invalid configure choice' }
   }
  }
  '3' {
   $script:Action='update'
   if ((Read-Host 'Reviewed/accept Android SDK licenses? (yes/no)') -eq 'yes') { $script:AcceptAndroidLicenses=$true }
  }
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
 if ($Feature -eq 'emulator') { $Action="emulator-$Operation" }
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
 'emulator-install' { EmulatorInstall }
 'emulator-list' { EmulatorList }
 'emulator-start' { EmulatorStart }
 'emulator-remove' { EmulatorRemove }
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
