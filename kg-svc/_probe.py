"""临时探针：以 UTF-8 正确地向本机 kg-svc 发检索请求（规避 Windows 终端中文编码问题）。
    python _probe.py                 # 默认问题, hybrid
    python _probe.py "问题" naive
"""
import json
import sys
import urllib.request

URL = "http://127.0.0.1:8010/kg/retrieve"
query = sys.argv[1] if len(sys.argv) > 1 else "肩周炎粘连期的康复训练方法和禁忌有哪些？"
mode = sys.argv[2] if len(sys.argv) > 2 else "hybrid"

body = json.dumps({"query": query, "mode": mode, "top_k": 15}).encode("utf-8")
req = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=120) as r:
    d = json.load(r)

print(f"[query] {query}")
print(f"[resp ] mode={d['mode']}  elapsed_ms={d['elapsed_ms']}  length={d['length']}")
print("--- context preview (600) ---")
print(d["context"][:600])
