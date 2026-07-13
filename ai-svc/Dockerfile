FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 构建上下文为仓库根（见 docker-compose 的 context: .），故 ai-svc 前缀；data 仍在根下
COPY ai-svc/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY ai-svc/app ./app
COPY data/metadata ./data/metadata

RUN mkdir -p data/sessions data/tasks data/uploads assets/videos logs

# 容器内 data/assets/logs 与 app 包同在 /app 下；覆盖 core.config 的路径锚点
ENV APP_BASE_DIR=/app

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/api/health')"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "1"]
