# Upload backend + frontend images and deploy files to server
# Usage: .\scripts\upload-to-server.ps1 -Server "root@101.201.170.95"

param(
    [string]$Server = "root@101.201.170.95",
    [string]$RemoteDir = "/opt/rehabilitation"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$BackendTar = Join-Path $Root "rehabilitation-backend.tar"
$FrontendTar = Join-Path $Root "rehabilitation-frontend.tar"

if (-not (Test-Path $BackendTar)) {
    Write-Error "未找到 rehabilitation-backend.tar，请先执行 .\scripts\docker-build-export.ps1"
}
if (-not (Test-Path $FrontendTar)) {
    Write-Error "未找到 rehabilitation-frontend.tar，请先执行 .\scripts\docker-build-web-export.ps1"
}

Write-Host ">>> 在服务器创建目录 $RemoteDir ..." -ForegroundColor Cyan
ssh $Server "mkdir -p $RemoteDir/data/metadata $RemoteDir/assets/videos $RemoteDir/logs $RemoteDir/scripts"

Write-Host ">>> 上传镜像与配置..." -ForegroundColor Cyan
scp $BackendTar $FrontendTar docker-compose.prod.yml "$Server`:${RemoteDir}/"
if (Test-Path ".env") {
    scp .env "$Server`:${RemoteDir}/"
} else {
    scp .env.example "$Server`:${RemoteDir}/"
    Write-Host "提示：本地无 .env，已上传 .env.example，请在服务器复制并填写 Key" -ForegroundColor Yellow
}
scp scripts/server-deploy.sh "$Server`:${RemoteDir}/scripts/"

Write-Host ">>> 上传 data/metadata（若本地有）..." -ForegroundColor Cyan
if (Test-Path "data/metadata") {
    scp -r data/metadata "$Server`:${RemoteDir}/data/"
}

Write-Host ""
Write-Host ">>> 上传完成。请在服务器执行：" -ForegroundColor Green
Write-Host "  ssh $Server"
Write-Host "  cd $RemoteDir"
Write-Host "  cp .env.example .env   # 若尚未配置"
Write-Host "  bash scripts/server-deploy.sh"
