# Build Flutter Web locally, pack into nginx Docker image, export tar
# Usage: .\scripts\docker-build-web-export.ps1

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Frontend = Join-Path $Root "frontend"
$ImageName = "rehabilitation-frontend:latest"
$OutputTar = Join-Path $Root "rehabilitation-frontend.tar"

Set-Location $Frontend

Write-Host ">>> flutter pub get ..." -ForegroundColor Cyan
flutter pub get
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ">>> flutter build web (BACKEND_BASE empty, use nginx proxy) ..." -ForegroundColor Cyan
flutter build web --release --dart-define=BACKEND_BASE=
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ">>> Building nginx image (linux/amd64) ..." -ForegroundColor Cyan
docker build --platform linux/amd64 -t $ImageName .
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ">>> Exporting image to $OutputTar ..." -ForegroundColor Cyan
docker save $ImageName -o $OutputTar
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$sizeMb = [math]::Round((Get-Item $OutputTar).Length / 1MB, 1)
Write-Host ">>> Done. Size: ${sizeMb} MB" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  .\scripts\upload-to-server.ps1 -Server root@101.201.170.95"
Write-Host "  ssh root@101.201.170.95"
Write-Host "  cd /opt/rehabilitation"
Write-Host "  bash scripts/server-deploy.sh"
