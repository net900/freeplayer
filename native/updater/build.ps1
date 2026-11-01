# Builds update.exe (Windows GUI subsystem, no console window).
# Requires Go on PATH. Output: native\updater\build\update.exe
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path $here 'build'
New-Item -ItemType Directory -Force $out | Out-Null

$env:CGO_ENABLED = '0'
$env:GOOS = 'windows'
$env:GOARCH = 'amd64'
Push-Location $here
try {
  go build -trimpath -ldflags '-s -w -H=windowsgui' -o (Join-Path $out 'update.exe') .
  if ($LASTEXITCODE -ne 0) { throw "go build failed: $LASTEXITCODE" }
} finally {
  Pop-Location
}
Get-Item (Join-Path $out 'update.exe') | Select-Object Name, Length
