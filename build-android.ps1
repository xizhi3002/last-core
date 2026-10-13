# Android 开发预览构建：先测试，再生成调试签名 APK。
# Java SDK、Android SDK 与调试签名在 Godot 编辑器设置中配置。
param(
    [string]$Godot = 'D:\codex\tools\godot\Godot_v4.5.2-stable_win64_console.exe',
    [string]$Template = 'D:\codex\tools\godot\android_debug.apk'
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Godot)) { throw 'Godot executable not found.' }
if (-not (Test-Path -LiteralPath $Template)) { throw 'Android debug export template not found.' }
$root = $PSScriptRoot
New-Item -ItemType Directory -Force -Path (Join-Path $root 'build') | Out-Null
$preset = Join-Path $root 'export_presets.cfg'
$config = Get-Content -LiteralPath $preset -Raw
$config = $config -replace 'custom_template/debug="[^"]*"', ('custom_template/debug="' + $Template.Replace('\','/') + '"')
Set-Content -LiteralPath $preset -Value $config -Encoding utf8 -NoNewline
& $Godot --headless --path $root --editor --quit
if ($LASTEXITCODE -ne 0) { throw 'Project import failed.' }
& $Godot --headless --path $root --script res://tests/test_simulation.gd
if ($LASTEXITCODE -ne 0) { throw 'Simulation tests failed.' }
& $Godot --headless --path $root --script res://tests/test_navigation.gd
if ($LASTEXITCODE -ne 0) { throw 'Navigation tests failed.' }
& $Godot --headless --path $root --script res://tests/test_storage.gd -- --test
if ($LASTEXITCODE -ne 0) { throw 'Storage tests failed.' }
& $Godot --headless --path $root --script res://tests/mobile_smoke.gd -- --mobile --test
if ($LASTEXITCODE -ne 0) { throw 'Mobile tests failed.' }
$apk = Join-Path $root 'build\LastCore-Android.apk'
& $Godot --headless --path $root --export-debug Android $apk
if ($LASTEXITCODE -ne 0) { throw 'Android export failed.' }
Get-FileHash -LiteralPath $apk -Algorithm SHA256
Write-Host 'Android preview ready:' $apk
