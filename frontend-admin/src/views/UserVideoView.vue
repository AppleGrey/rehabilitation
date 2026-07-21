<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { CORE_SVC_BASE, fetchUploads, type UploadItem } from '../api'

const busy = ref(false)
const error = ref('')
const uploads = ref<UploadItem[]>([])
const selectedId = ref('')

const selected = computed(() => uploads.value.find((u) => u.task_id === selectedId.value) ?? null)

async function load() {
  busy.value = true
  error.value = ''
  try {
    const data = await fetchUploads(50)
    uploads.value = data.uploads || []
    if (uploads.value.length && !selectedId.value) selectedId.value = uploads.value[0].task_id
  } catch (err) {
    error.value = String(err)
    uploads.value = []
  } finally {
    busy.value = false
  }
}

function playSrc(url?: string): string {
  if (!url) return ''
  return url.startsWith('/core-svc') ? url : `${CORE_SVC_BASE}${url}`
}

function fmtDate(s?: string | null): string {
  if (!s) return '—'
  const d = new Date(s)
  return isNaN(d.getTime()) ? String(s) : d.toLocaleString()
}

const assessRows = computed(() => {
  const a = selected.value?.assessment as Record<string, any> | null | undefined
  if (!a || typeof a !== 'object') return []
  const keys = ['overall_score', 'posture_score', 'range_of_motion', 'rhythm_score']
  return keys
    .filter((k) => a[k] != null)
    .map((k) => ({ label: k, value: String(a[k]) }))
})

const assessLists = computed(() => {
  const a = selected.value?.assessment as Record<string, any> | null | undefined
  if (!a) return []
  const out: { title: string; items: string[] }[] = []
  for (const [key, title] of [
    ['key_findings', '关键发现'],
    ['corrections', '纠正建议'],
    ['safety_notes', '安全提醒'],
  ] as const) {
    const v = a[key]
    if (Array.isArray(v) && v.length) out.push({ title, items: v.map(String) })
  }
  return out
})

onMounted(load)
</script>

<template>
  <div class="wrap">
    <header class="page-head">
      <div>
        <h1>用户跟练视频</h1>
        <p class="sub">
          用户上传的动作评估视频，来自 admin-svc <code>GET /admin-api/uploads</code>，经 core-svc 播放。
        </p>
      </div>
      <div class="head-actions">
        <span class="count">{{ uploads.length }}</span>
        <button type="button" class="btn" :disabled="busy" @click="load">刷新</button>
      </div>
    </header>

    <div v-if="error" class="banner err">{{ error }}</div>

    <div class="workspace">
      <aside class="list-panel">
        <div v-if="busy && !uploads.length" class="empty">加载中…</div>
        <div v-else-if="!uploads.length" class="empty">暂无用户上传视频</div>
        <ul v-else class="ulist">
          <li
            v-for="u in uploads"
            :key="u.task_id"
            :class="{ active: u.task_id === selectedId }"
            @click="selectedId = u.task_id"
          >
            <div class="row1">
              <span class="tid">{{ u.task_id.slice(0, 8) }}</span>
              <span class="status" :data-s="u.status">{{ u.status }}</span>
            </div>
            <div class="row2">
              <span>标准: {{ u.standard_video_id || '—' }}</span>
            </div>
            <div class="row3">{{ fmtDate(u.created_at) }}</div>
          </li>
        </ul>
      </aside>

      <main class="detail-panel">
        <template v-if="selected">
          <section class="card">
            <h2>跟练视频 {{ selected.task_id.slice(0, 8) }}</h2>
            <div class="tags">
              <span class="chip">状态：{{ selected.status }}</span>
              <span class="chip">会话：{{ (selected.session_id || '—').slice(0, 8) }}</span>
              <span class="chip">{{ fmtDate(selected.created_at) }}</span>
            </div>
            <video
              v-if="selected.status === 'done' || selected.play_url"
              :key="selected.task_id"
              class="player"
              :src="playSrc(selected.play_url)"
              controls
              preload="metadata"
            />
          </section>

          <section v-if="assessRows.length || assessLists.length" class="card">
            <h3>动作评估</h3>
            <div class="scores">
              <div v-for="r in assessRows" :key="r.label" class="score">
                <span class="s-val">{{ r.value }}</span>
                <span class="s-lbl">{{ r.label }}</span>
              </div>
            </div>
            <div v-for="blk in assessLists" :key="blk.title" class="ablk">
              <h4>{{ blk.title }}</h4>
              <ul>
                <li v-for="(t, i) in blk.items" :key="i">{{ t }}</li>
              </ul>
            </div>
            <p v-if="selected.summary" class="summary">{{ selected.summary }}</p>
          </section>
          <section v-else class="card">
            <p class="empty">
              {{ selected.status === 'done' ? '无评估详情' : '评估尚未完成（' + selected.status + '）' }}
            </p>
          </section>

          <details class="raw">
            <summary>原始 JSON</summary>
            <pre>{{ JSON.stringify(selected, null, 2) }}</pre>
          </details>
        </template>
        <div v-else class="empty detail-empty">选择左侧视频查看</div>
      </main>
    </div>
  </div>
</template>

<style scoped>
.wrap { height: 100%; min-height: 0; display: flex; flex-direction: column; padding: 16px 18px 18px; gap: 12px; overflow: hidden; }
.page-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; flex: 0 0 auto; }
h1 { margin: 0 0 4px; font-size: 1.35rem; font-weight: 600; }
.sub { margin: 0; color: var(--muted); font-size: 0.86rem; }
.sub code { font-family: Consolas, Menlo, monospace; font-size: 0.85em; }
.head-actions { display: flex; align-items: center; gap: 10px; }
.count { color: var(--muted); font-size: 0.85rem; }
.btn { padding: 8px 14px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); color: var(--fg); font: inherit; cursor: pointer; }
.btn:hover:not(:disabled) { border-color: var(--primary); color: var(--primary); }
.banner.err { padding: 10px 12px; border-radius: 8px; background: #2a1518; border: 1px solid #5c2430; color: var(--red); font-size: 0.88rem; }
.workspace { flex: 1; min-height: 0; display: grid; grid-template-columns: minmax(220px, 300px) 1fr; gap: 12px; }
.list-panel, .detail-panel { min-height: 0; background: var(--panel); border: 1px solid var(--line); border-radius: 10px; overflow: auto; }
.ulist { list-style: none; margin: 0; padding: 6px; }
.ulist li { padding: 10px 12px; border-radius: 8px; cursor: pointer; border: 1px solid transparent; margin-bottom: 4px; }
.ulist li:hover { background: #132033; }
.ulist li.active { background: #13262a; border-color: #1f4a45; }
.row1 { display: flex; justify-content: space-between; align-items: center; }
.tid { font-family: Consolas, Menlo, monospace; font-weight: 600; font-size: 0.86rem; }
.status { font-size: 0.72rem; color: var(--muted); }
.status[data-s='done'] { color: var(--primary); }
.status[data-s='error'] { color: var(--red); }
.row2 { margin-top: 4px; font-size: 0.75rem; color: var(--muted); }
.row3 { margin-top: 2px; font-size: 0.72rem; color: #6b7688; }
.detail-panel { padding: 14px; display: flex; flex-direction: column; gap: 12px; }
.card { background: var(--bg); border: 1px solid var(--line); border-radius: 10px; padding: 14px; }
.card h2 { margin: 0 0 8px; font-size: 1.1rem; }
.card h3 { margin: 0 0 10px; font-size: 0.98rem; }
.card h4 { margin: 10px 0 6px; font-size: 0.78rem; color: var(--muted); }
.tags { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 10px; }
.chip { padding: 4px 9px; border-radius: 999px; background: #1a2436; border: 1px solid var(--line); font-size: 0.78rem; color: #c9d4e8; }
.player { width: 100%; max-height: min(52vh, 460px); background: #000; border-radius: 8px; display: block; }
.scores { display: flex; flex-wrap: wrap; gap: 10px; margin-bottom: 8px; }
.score { background: #1a2436; border: 1px solid var(--line); border-radius: 8px; padding: 8px 14px; text-align: center; }
.s-val { display: block; font-size: 1.2rem; font-weight: 700; color: var(--primary); }
.s-lbl { font-size: 0.72rem; color: var(--muted); }
.ablk ul { margin: 4px 0 0; padding-left: 18px; font-size: 0.85rem; color: #c9d4e8; line-height: 1.5; }
.summary { margin: 10px 0 0; color: #c9d4e8; font-size: 0.88rem; line-height: 1.55; }
.raw { border-top: 1px solid var(--line); padding-top: 10px; }
.raw summary { cursor: pointer; color: var(--muted); font-size: 0.85rem; }
.raw pre { margin: 10px 0 0; padding: 12px; border-radius: 8px; background: #0c111b; border: 1px solid var(--line); overflow: auto; max-height: 320px; font-size: 0.78rem; font-family: Consolas, Menlo, monospace; }
.empty { padding: 24px 16px; color: var(--muted); text-align: center; font-size: 0.9rem; }
.detail-empty { margin: auto; }
@media (max-width: 900px) { .workspace { grid-template-columns: 1fr; grid-template-rows: minmax(200px, 34%) 1fr; } }
</style>
