param(
    [string]$Godot = 'D:\codex\tools\godot\Godot_v4.5.2-stable_win64_console.exe',
    [string]$Template = 'D:\codex\tools\godot\windows_release_x86_64.exe'
)
$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
if (-not (Test-Path -LiteralPath $Godot)) { throw 'Godot 4.5.2 executable not found.' }
if (-not (Test-Path -LiteralPath $Template)) { throw 'Godot 4.5.2 Windows release template not found.' }
New-Item -ItemType Directory -Force -Path (Join-Path $projectRoot 'build') | Out-Null
$presetPath = Join-Path $projectRoot 'export_presets.cfg'
$presetText = Get-Content -LiteralPath $presetPath -Raw
$templatePath = $Template.Replace('\','/')
$presetText = $presetText -replace 'custom_template/release="[^"]*"', ('custom_template/release="' + $templatePath + '"')
Set-Content -LiteralPath $presetPath -Value $presetText -Encoding utf8
& $Godot --headless --path $projectRoot --script res://tests/test_simulation.gd
if ($LASTEXITCODE -ne 0) { throw 'Simulation tests failed.' }
& $Godot --headless --path $projectRoot --export-release 'Windows Desktop' (Join-Path $projectRoot 'build\LastCore.exe')
if ($LASTEXITCODE -ne 0) { throw 'Export failed.' }
Write-Host 'Windows build ready:' (Join-Path $projectRoot 'build\LastCore.exe')
