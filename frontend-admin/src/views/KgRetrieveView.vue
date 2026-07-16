<script setup lang="ts">
import { onMounted, ref } from 'vue'

const baseUrl = ref('/kg-svc')
const query = ref('网球肘患者握物时常见的代偿模式是什么？')
const mode = ref('hybrid')
const topK = ref(20)
const onlyNeedContext = ref('true')

const healthBusy = ref(false)
const healthKind = ref<'ok' | 'err' | ''>('')
const healthLabel = ref('')
const healthInfo = ref('')

const retrieveBusy = ref(false)
const retrieveKind = ref<'ok' | 'err' | ''>('')
const retrieveLabel = ref('')
const showMeta = ref(false)
const metaMode = ref('—')
const metaElapsed = ref('—')
const metaLength = ref('—')
const metaTokens = ref('—')
const contextOut = ref('（检索结果将显示在这里）')

function normalizedBase() {
  return baseUrl.value.replace(/\/+$/, '')
}

function estTokens(text: string) {
  if (!text) return 0
  const cjk = (text.match(/[\u4e00-\u9fff]/g) || []).length
  const other = text.length - cjk
  return Math.round(cjk / 1.6 + other / 4.2)
}

async function checkHealth() {
  healthBusy.value = true
  healthKind.value = ''
  healthLabel.value = '检查中…'
  healthInfo.value = ''
  try {
    const res = await fetch(`${normalizedBase()}/health`)
    const data = await res.json()
    if (!res.ok) throw new Error(JSON.stringify(data))
    const miss = (data.config_missing || []).join(', ') || '无'
    healthKind.value = 'ok'
    healthLabel.value = '服务正常'
    healthInfo.value = [
      `status: ${data.status}`,
      `working_dir: ${data.working_dir}`,
      `embed_model: ${data.embed_model}`,
      `llm_model: ${data.llm_model}`,
      `config_missing: ${miss}`,
    ].join('\n')
  } catch (err) {
    healthKind.value = 'err'
    healthLabel.value = '连接失败'
    healthInfo.value = String(err)
  } finally {
    healthBusy.value = false
  }
}

async function doRetrieve() {
  const q = query.value.trim()
  if (!q) {
    alert('请输入检索问题')
    return
  }
  retrieveBusy.value = true
  showMeta.value = false
  retrieveKind.value = ''
  retrieveLabel.value = '检索中…'
  contextOut.value = '请稍候…'

  const body = {
    query: q,
    mode: mode.value,
    top_k: Number(topK.value) || 20,
    only_need_context: onlyNeedContext.value === 'true',
  }

  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 120000)

  try {
    const res = await fetch(`${normalizedBase()}/kg/retrieve`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
      body: JSON.stringify(body),
      signal: controller.signal,
    })
    const data = await res.json()
    if (!res.ok) {
      const detail =
        typeof data.detail === 'string' ? data.detail : JSON.stringify(data.detail || data)
      throw new Error(detail || res.statusText)
    }
    retrieveKind.value = 'ok'
    retrieveLabel.value = '检索成功'
    showMeta.value = true
    metaMode.value = data.mode
    metaElapsed.value = String(data.elapsed_ms)
    metaLength.value = String(data.length)
    metaTokens.value = `~${estTokens(data.context || '')}`
    contextOut.value = data.context || '（空上下文）'
  } catch (err: any) {
    retrieveKind.value = 'err'
    retrieveLabel.value = '检索失败'
    contextOut.value =
      err?.name === 'AbortError'
        ? '请求超时（120s），请检查服务或改用 naive 模式重试。'
        : String(err)
  } finally {
    clearTimeout(timer)
    retrieveBusy.value = false
  }
}

function clearResult() {
  retrieveKind.value = ''
  retrieveLabel.value = ''
  showMeta.value = false
  contextOut.value = '（检索结果将显示在这里）'
}

onMounted(() => {
  checkHealth()
})
</script>

<template>
  <div class="wrap">
    <header>
      <h1>kg-svc 检索测试</h1>
      <p class="sub">
        调用 <code>POST /kg/retrieve</code> 与 <code>GET /health</code>。默认走同域代理
        <code>/kg-svc</code>（→ :8010）；也可填直连地址。
      </p>
    </header>

    <section class="panel">
      <div class="row">
        <div class="field grow">
          <label for="baseUrl">服务地址</label>
          <input id="baseUrl" v-model="baseUrl" type="text" />
        </div>
        <div class="btns">
          <button type="button" class="btn-secondary" :disabled="healthBusy" @click="checkHealth">
            检查 /health
          </button>
        </div>
      </div>
      <div class="status-bar">
        <span v-if="healthLabel" class="pill" :class="healthKind">
          <span v-if="healthBusy" class="spinner" />{{ healthLabel }}
        </span>
      </div>
      <pre class="health-info">{{ healthInfo }}</pre>
    </section>

    <section class="panel">
      <div class="field" style="margin-bottom: 12px">
        <label for="query">检索问题</label>
        <textarea id="query" v-model="query" placeholder="输入中文或英文问题…" />
      </div>

      <div class="row">
        <div class="field">
          <label for="mode">检索模式</label>
          <select id="mode" v-model="mode">
            <option value="hybrid">hybrid — 图 + 向量（默认）</option>
            <option value="naive">naive — 纯向量</option>
            <option value="local">local — 实体为中心</option>
            <option value="global">global — 关系主题</option>
            <option value="mix">mix — 图 + 向量（mix）</option>
          </select>
        </div>
        <div class="field" style="max-width: 120px">
          <label for="topK">top_k</label>
          <input id="topK" v-model.number="topK" type="number" min="1" max="100" />
        </div>
        <div class="field" style="max-width: 180px">
          <label for="onlyContext">only_need_context</label>
          <select id="onlyContext" v-model="onlyNeedContext">
            <option value="true">true — 只返回上下文</option>
            <option value="false">false — LightRAG 直接生成</option>
          </select>
        </div>
      </div>

      <div class="btns" style="margin-top: 4px">
        <button type="button" class="btn-primary" :disabled="retrieveBusy" @click="doRetrieve">
          检索
        </button>
        <button type="button" class="btn-secondary" :disabled="retrieveBusy" @click="clearResult">
          清空结果
        </button>
      </div>
      <p class="hint">首次检索可能较慢（向量计算 + 可选 LLM 抽关键词）。超时设为 120 秒。</p>
    </section>

    <section class="panel">
      <div class="status-bar">
        <span v-if="retrieveLabel" class="pill" :class="retrieveKind">
          <span v-if="retrieveBusy" class="spinner" />{{ retrieveLabel }}
        </span>
      </div>
      <div v-show="showMeta" class="meta">
        <span>模式：<strong>{{ metaMode }}</strong></span>
        <span>耗时：<strong>{{ metaElapsed }}</strong> ms</span>
        <span>长度：<strong>{{ metaLength }}</strong> 字符</span>
        <span>约 token：<strong>{{ metaTokens }}</strong></span>
      </div>
      <pre class="context-out">{{ contextOut }}</pre>
    </section>
  </div>
</template>

<style scoped>
.wrap {
  max-width: 960px;
  margin: 0 auto;
  padding: 24px 20px 48px;
  overflow: auto;
  height: 100%;
  --bg: #0f1419;
  --panel: #1a2332;
  --border: #2d3a4f;
  --text: #e7ecf3;
  --muted: #8b9cb3;
  --accent: #3b82f6;
  --accent-hover: #2563eb;
  --ok: #22c55e;
  --err: #ef4444;
  --mono: 'Cascadia Code', Consolas, Menlo, monospace;
  color: var(--text);
  background: var(--bg);
}
header { margin-bottom: 24px; }
h1 { margin: 0 0 6px; font-size: 1.5rem; font-weight: 600; }
.sub { color: var(--muted); font-size: 0.9rem; }
.panel {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 16px;
  margin-bottom: 16px;
}
.row {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
  align-items: flex-end;
  margin-bottom: 12px;
}
.field {
  display: flex;
  flex-direction: column;
  gap: 6px;
  flex: 1;
  min-width: 140px;
}
.field.grow { flex: 2; min-width: 220px; }
label {
  font-size: 0.8rem;
  color: var(--muted);
  text-transform: uppercase;
  letter-spacing: 0.04em;
}
input[type='text'],
input[type='number'],
select,
textarea {
  width: 100%;
  padding: 10px 12px;
  border: 1px solid var(--border);
  border-radius: 8px;
  background: var(--bg);
  color: var(--text);
  font: inherit;
}
textarea {
  min-height: 96px;
  resize: vertical;
}
.btns { display: flex; flex-wrap: wrap; gap: 10px; }
button {
  padding: 10px 18px;
  border: none;
  border-radius: 8px;
  font: inherit;
  font-weight: 500;
  cursor: pointer;
}
button:disabled { opacity: 0.5; cursor: not-allowed; }
.btn-primary { background: var(--accent); color: #fff; }
.btn-primary:hover:not(:disabled) { background: var(--accent-hover); }
.btn-secondary { background: var(--border); color: var(--text); }
.btn-secondary:hover:not(:disabled) { background: #3d4f6a; }
.status-bar {
  display: flex;
  flex-wrap: wrap;
  gap: 16px;
  font-size: 0.9rem;
  min-height: 24px;
}
.pill {
  padding: 4px 10px;
  border-radius: 999px;
  background: var(--bg);
  border: 1px solid var(--border);
  display: inline-flex;
  align-items: center;
  gap: 6px;
}
.pill.ok { color: var(--ok); border-color: #166534; }
.pill.err { color: var(--err); border-color: #991b1b; }
.health-info {
  margin-top: 10px;
  font-size: 0.85rem;
  color: var(--muted);
  white-space: pre-wrap;
  font-family: var(--mono);
}
.context-out {
  margin: 0;
  padding: 14px;
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: 8px;
  font-family: var(--mono);
  font-size: 0.82rem;
  line-height: 1.55;
  white-space: pre-wrap;
  word-break: break-word;
  max-height: 520px;
  overflow: auto;
}
.meta {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
  margin-bottom: 10px;
  font-size: 0.9rem;
  color: var(--muted);
}
.meta strong { color: var(--text); }
.hint {
  font-size: 0.82rem;
  color: var(--muted);
  margin-top: 8px;
}
.spinner {
  display: inline-block;
  width: 14px;
  height: 14px;
  border: 2px solid var(--border);
  border-top-color: var(--accent);
  border-radius: 50%;
  animation: spin 0.7s linear infinite;
}
@keyframes spin { to { transform: rotate(360deg); } }
code {
  font-family: var(--mono);
  font-size: 0.85em;
}
</style>