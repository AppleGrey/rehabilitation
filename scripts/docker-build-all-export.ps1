# Build and export both backend and frontend images
# Usage: .\scripts\docker-build-all-export.ps1

$ErrorActionPreference = "Stop"

& (Join-Path $PSScriptRoot "docker-build-export.ps1")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& (Join-Path $PSScriptRoot "docker-build-web-export.ps1")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host ">>> Backend + Frontend images exported." -ForegroundColor Green
