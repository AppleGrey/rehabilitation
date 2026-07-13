conda activate rehabilitation
Set-Location $PSScriptRoot/ai-svc
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
