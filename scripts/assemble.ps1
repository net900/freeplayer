# Assembles a runnable app folder: the built shell, ffmpeg/ffprobe in tools\,
# and the in-place updater. The source gateway is a separate deployment and
# is deliberately not part of the app. Decryptors are not packaged either:
# each source declares its own and the client downloads it into
# decryptors\<id>\<version>\.
param(
  [string]$BuildDir = 'build\windows\x64\runner\Release',
  [string]$FfmpegDir = ''
)
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path (Join-Path $root 'shell') $BuildDir
$exe = Join-Path $out 'free_player.exe'
if (-not (Test-Path $exe)) {
  throw "No free_player.exe in $out. Build the Windows app first."
}

if (-not $FfmpegDir) {
  $ffmpeg = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
  if (-not $ffmpeg) {
    throw 'ffmpeg.exe not found on PATH; pass -FfmpegDir <folder with ffmpeg.exe/ffprobe.exe>.'
  }
  $FfmpegDir = Split-Path $ffmpeg.Source
}
$tools = Join-Path $out 'tools'
New-Item -ItemType Directory -Force $tools | Out-Null
foreach ($name in 'ffmpeg.exe', 'ffprobe.exe') {
  $source = Join-Path $FfmpegDir $name
  if (-not (Test-Path $source)) { throw "Missing $name in $FfmpegDir" }
  Copy-Item $source (Join-Path $tools $name) -Force
}

# In-place updater: the shell copies it to a temporary folder, exits, and the
# helper replaces the install directory and restarts the app.
$updater = Join-Path $root 'native\updater\build\update.exe'
if (-not (Test-Path $updater)) {
  throw 'Missing native\updater\build\update.exe. Run native\updater\build.ps1 first.'
}
Copy-Item $updater (Join-Path $out 'update.exe') -Force

$items = @(
  (Join-Path $out 'free_player.exe'),
  (Join-Path $out 'update.exe'),
  (Join-Path $tools 'ffmpeg.exe'),
  (Join-Path $tools 'ffprobe.exe')
)
foreach ($item in $items) {
  if (-not (Test-Path $item)) { throw "Assembly incomplete: $item" }
  $kb = [math]::Round((Get-Item $item).Length / 1KB, 1)
  Write-Output ("{0}  {1} KB" -f (Split-Path $item -Leaf), $kb)
}
Write-Output "Assembled: $out"
