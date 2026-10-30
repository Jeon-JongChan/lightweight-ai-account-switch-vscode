#requires -Version 5.1
<# .SYNOPSIS .tools/build.ps1 도구로 전달한다. #>
[CmdletBinding()]
param([ValidateSet('prepare','build','test','package')][string]$Action = 'package', [switch]$Offline)
& (Join-Path $PSScriptRoot '.tools/build.ps1') -Action $Action -Offline:$Offline

