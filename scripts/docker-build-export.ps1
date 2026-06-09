# Local build and export Docker image tar for server upload
# Usage: .\scripts\docker-build-export.ps1

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$ImageName = "rehabilitation-backend:latest"
$OutputTar = Join-Path $Root "rehabilitation-backend.tar"

Set-Location $Root

Write-Host ">>> Building image (linux/amd64)..." -ForegroundColor Cyan
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
