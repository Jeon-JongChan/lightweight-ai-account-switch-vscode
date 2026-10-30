#requires -Version 5.1
<# .SYNOPSIS 제공된 포터블 Node.js 도구로 준비·빌드·검증·패키징을 수행한다. #>
[CmdletBinding()]
param([ValidateSet('prepare','build','test','package')][string]$Action = 'package', [switch]$Offline)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$kit = Join-Path $projectRoot '.tools/.build/nodejs.ps1'
$sdk = Join-Path $projectRoot '.tools/.build/nodejs/node'
$node = Join-Path $sdk 'node.exe'
if (-not (Test-Path -LiteralPath $node)) {
  if ($Action -ne 'prepare' -or $Offline) { throw '먼저 .\build.ps1 prepare를 실행하세요.' }
  & $kit -Action install -Project $projectRoot
}
$modules = Join-Path $projectRoot '.tools/.build/node_modules'
$env:NODE_PATH = $modules
$env:PATH = (Join-Path $modules '.bin') + ';' + $sdk + ';' + $env:PATH
$env:npm_config_cache = Join-Path $projectRoot '.tools/.build/nodejs/npm-cache'
$env:npm_config_update_notifier = 'false'
$snapshot = Join-Path $projectRoot '.tools/.build/dependencies.sha256'
$lock = Join-Path $projectRoot 'package-lock.json'
$hash = (Get-FileHash -LiteralPath $lock -Algorithm SHA256).Hash
Push-Location $projectRoot
try {
  if ($Action -eq 'prepare') {
    # 기존 라이브러리는 이동·삭제하지 않아 Windows 파일 잠금과 사용자 파일 손실을 피한다.
    if (-not (Test-Path -LiteralPath $modules)) {
      $arguments = @('ci', '--ignore-scripts', '--no-audit', '--no-fund', '--loglevel=error')
      if ($Offline) { $arguments += '--offline' }
      & (Join-Path $sdk 'npm.cmd') @arguments
      if ($LASTEXITCODE) { throw '빌드 의존성 준비 실패' }
      $rootModules = Join-Path $projectRoot 'node_modules'
      if (Test-Path -LiteralPath $rootModules) {
        Move-Item -LiteralPath $rootModules -Destination $modules -Force
      }
    }
    & $node -e "require.resolve('typescript', { paths: [process.env.NODE_PATH] }); require.resolve('@vscode/vsce/vsce', { paths: [process.env.NODE_PATH] })"
    if ($LASTEXITCODE) { throw '기존 node_modules가 불완전합니다. 파일을 보존하고 의존성을 복구하세요.' }
    Set-Content -LiteralPath $snapshot -Value $hash -Encoding ASCII
    Write-Host '포터블 빌드 준비 완료. 이후 build/test/package는 다운로드 없이 실행됩니다.'
  } else {
    if (-not (Test-Path -LiteralPath $snapshot) -or (Get-Content -LiteralPath $snapshot -Raw).Trim() -ne $hash) {
      throw '잠금 파일에 맞는 .\build.ps1 prepare가 필요합니다.'
    }
    & (Join-Path $sdk 'npm.cmd') run $Action --silent
    if ($LASTEXITCODE) { throw "$Action 실패 (exit $LASTEXITCODE)" }
  }
} finally { Pop-Location }
