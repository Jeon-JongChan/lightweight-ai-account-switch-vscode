#requires -Version 5.1
<#
.SYNOPSIS
 검증용 인메모리 Kafka (franz-go kfake). .build 포터블 Go 로 빌드한 뒤 127.0.0.1:19092 에 띄운다.
.NOTES
 이 파일은 UTF-8 BOM으로 저장해야 합니다. Windows PowerShell 5.1은 BOM이 없으면 한글을 CP949로 읽어 깨뜨립니다.
.EXAMPLE
 .\.build\kfake.ps1
 다른 창(프로젝트 루트): go run . --brokers 127.0.0.1:19092 --listen 127.0.0.1:8089
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$activate = Join-Path $PSScriptRoot 'activate.ps1'
if (Test-Path -LiteralPath $activate) { . $activate }
elseif (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'go.ps1')) { . (Join-Path $PSScriptRoot 'go.ps1') -Action env }
else { throw ".build\activate.ps1 또는 go.ps1 이 없습니다. 먼저 .\.build\go.ps1 -Action install" }
$dir = Join-Path $PSScriptRoot 'kfake'
if (-not (Test-Path -LiteralPath $dir)) { $dir = Join-Path $PSScriptRoot 'kfake(go프로젝트 귀속)' }
Push-Location $dir
try {
	& go build -o kfake.exe .
	if ($LASTEXITCODE) { throw "kfake 빌드 실패 (exit $LASTEXITCODE)" }
} finally { Pop-Location }
& (Join-Path $dir 'kfake.exe')
