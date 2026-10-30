#requires -Version 5.1
<#
Portable Build Kit: Windows x64, PowerShell 5.1+.
Only user-scoped environment is modified on explicit global-on; local install requires no elevation.
#>
[CmdletBinding()]
param(
 [ValidateSet('menu','install','configure','update','reset','verify','prime','offline-check','env','global-on','global-off','remove','list','run','emulator-install','emulator-list','emulator-start','emulator-remove','vue-init','tauri-install','tauri-verify','tauri-prime','tauri-offline-check','tauri-remove')][string]$Action='menu',
 [ValidateSet('all','go','rust','kotlin','csharp','nodejs','python')][string]$Language='all',
 [string]$Project='',
 [int]$AndroidApi=36,
 [string]$BuildTools='36.0.0',
 [string]$NdkVersion='27.2.12479018',
 [switch]$WithNdk,
 [switch]$WithAdb,
 [switch]$AcceptAndroidLicenses,
 [string]$Task='assembleDebug',
 [int]$JdkMajor=21,
 [string]$PythonVersion='3.13',
 [string]$GoVersion='1.27.2',
 [int]$NodeMajor=24,
 [string]$DotnetChannel='10.0',
 [ValidateSet('msvc','gnu')][string]$RustAbi='msvc',
 [ValidateSet('x86_64','arm64-v8a')][string]$EmulatorAbi='x86_64',
 [ValidateSet('default','google_apis')][string]$EmulatorFlavor='google_apis',
 [ValidatePattern('^[A-Za-z][A-Za-z0-9_.-]{0,63}$')][string]$AvdName='pbk_android',
 [switch]$Headless, [switch]$PurgeEmulatorPackages,
 [ValidateSet('verify','env','global-on','global-off','prime','offline-check','list','run')][string]$Mode='verify',
 [ValidateSet('none','emulator','tauri','vue')][string]$Feature='none',
 [ValidateSet('','install','verify','prime','offline-check','list','start','remove','init')][string]$Operation='',
 [ValidateSet('all','env','tools')][string]$Scope='all', [switch]$Yes,
 [string[]]$CommandArgs=@()
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$global:LASTEXITCODE=0
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# PS 5.1 진행률 표시는 Invoke-WebRequest 다운로드를 수십 배 느리게 함
$ProgressPreference='SilentlyContinue'
$script:GoVersionSpecified=$PSBoundParameters.ContainsKey('GoVersion')
$Root=$PSScriptRoot
if (-not $Project) { $Project=Split-Path -Parent $Root }
if (-not (Test-Path -LiteralPath $Project -PathType Container)) { throw "Project directory not found: $Project" }
$Project=(Resolve-Path -LiteralPath $Project).Path
$State=Join-Path $Root '_state'
if (-not [Environment]::Is64BitOperatingSystem) { throw 'A 64-bit Windows host is required.' }
if ($env:OS -ne 'Windows_NT') { throw 'Use setup.sh on Linux.' }
function Log([string]$Message) { Write-Host "[build-kit] $Message" }
function AssertExit([string]$Message) { if ($global:LASTEXITCODE) { throw "$Message (exit $global:LASTEXITCODE)" } }
function EnsureDir([string]$Path) {
 if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
 $probe=Join-Path $Path ('.pbk-acl-' + [Guid]::NewGuid().ToString('N'))
 try {
  New-Item -ItemType File -Path $probe -Force -ErrorAction Stop | Out-Null
  Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
 } catch {
  # 다른 PC/계정에서 복사된 NTFS 폴더의 소유권·ACL 불일치 시 현재 사용자 권한 복구
  & takeown.exe /F $Path /R /D Y 2>&1 | Out-Null
  & icacls.exe $Path /grant "${env:USERNAME}:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
  $global:LASTEXITCODE=0
 }
}
function RemoveTree([string]$Path) {
 if (-not (Test-Path -LiteralPath $Path)) { return }
 try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
 catch {
  # Go GOMODCACHE 등의 읽기전용 디렉터리/파일 및 외부 소유권 정리 후 재시도
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
EnsureDir $State
function Download([string]$Url,[string]$Destination) {
 $parent=Split-Path -Parent $Destination
 EnsureDir $parent
 Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -MaximumRedirection 12
 try { Unblock-File -LiteralPath $Destination -ErrorAction SilentlyContinue } catch {}
}
function CheckSha([string]$File,[string]$Expected) {
 if ($Expected -notmatch '^[0-9a-fA-F]{64}$') { throw "Invalid SHA256 for $File" }
 $actual=(Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
 if ($actual -ine $Expected) { throw "SHA256 mismatch for $File" }
}
function Unpack([string]$Archive,[string]$Destination) {
 $staging=Join-Path $State ("extract-" + [Guid]::NewGuid().ToString('N'))
 EnsureDir $staging; EnsureDir $Destination
 try {
  # Windows 내장 bsdtar는 zip도 처리하며 --no-same-owner/--no-same-permissions로 소유권·ACL 복원 오류를 방지
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
function EnvMap {
 $e=[ordered]@{
  'GIT_CONFIG_COUNT'='1'; 'GIT_CONFIG_KEY_0'='safe.directory'; 'GIT_CONFIG_VALUE_0'='*';
  'RUSTUP_HOME'=(Join-Path $Root 'rust\rustup'); 'CARGO_HOME'=(Join-Path $Root 'rust\cargo');
  'GOROOT'=(Join-Path $Root 'go\sdk'); 'GOPATH'=(Join-Path $Root 'go\path'); 'GOMODCACHE'=(Join-Path $Root 'go\path\pkg\mod'); 'GOCACHE'=(Join-Path $Root 'go\cache'); 'GOENV'=(Join-Path $Root 'go\goenv'); 'GOTOOLCHAIN'='local';
  'DOTNET_ROOT'=(Join-Path $Root 'csharp\dotnet'); 'DOTNET_CLI_HOME'=(Join-Path $Root 'csharp\home'); 'NUGET_PACKAGES'=(Join-Path $Root 'csharp\nuget'); 'DOTNET_MULTILEVEL_LOOKUP'='0'; 'DOTNET_CLI_TELEMETRY_OPTOUT'='1'; 'DOTNET_NOLOGO'='1'; 'DOTNET_SYSTEM_GLOBALIZATION_INVARIANT'='1';
  'JAVA_HOME'=(Join-Path $Root 'kotlin\jdk'); 'ANDROID_HOME'=(Join-Path $Root 'kotlin\android-sdk'); 'ANDROID_SDK_ROOT'=(Join-Path $Root 'kotlin\android-sdk'); 'GRADLE_USER_HOME'=(Join-Path $Root 'kotlin\gradle'); 'ANDROID_USER_HOME'=(Join-Path $Root 'kotlin\android-user'); 'ANDROID_PREFS_ROOT'=(Join-Path $Root 'kotlin\android-user'); 'ANDROID_EMULATOR_HOME'=(Join-Path $Root 'kotlin\android-user'); 'ANDROID_AVD_HOME'=(Join-Path $Root 'kotlin\android-user\avd');
  # ponytail: UV_MANAGED_PYTHON conflicts with UV_PYTHON_PREFERENCE on uv>=0.13
  'UV_CACHE_DIR'=(Join-Path $Root 'python\cache'); 'UV_PYTHON_INSTALL_DIR'=(Join-Path $Root 'python\runtimes'); 'UV_PYTHON_BIN_DIR'=(Join-Path $Root 'python\bin'); 'UV_PYTHON_PREFERENCE'='only-managed'; 'UV_LINK_MODE'='copy'; 'UV_TOOL_DIR'=(Join-Path $Root 'python\tools'); 'UV_TOOL_BIN_DIR'=(Join-Path $Root 'python\bin'); 'PIP_CACHE_DIR'=(Join-Path $Root 'python\pip-cache'); 'PYTHONNOUSERSITE'='1';
  'npm_config_cache'=(Join-Path $Root 'nodejs\npm-cache'); 'npm_config_prefix'=(Join-Path $Root 'nodejs\npm-global'); 'npm_config_userconfig'=(Join-Path $Root 'nodejs\npmrc'); 'COREPACK_HOME'=(Join-Path $Root 'nodejs\corepack'); 'npm_config_update_notifier'='false'; 'npm_config_unsafe_perm'='true'
 }
 $ndk=Join-Path $Root 'kotlin\android-sdk\ndk'
 if (Test-Path $ndk) {
  $dir=Get-ChildItem -LiteralPath $ndk -Directory | Select-Object -First 1
  if ($null -ne $dir) { $e['NDK_HOME']=$dir.FullName; $e['ANDROID_NDK_HOME']=$dir.FullName }
 }
 return $e
}
function EnvPaths {
 $list=[System.Collections.Generic.List[string]]::new()
 foreach ($rel in @('go\sdk\bin','rust\cargo\bin','csharp\dotnet','kotlin\jdk\bin','kotlin\android-sdk\cmdline-tools\latest\bin','kotlin\android-sdk\platform-tools','kotlin\android-sdk\emulator','nodejs\node')) {
  $p=Join-Path $Root $rel
  if (Test-Path -LiteralPath $p -PathType Container) { $list.Add($p) }
 }
 # PSF 서명된 실제 CPython 런타임을 python\bin 트램펄린보다 먼저 배치해 WDAC(4551) 및 폴더 이동 시 경로 깨짐 방지
 $pyRuntimes=Join-Path $Root 'python\runtimes'
 if (Test-Path -LiteralPath $pyRuntimes -PathType Container) {
  foreach ($rt in (Get-ChildItem -LiteralPath $pyRuntimes -Directory -ErrorAction SilentlyContinue)) {
   if (Test-Path -LiteralPath (Join-Path $rt.FullName 'python.exe')) {
    $list.Add($rt.FullName)
    $sc=Join-Path $rt.FullName 'Scripts'
    if (Test-Path -LiteralPath $sc -PathType Container) { $list.Add($sc) }
   }
  }
 }
 $pyBin=Join-Path $Root 'python\bin'
 if (Test-Path -LiteralPath $pyBin -PathType Container) { $list.Add($pyBin) }
 return $list
}
function Activate {
 $map=EnvMap
 foreach ($key in $map.Keys) { [Environment]::SetEnvironmentVariable($key,$map[$key],'Process') }
 # Clear obsolete uv flag that conflicts with UV_PYTHON_PREFERENCE on uv>=0.13
 Remove-Item Env:UV_MANAGED_PYTHON -ErrorAction SilentlyContinue
 $paths=@(EnvPaths)
 if ($paths.Count -gt 0) { $env:Path=($paths -join ';')+';'+$env:Path }
}
function WriteActivation {
 $s=@'
# Load into the current PowerShell process with: . .\.build\activate.ps1
$localRoot=$PSScriptRoot
$values=@{
 GIT_CONFIG_COUNT='1'; GIT_CONFIG_KEY_0='safe.directory'; GIT_CONFIG_VALUE_0='*'
 RUSTUP_HOME="$localRoot\rust\rustup"; CARGO_HOME="$localRoot\rust\cargo"
 GOROOT="$localRoot\go\sdk"; GOPATH="$localRoot\go\path"; GOMODCACHE="$localRoot\go\path\pkg\mod"; GOCACHE="$localRoot\go\cache"; GOENV="$localRoot\go\goenv"; GOTOOLCHAIN='local'
 DOTNET_ROOT="$localRoot\csharp\dotnet"; DOTNET_CLI_HOME="$localRoot\csharp\home"; NUGET_PACKAGES="$localRoot\csharp\nuget"; DOTNET_MULTILEVEL_LOOKUP='0'; DOTNET_CLI_TELEMETRY_OPTOUT='1'; DOTNET_NOLOGO='1'; DOTNET_SYSTEM_GLOBALIZATION_INVARIANT='1'
 JAVA_HOME="$localRoot\kotlin\jdk"; ANDROID_HOME="$localRoot\kotlin\android-sdk"; ANDROID_SDK_ROOT="$localRoot\kotlin\android-sdk"; GRADLE_USER_HOME="$localRoot\kotlin\gradle"; ANDROID_USER_HOME="$localRoot\kotlin\android-user"; ANDROID_PREFS_ROOT="$localRoot\kotlin\android-user"; ANDROID_EMULATOR_HOME="$localRoot\kotlin\android-user"; ANDROID_AVD_HOME="$localRoot\kotlin\android-user\avd"
 UV_CACHE_DIR="$localRoot\python\cache"; UV_PYTHON_INSTALL_DIR="$localRoot\python\runtimes"; UV_PYTHON_BIN_DIR="$localRoot\python\bin"; UV_PYTHON_PREFERENCE='only-managed'; UV_LINK_MODE='copy'; UV_TOOL_DIR="$localRoot\python\tools"; UV_TOOL_BIN_DIR="$localRoot\python\bin"; PIP_CACHE_DIR="$localRoot\python\pip-cache"; PYTHONNOUSERSITE='1'
 npm_config_cache="$localRoot\nodejs\npm-cache"; npm_config_prefix="$localRoot\nodejs\npm-global"; npm_config_userconfig="$localRoot\nodejs\npmrc"; COREPACK_HOME="$localRoot\nodejs\corepack"; npm_config_update_notifier="false"; npm_config_unsafe_perm="true"
}
$ndkRoot="$localRoot\kotlin\android-sdk\ndk"
if (Test-Path $ndkRoot) {
 $ndk=Get-ChildItem $ndkRoot -Directory | Select-Object -First 1
 if ($ndk) { $values.NDK_HOME=$ndk.FullName; $values.ANDROID_NDK_HOME=$ndk.FullName }
}
foreach ($key in $values.Keys) { [Environment]::SetEnvironmentVariable($key,$values[$key],'Process') }
Remove-Item Env:UV_MANAGED_PYTHON -ErrorAction SilentlyContinue
$bins=[System.Collections.Generic.List[string]]::new()
foreach ($relative in @('go\sdk\bin','rust\cargo\bin','csharp\dotnet','kotlin\jdk\bin','kotlin\android-sdk\cmdline-tools\latest\bin','kotlin\android-sdk\platform-tools','kotlin\android-sdk\emulator','nodejs\node')) {
 $bin=Join-Path $localRoot $relative
 if (Test-Path $bin) { $bins.Add($bin) }
}
$pyRuntimes=Join-Path $localRoot 'python\runtimes'
if (Test-Path $pyRuntimes) {
 foreach ($rt in (Get-ChildItem -LiteralPath $pyRuntimes -Directory -ErrorAction SilentlyContinue)) {
  if (Test-Path (Join-Path $rt.FullName 'python.exe')) {
   $bins.Add($rt.FullName)
   $scripts=Join-Path $rt.FullName 'Scripts'
   if (Test-Path $scripts) { $bins.Add($scripts) }
  }
 }
}
$pyBin=Join-Path $localRoot 'python\bin'
if (Test-Path $pyBin) { $bins.Add($pyBin) }
if ($bins.Count -gt 0) { $env:Path=($bins -join ';')+';'+$env:Path }
Remove-Variable localRoot,values,ndkRoot,ndk,bins,relative,bin,key,pyRuntimes,rt,scripts,pyBin -ErrorAction SilentlyContinue
'@
 Set-Content -LiteralPath (Join-Path $Root 'activate.ps1') -Value $s -Encoding UTF8
}
function InstallGo {
 $out=Join-Path $Root 'go\sdk'
 if (Test-Path (Join-Path $out 'bin\go.exe')) { Log 'Go already present'; return }
 # include=all: 기본 목록은 최신 패치만 담아 고정 버전이 새 패치 출시 즉시 사라짐
 # ForEach-Object 펼침: PS 5.1은 JSON 배열을 단일 객체로 내보내 @()가 [전체배열] 1개로 감싸고, 필터가 항상 최신판을 고름
 $releases=@(Invoke-RestMethod -Uri 'https://go.dev/dl/?mode=json&include=all' | ForEach-Object { $_ })
 $release=$releases | Where-Object { $_.version -eq "go$GoVersion" } | Select-Object -First 1
 if (-not $release) { throw "Go $GoVersion not found" }
 $pkg=$release.files | Where-Object { $_.os -eq 'windows' -and $_.arch -eq 'amd64' -and $_.kind -eq 'archive' -and $_.filename -like '*.zip' } | Select-Object -First 1
 if (-not $pkg) { throw 'Go Windows x64 zip not found' }
 $file=Join-Path $State $pkg.filename
 Download "https://go.dev/dl/$($pkg.filename)" $file; CheckSha $file $pkg.sha256
 Unpack $file $out; Remove-Item $file -Force
}
function HasMsvc {
 <# MSVC 링커 존재 여부. 일반 터미널 PATH에는 link.exe가 없으므로 rustup과 같은 vswhere 탐지도 허용 #>
 if (Get-Command link.exe -ErrorAction SilentlyContinue) { return $true }
 $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
 if (-not (Test-Path -LiteralPath $vswhere)) { return $false }
 return [bool](& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
}
function InstallRust {
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
 Log 'Rust installed. Windows MSVC linker/SDK is a separate host prerequisite for native Rust/Tauri linking.'
}
function InstallCsharp {
 $dotnet=Join-Path $Root 'csharp\dotnet\dotnet.exe'
 if (Test-Path $dotnet) { Log '.NET already present'; return }
 $installer=Join-Path $State 'dotnet-install.ps1'
 Download 'https://dot.net/v1/dotnet-install.ps1' $installer
 $dest=Join-Path $Root 'csharp\dotnet'
 & $installer -Channel $DotnetChannel -InstallDir $dest -NoPath
 if (-not (Test-Path $dotnet)) { throw '.NET installation did not produce dotnet.exe' }
}
function InstallNodejs {
 $node=Join-Path $Root 'nodejs\node\node.exe'
 if (Test-Path $node) { Log 'Node.js already present'; return }
 $list=(Invoke-WebRequest -Uri "https://nodejs.org/dist/latest-v$NodeMajor.x/SHASUMS256.txt" -UseBasicParsing).Content
 $pattern="(?m)^([0-9a-fA-F]{64})\s+(node-v$NodeMajor\.[0-9]+\.[0-9]+-win-x64\.zip)\s*$"
 $match=[regex]::Match($list,$pattern)
 if (-not $match.Success) { throw "Node.js $NodeMajor LTS Windows archive not found" }
 $filename=$match.Groups[2].Value
 $file=Join-Path $State $filename
 Download "https://nodejs.org/dist/latest-v$NodeMajor.x/$filename" $file
 CheckSha $file $match.Groups[1].Value
 Unpack $file (Join-Path $Root 'nodejs\node'); Remove-Item $file -Force
}
function ResolvePythonExe {
 $pyRuntimes=Join-Path $Root 'python\runtimes'
 if (Test-Path -LiteralPath $pyRuntimes -PathType Container) {
  foreach ($rt in (Get-ChildItem -LiteralPath $pyRuntimes -Directory -ErrorAction SilentlyContinue)) {
   $candidate=Join-Path $rt.FullName 'python.exe'
   if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
 }
 return (Join-Path $Root 'python\bin\python.exe')
}
function InstallPython {
 $uv=Join-Path $Root 'python\bin\uv.exe'
 if (-not (Test-Path $uv)) {
  EnsureDir (Join-Path $Root 'python\bin')
  $installer=Join-Path $State 'uv-install.ps1'
  Download 'https://astral.sh/uv/install.ps1' $installer
  $env:UV_UNMANAGED_INSTALL=Join-Path $Root 'python\bin'
  $global:LASTEXITCODE=0
  & $installer
  if (-not (Test-Path $uv)) { throw 'uv installation failed' }
 }
 Activate
 & $uv python install $PythonVersion --default
 AssertExit 'Python runtime installation failed'
 Activate
 $py=ResolvePythonExe
 if (-not (Test-Path $py)) { throw 'Portable python.exe missing from .build/python' }
 & $py --version; AssertExit 'Portable Python binary verification failed'
}
function InstallKotlin {
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
  $answers=Join-Path $State 'android-licenses.txt'
  Set-Content -LiteralPath $answers -Value (@('y') * 80) -Encoding ASCII
  # sdkmanager.bat ignores PowerShell pipeline stdin; feed via cmd
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
# Optional Android emulator/AVD manager: no emulator is installed by default.
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
 InstallKotlin
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
 $ini=Join-Path $env:ANDROID_AVD_HOME "$AvdName.ini"
 if (Test-Path $ini) { & $avd delete avd -n $AvdName; AssertExit 'AVD deletion failed'; Log "Removed AVD $AvdName" }
 else { Log "AVD not found: $AvdName" }
 if ($PurgeEmulatorPackages) {
  if (@(Get-ChildItem -LiteralPath $env:ANDROID_AVD_HOME -Filter '*.ini').Count -gt 0) { throw 'Other AVDs remain; shared emulator and system image not removed' }
  & $mgr "--sdk_root=$sdk" --uninstall (AndroidImagePackage) 'emulator'
  AssertExit 'Emulator SDK package removal failed'
  Log 'Removed selected system image and emulator package; platform-tools retained.'
 }
}
function ProjectRef {
 $base=(Split-Path -Parent $Root).TrimEnd('\')
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
function GradleProjectCache { return (Join-Path $Root ("kotlin\project-caches\"+(ProjectKey))) }
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
  elseif ($ref -eq '.') { $script:Project=(Split-Path -Parent $Root) }
  else { $script:Project=Join-Path (Split-Path -Parent $Root) $ref }
  try { if (Get-Item -LiteralPath (NodeLink) -Force -ErrorAction SilentlyContinue) { RemoveNodeLink $store.FullName } }
  finally { $script:Project=$oldProject }
 }
}
function InstallTauri {
 InstallRust; InstallNodejs
 if ($RustAbi -ne 'msvc') { throw 'Windows Tauri requires Rust MSVC; choose -RustAbi msvc and host MSVC Build Tools' }
 if ($WithNdk) {
  InstallKotlin; Activate
  & (Join-Path $Root 'rust\cargo\bin\rustup.exe') target add aarch64-linux-android
  AssertExit 'Cannot add Android Rust target'
 }
 New-Item -ItemType Directory -Path (Join-Path $Root 'rust\tauri') -Force | Out-Null
 Set-Content -LiteralPath (Join-Path $Root 'rust\tauri\README.txt') -Value 'Optional Tauri 2 uses shared Rust and portable Node.js; app dependencies are project-specific.' -Encoding UTF8
 Log 'Tauri requires host MSVC/Windows SDK and WebView2; check -Action tauri-verify.'
}
function VerifyTauri {
 VerifyOne rust; VerifyOne nodejs
 if (-not (HasMsvc)) { throw 'Missing host MSVC C++ Build Tools (link.exe)' }
 Log 'MSVC linker found; Windows SDK/WebView2 packaging require real build verification.'
}
function PrimeTauri([bool]$Offline) {
 if (-not (Test-Path (Join-Path $Project 'src-tauri\Cargo.toml'))) { throw 'src-tauri/Cargo.toml missing' }
 PrepareNodeDependencies $Offline
 Push-Location $Project
 try { & npm.cmd run build --if-present; AssertExit 'Frontend build failed' }
 finally { Pop-Location }
 Push-Location (Join-Path $Project 'src-tauri')
 try {
  $env:CARGO_TARGET_DIR=RustTargetDir
  if ($Offline) { & cargo build --offline }
  else { & cargo fetch; AssertExit 'Tauri cargo fetch failed'; & cargo build }
  AssertExit 'Tauri native core build failed'
 } finally { Pop-Location }
}
function VueInit {
 InstallNodejs; Activate
 if (@(Get-ChildItem -LiteralPath $Project -Force).Count -gt 0) { throw "Vue target must be an empty directory: $Project" }
 Push-Location $Project
 try { & npm.cmd create vue@latest '--' '--typescript' '.'; AssertExit 'Vue scaffold failed' }
 finally { Pop-Location }
 Log 'Vue files generated. Run nodejs prime to install/capture dependencies.'
}
function InstallOne([string]$L) {
 switch ($L) { go {InstallGo} rust {InstallRust} kotlin {InstallKotlin} csharp {InstallCsharp} nodejs {InstallNodejs} python {InstallPython} }
}
function ListLanguages { if ($Language -eq 'all') { @('go','rust','kotlin','csharp','python') } else { @($Language) } }
function VerifyOne([string]$L) {
 switch ($L) {
  go { & (Join-Path $Root 'go\sdk\bin\go.exe') version; AssertExit 'Go verification failed' }
  rust { & (Join-Path $Root 'rust\cargo\bin\rustc.exe') --version; AssertExit 'Rust verification failed' }
  kotlin {
   & (Join-Path $Root 'kotlin\jdk\bin\java.exe') -version; AssertExit 'JDK verification failed'
   & (Join-Path $Root 'kotlin\android-sdk\cmdline-tools\latest\bin\sdkmanager.bat') "--sdk_root=$env:ANDROID_HOME" --list_installed
   AssertExit 'Android SDK verification failed'
  }
  csharp { & (Join-Path $Root 'csharp\dotnet\dotnet.exe') --version; AssertExit '.NET verification failed' }
  nodejs { & (Join-Path $Root 'nodejs\node\node.exe') --version; AssertExit 'Node verification failed'; & (Join-Path $Root 'nodejs\node\npm.cmd') --version; AssertExit 'npm verification failed' }
  python { & (Join-Path $Root 'python\bin\uv.exe') python list --only-installed; AssertExit 'uv Python verification failed'; & (ResolvePythonExe) --version; AssertExit 'Python verification failed' }
 }
}
function PythonEnvDir { return (Join-Path $Root ("python\envs\"+(ProjectKey))) }
function PrimeOne([string]$L,[bool]$Offline) {
 Push-Location $Project
 try {
  switch ($L) {
   go {
    if (-not (Test-Path go.mod)) { throw 'go.mod missing' }
    if ($Offline) { $env:GOPROXY='off'; $env:GOSUMDB='off' }
    else { & go mod download; AssertExit 'Go module download failed' }
    & go test ./...; AssertExit 'Go tests/build failed'
   }
   rust {
    if (-not (Test-Path Cargo.toml)) { throw 'Cargo.toml missing' }
    $env:CARGO_TARGET_DIR=RustTargetDir
    if ($Offline) { & cargo build --offline }
    else { & cargo fetch; AssertExit 'Cargo fetch failed'; & cargo build }
    AssertExit 'Rust build failed'
   }
   kotlin {
    if (-not (Test-Path gradlew.bat)) { throw 'gradlew.bat missing' }
    $argsList=@($Task,'--no-daemon','--project-cache-dir',(GradleProjectCache))
    if ($Offline) { $argsList+='--offline' }
    & .\gradlew.bat @argsList; AssertExit 'Gradle build failed'
   }
   csharp {
    if (-not $Offline) { & dotnet restore; AssertExit 'NuGet restore failed' }
    & dotnet build --no-restore; AssertExit '.NET build failed'
   }
   nodejs {
    PrepareNodeDependencies $Offline
    & npm.cmd run build --if-present; AssertExit 'Frontend build failed'
   }
   python {
    $env:UV_PROJECT_ENVIRONMENT=PythonEnvDir
    if ($Offline) { $env:UV_OFFLINE='1' }
    if (Test-Path uv.lock) { & uv sync --locked }
    elseif (Test-Path pyproject.toml) { & uv sync }
    elseif (Test-Path requirements.txt) {
     & uv venv --python $PythonVersion --allow-existing $env:UV_PROJECT_ENVIRONMENT
     AssertExit 'Python virtualenv creation failed'
     & uv pip install --python (Join-Path $env:UV_PROJECT_ENVIRONMENT 'Scripts\python.exe') -r requirements.txt
    } else { throw 'uv.lock / pyproject.toml / requirements.txt missing' }
    AssertExit 'Python dependencies failed'
   }
  }
 } finally { Pop-Location }
}
# ponytail: SetEnvironmentVariable(User) broadcasts WM_SETTINGCHANGE and can hang for minutes; write HKCU\Environment instead.
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
 # 원본 %VAR% 보존: Get-ItemProperty는 REG_EXPAND_SZ를 확장해 복원 시 사용자 Path가 변형됨
 return (Get-Item -LiteralPath 'HKCU:\Environment').GetValue($Name,$null,'DoNotExpandEnvironmentNames')
}
function GlobalOn {
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
 Log 'User-level environment recorded and applied (HKCU). New processes see it; restart terminals if needed.'
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
function ChooseLanguage {
 if ($Language -eq 'all') {
  $value=Read-Host 'Language (go/rust/kotlin/csharp/nodejs/python/all) [all]'
  if ($value) {
   if ($value -notin @('go','rust','kotlin','csharp','nodejs','python','all')) { throw 'Invalid language' }
   $script:Language=$value
  }
 }
}
function InteractiveMenu {
 Write-Host "`n=== Portable Build Kit: $Language ==="
 Write-Host '1. 설치 (Install)'
 Write-Host '2. 환경설정 (Configure)'
 Write-Host '3. 최신화 (Update)'
 Write-Host '4. 초기화 (Reset)'
 Write-Host '0. 종료'
 $choice=Read-Host 'Choice'
 switch ($choice) {
  '1' { $script:Action='install'; ChooseLanguage }
  '2' {
    $script:Action='configure'; ChooseLanguage
    Write-Host 'Configuration: 1 verify | 2 session env | 3 global-on | 4 global-off'
    Write-Host '               5 prime | 6 offline-check | 7 list | 8 optional features | 0 back'
    $choice2=Read-Host 'Choice'
    switch ($choice2) {
     '1' {$script:Mode='verify'} '2' {$script:Mode='env'} '3' {$script:Mode='global-on'}
     '4' {$script:Mode='global-off'} '5' {$script:Mode='prime'}
     '6' {$script:Mode='offline-check'} '7' {$script:Mode='list'}
     '8' { OptionalFeatureMenu }
     '0' { exit 0 }
     default { throw 'Invalid configure choice' }
    }
  }
  '3' { $script:Action='update'; ChooseLanguage }
  '4' {
    $script:Action='reset'; ChooseLanguage
    Write-Host 'Reset: 1 restore env + remove tools | 2 restore env | 3 remove tools | 0 back'
    $choice2=Read-Host 'Choice'
    $script:Scope=switch ($choice2) { '1' {'all'} '2' {'env'} '3' {'tools'} '0' {exit 0} default {throw 'Invalid reset scope'} }
    if ((Read-Host "Type RESET to confirm [$Language/$Scope]") -cne 'RESET') { Log 'Cancelled'; exit 0 }
    $script:Yes=$true
  }
  '0' { exit 0 }
  default { throw 'Invalid menu choice' }
 }
 if ($Action -in @('install','update') -and $Language -in @('kotlin','all')) {
  if ((Read-Host 'Reviewed/accept Android SDK licenses? (yes/no)') -eq 'yes') { $script:AcceptAndroidLicenses=$true }
 }
}
function OptionalFeatureMenu {
 $script:Feature=switch ($Language) {
  kotlin {'emulator'} rust {'tauri'} nodejs {'vue'}
  default {throw 'No optional features for this language. Select Kotlin/Rust/Node.js.'}
 }
 switch ($Feature) {
  emulator {
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
  tauri {
   Write-Host 'Tauri: 1 install | 2 verify | 3 prime | 4 offline-check | 5 remove | 0 back'
   $v=Read-Host 'Choice'
   $script:Operation=switch ($v) {'1' {'install'} '2' {'verify'} '3' {'prime'} '4' {'offline-check'} '5' {'remove'} '0' {exit 0} default {throw 'Invalid Tauri option'}}
  }
  vue {
   Write-Host 'Vue: 1 initialize project (empty folder) | 0 back'
   $v=Read-Host 'Choice'
   $script:Operation=switch ($v) {'1' {'init'} '0' {exit 0} default {throw 'Invalid Vue option'}}
  }
 }
}
function InvokeInstallFacade {
 foreach ($l in (ListLanguages)) { Log "Installing $l"; InstallOne $l }
 WriteActivation
}
function InvokeConfigureFacade {
 if ($Feature -ne 'none') {
  switch ($Feature) {
   emulator {
    if ($Language -ne 'kotlin') { throw 'Emulator requires Kotlin' }
    switch ($Operation) { install {EmulatorInstall} list {EmulatorList} start {EmulatorStart} remove {EmulatorRemove} default {throw 'Invalid emulator operation'} }
   }
   tauri {
    if ($Language -ne 'rust') { throw 'Tauri requires Rust' }
    switch ($Operation) {
     install {InstallTauri} verify {Activate; VerifyTauri}
     prime {Activate; PrimeTauri $false} offline-check {Activate; PrimeTauri $true}
     remove { Remove-Item -LiteralPath (Join-Path $Root 'rust\tauri') -Recurse -Force -ErrorAction SilentlyContinue }
     default {throw 'Invalid Tauri operation'}
    }
   }
   vue { if ($Language -ne 'nodejs' -or $Operation -ne 'init') {throw 'Vue requires Node.js/init'}; VueInit }
   default {throw 'Unknown feature'}
  }
  return
 }
 switch ($Mode) {
  verify {
   Activate; $failures=@()
   foreach ($l in (ListLanguages)) { try { Log "Checking $l"; VerifyOne $l } catch { Write-Warning $_; $failures+=$l } }
   if ($failures.Count) { throw "Verification failed: $($failures -join ', ')" }
  }
  env { Log "In current PowerShell process run: . '$Root\activate.ps1'" }
  'global-on' { GlobalOn }
  'global-off' { GlobalOff }
  prime { if ($Language -eq 'all') {throw 'Specify one language'}; Activate; PrimeOne $Language $false }
  'offline-check' { if ($Language -eq 'all') {throw 'Specify one language'}; Activate; PrimeOne $Language $true }
  list { foreach ($l in @('go','rust','kotlin','csharp','nodejs','python')) { Write-Host ("{0,-8} {1}" -f $l,$(if (Test-Path (Join-Path $Root $l)) {'present'} else {'absent'})) } }
  run {
   Activate
   if (-not $CommandArgs.Count) {throw 'Specify -CommandArgs'}
   $exe=$CommandArgs[0]; $arguments=@()
   if ($CommandArgs.Count -gt 1) { $arguments=@($CommandArgs[1..($CommandArgs.Count-1)]) }
   & $exe @arguments; AssertExit 'Command failed'
  }
  default { throw 'Unsupported configure mode' }
 }
}
function InvokeUpdateFacade {
 foreach ($l in (ListLanguages)) {
  Log "Updating $l"
  switch ($l) {
   go {
    $sdk=Join-Path $Root 'go\sdk'; $exe=Join-Path $sdk 'bin\go.exe'
    if (-not (Test-Path $exe)) { throw 'Install Go first' }
    if (-not $script:GoVersionSpecified) {
     $releases=@(Invoke-RestMethod -Uri 'https://go.dev/dl/?mode=json' | ForEach-Object { $_ })
     $script:GoVersion=[string]$releases[0].version -replace '^go',''
    }
    if ((& $exe version) -match ('go'+[regex]::Escape($GoVersion)+'\s')) { Log 'Go already current' }
    else {
     $backup=Join-Path $State 'update-backup-go'
     if (Test-Path $backup) { throw "Incomplete previous update: $backup" }
     Move-Item -LiteralPath $sdk -Destination $backup
     try { InstallGo; RemoveTree $backup }
     catch { RemoveTree $sdk; Move-Item -LiteralPath $backup -Destination $sdk; throw }
    }
   }
   rust {
    if (-not (Test-Path (Join-Path $Root 'rust\cargo\bin\rustup.exe'))) {throw 'Install Rust first'}
    Activate; & rustup set profile minimal; AssertExit 'Rust profile failed'
    & rustup update stable; AssertExit 'Rust update failed'
   }
   csharp {
    if (-not (Test-Path (Join-Path $Root 'csharp\dotnet\dotnet.exe'))) {throw 'Install .NET first'}
    $installer=Join-Path $State 'dotnet-install.ps1'
    Download 'https://dot.net/v1/dotnet-install.ps1' $installer
    $global:LASTEXITCODE=0
    & $installer -Channel $DotnetChannel -InstallDir (Join-Path $Root 'csharp\dotnet') -NoPath
    AssertExit '.NET update failed'
   }
   nodejs {
    $node=Join-Path $Root 'nodejs\node'; $exe=Join-Path $node 'node.exe'
    if (-not (Test-Path $exe)) {throw 'Install Node.js first'}
    $sums=[string](Invoke-WebRequest -Uri "https://nodejs.org/dist/latest-v$NodeMajor.x/SHASUMS256.txt" -UseBasicParsing).Content
    $matched=[regex]::Match($sums,'node-(v[0-9]+\.[0-9]+\.[0-9]+)-win-x64\.zip')
    if (-not $matched.Success) {throw 'Cannot resolve latest Node.js patch'}
    $latest=$matched.Groups[1].Value
    if ((& $exe --version) -eq $latest) {Log "Node.js already at $latest"}
    else {
     $backup=Join-Path $State 'update-backup-nodejs'
     if (Test-Path $backup) {throw "Incomplete previous update: $backup"}
     Move-Item -LiteralPath $node -Destination $backup
     try { InstallNodejs; RemoveTree $backup }
     catch { RemoveTree $node; Move-Item -LiteralPath $backup -Destination $node; throw }
    }
   }
   python {
    if (-not (Test-Path (Join-Path $Root 'python\bin\uv.exe'))) {throw 'Install Python first'}
    $installer=Join-Path $State 'uv-install.ps1'
    Download 'https://astral.sh/uv/install.ps1' $installer
    $env:UV_UNMANAGED_INSTALL=Join-Path $Root 'python\bin'
    $global:LASTEXITCODE=0
    & $installer; AssertExit 'uv refresh failed'
    Activate; & uv python install $PythonVersion --default; AssertExit 'Python refresh failed'
   }
   kotlin {
    if (-not (Test-Path (Join-Path $Root 'kotlin\android-sdk\cmdline-tools\latest\bin\sdkmanager.bat'))) {throw 'Install Kotlin SDK first'}
    InstallKotlin
    Log 'Requested Android SDK pins ensured. JDK/CLI upgrades require explicit tested pins.'
   }
  }
 }
}
function InvokeResetFacade {
 if ($Scope -ne 'env' -and -not $Yes) {throw 'Reset deletes tools; pass -Yes after reviewing scope'}
 switch ($Scope) {
  all { GlobalOff }
  env { GlobalOff; return }
  tools { if (Test-Path (Join-Path $State 'global-windows.json')) {throw 'Restore globals first or use -Scope all'} }
 }
 if ($Language -in @('nodejs','all')) { CleanupNodeLinks }
 $targets=if ($Language -eq 'all') { @('go','rust','kotlin','csharp','python','nodejs') } else { @($Language) }
 foreach ($l in $targets) {
  $dest=Join-Path $Root $l
  if (Test-Path $dest) { RemoveTree $dest }
  Log "Removed $l"
 }
}
WriteActivation
if ($Action -eq 'menu') { InteractiveMenu }
switch ($Action) {
 'install' { InvokeInstallFacade }
 'configure' { InvokeConfigureFacade }
 'update' { InvokeUpdateFacade }
 'reset' { InvokeResetFacade }
 'vue-init' { if ($Language -ne 'nodejs') { throw 'vue-init belongs to nodejs' }; VueInit }
 'tauri-install' { if ($Language -ne 'rust') { throw 'Tauri belongs to rust' }; InstallTauri }
 'tauri-verify' { if ($Language -ne 'rust') { throw 'Tauri belongs to rust' }; Activate; VerifyTauri }
 'tauri-prime' { if ($Language -ne 'rust') { throw 'Tauri belongs to rust' }; Activate; PrimeTauri $false }
 'tauri-offline-check' { if ($Language -ne 'rust') { throw 'Tauri belongs to rust' }; Activate; PrimeTauri $true }
 'tauri-remove' { if ($Language -ne 'rust') { throw 'Tauri belongs to rust' }; RemoveTree (Join-Path $Root 'rust\tauri'); Log 'Removed optional Tauri state, shared dependencies retained' }
 'emulator-install' { EmulatorInstall }
 'emulator-list' { EmulatorList }
 'emulator-start' { EmulatorStart }
 'emulator-remove' { EmulatorRemove }
 verify {
  Activate; $failures=@()
  foreach ($l in (ListLanguages)) { try { Log "Checking $l"; VerifyOne $l } catch { Write-Warning $_; $failures+=$l } }
  if ($failures.Count) { throw "Verification failed: $($failures -join ', ')" }
 }
 prime { if ($Language -eq 'all') { throw 'Prime requires one --language / -Language value' }; Activate; PrimeOne $Language $false }
 'offline-check' { if ($Language -eq 'all') { throw 'Offline-check requires one language' }; Activate; PrimeOne $Language $true }
 env { Log "In current PowerShell process run: . '$Root\activate.ps1'" }
 'global-on' { GlobalOn }
 'global-off' { GlobalOff }
 remove {
  if (Test-Path (Join-Path $State 'global-windows.json')) { throw 'Run global-off before remove' }
  if ($Language -in @('nodejs','all')) { CleanupNodeLinks }
  $targets=if ($Language -eq 'all') { @('go','rust','kotlin','csharp','python','nodejs') } else { @( $Language ) }
  foreach ($l in $targets) { $dest=Join-Path $Root $l; if (Test-Path $dest) { RemoveTree $dest }; Log "Removed $l" }
 }
 list {
  foreach ($l in @('go','rust','kotlin','csharp','nodejs','python')) { $present=Test-Path (Join-Path $Root $l); Write-Host ("{0,-8} {1}" -f $l,$(if ($present) {'present'} else {'absent'})) }
 }
 run {
  Activate
  if ($CommandArgs.Count -eq 0) { throw 'Specify -CommandArgs @("go","version")' }
  $exe=$CommandArgs[0]
  $rest=@(); if ($CommandArgs.Count -gt 1) { $rest=$CommandArgs[1..($CommandArgs.Count-1)] }
  & $exe @rest; AssertExit 'Command failed'
 }
 default { throw "Unexpected action: $Action" }
}
