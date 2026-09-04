<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { CORE_SVC_BASE, deleteProgram, fetchProgram, fetchPrograms, withToken, type ProgramSummary } from '../api'

const busy = ref(false)
const error = ref('')
const programs = ref<ProgramSummary[]>([])
const selectedId = ref('')
const detail = ref<Record<string, any> | null>(null)
const detailBusy = ref(false)
const deleting = ref(false)

async function load() {
  busy.value = true
  error.value = ''
  try {
    const data = await fetchPrograms(50)
    programs.value = data.programs || []
    if (programs.value.length && !selectedId.value) {
      void select(programs.value[0].program_id)
    } else if (selectedId.value && !programs.value.some((p) => p.program_id === selectedId.value)) {
      selectedId.value = programs.value[0]?.program_id || ''
      detail.value = null
      if (selectedId.value) void select(selectedId.value)
    }
  } catch (err) {
    error.value = String(err)
    programs.value = []
  } finally {
    busy.value = false
  }
}

async function select(id: string) {
  selectedId.value = id
  detailBusy.value = true
  detail.value = null
  try {
    detail.value = await fetchProgram(id)
  } catch (err) {
    error.value = String(err)
  } finally {
    detailBusy.value = false
  }
}

async function removeSelected() {
  const id = selectedId.value
  if (!id || deleting.value) return
  const name = detail.value?.condition || detail.value?.body_part || id.slice(0, 8)
  if (!window.confirm(`确定删除方案「${name}」？此操作不可恢复。`)) return
  deleting.value = true
  error.value = ''
  try {
    await deleteProgram(id)
    selectedId.value = ''
    detail.value = null
    await load()
  } catch (err) {
    error.value = String(err)
  } finally {
    deleting.value = false
  }
}

function playSrc(url?: string): string {
  if (!url) return ''
  return withToken(url.startsWith('/core-svc') ? url : `${CORE_SVC_BASE}${url}`)
}

function dosage(it: Record<string, any>): string {
  const parts: string[] = []
  if (it.sets != null && it.reps != null) parts.push(`${it.sets}组×${it.reps}次`)
  else if (it.hold_seconds != null) parts.push(`保持${it.hold_seconds}s`)
  if (it.frequency) parts.push(String(it.frequency))
  if (it.load) parts.push(String(it.load))
  return parts.join(' · ') || '—'
}

function statusLabel(s?: string): string {
  return (
    {
      baseline_pending: '待基线',
      generating: '生成中',
      active: '进行中',
      refer: '已转诊',
      discharged: '已结业',
    }[s || ''] ||
    s ||
    '—'
  )
}

onMounted(load)
</script>

<template>
  <div class="wrap">
    <header class="page-head">
      <div>
        <h1>康复方案</h1>
        <p class="sub">来自 admin-svc <code>GET /admin-api/programs</code>（直读库）。</p>
      </div>
      <div class="head-actions">
        <span class="count">{{ programs.length }}</span>
        <button type="button" class="btn" :disabled="busy" @click="load">刷新</button>
      </div>
    </header>

    <div v-if="error" class="banner err">{{ error }}</div>

    <div class="workspace">
      <aside class="list-panel">
        <div v-if="busy && !programs.length" class="empty">加载中…</div>
        <div v-else-if="!programs.length" class="empty">暂无疗程</div>
        <ul v-else class="plist">
          <li
            v-for="p in programs"
            :key="p.program_id"
            :class="{ active: p.program_id === selectedId }"
            @click="select(p.program_id)"
          >
            <div class="row1">
              <span class="cond">{{ p.condition || p.body_part || '疗程' }}</span>
              <span class="status" :data-s="p.status">{{ statusLabel(p.status) }}</span>
            </div>
            <div class="row2">
              <span>{{ p.body_part || '—' }}</span>
              <span>第 {{ p.current_stage_no ?? 1 }} 阶段</span>
              <span class="id">{{ p.program_id.slice(0, 8) }}</span>
            </div>
          </li>
        </ul>
      </aside>

      <main class="detail-panel">
        <div v-if="detailBusy" class="empty">加载中…</div>
        <template v-else-if="detail">
          <section class="card">
            <div class="detail-head">
              <h2>{{ detail.condition || detail.body_part || '疗程' }}</h2>
              <button
                type="button"
                class="btn danger"
                :disabled="deleting"
                @click="removeSelected"
              >
                {{ deleting ? '删除中…' : '删除方案' }}
              </button>
            </div>
            <div class="tags">
              <span class="chip">{{ detail.body_part || '—' }}</span>
              <span class="chip">状态：{{ statusLabel(detail.status) }}</span>
              <span class="chip">当前第 {{ detail.current_stage_no ?? 1 }} 阶段</span>
            </div>
            <div v-if="(detail.impression || []).length" class="imp">
              <h4>临床方向（内部参考）</h4>
              <div class="chips">
                <span v-for="(h, i) in detail.impression" :key="i" class="chip">
                  {{ h.name }} · {{ (h.confidence ?? 0).toFixed?.(2) ?? h.confidence }}
                </span>
              </div>
            </div>
          </section>

          <section v-if="detail.current && detail.current.stage" class="card">
            <h3>当前阶段：{{ detail.current.stage.stage_type }}</h3>
            <div v-if="(detail.current.stage.goals || []).length" class="chips">
              <span v-for="(g, i) in detail.current.stage.goals" :key="i" class="chip goal">{{ g }}</span>
            </div>
            <p v-if="detail.current.plan" class="summary">{{ detail.current.plan.summary_text }}</p>
            <div v-if="detail.current.plan && (detail.current.plan.precautions || []).length" class="chips warn">
              <span v-for="(pc, i) in detail.current.plan.precautions" :key="i" class="chip">{{ pc }}</span>
            </div>
          </section>

          <section v-if="detail.current && (detail.current.items || []).length" class="card">
            <h3>训练项（{{ detail.current.items.length }}）</h3>
            <div v-for="(it, i) in detail.current.items" :key="i" class="item">
              <div class="item-head">
                <span class="order">{{ it.order }}</span>
                <span class="role">{{ it.role || 'main' }}</span>
                <span class="vid">{{ it.video_id }}</span>
                <span class="dose">{{ dosage(it) }}</span>
              </div>
              <p v-if="it.notes" class="notes">{{ it.notes }}</p>
              <video
                v-if="it.url"
                class="vplayer"
                :src="playSrc(it.url)"
                controls
                preload="none"
              />
            </div>
          </section>

          <section v-else-if="detail.status === 'generating'" class="card">
            <p class="empty">方案生成中，完成后将显示训练动作。</p>
          </section>

          <section v-else-if="detail.status === 'baseline_pending'" class="card">
            <p class="empty">该疗程尚在基线阶段，用户跟做后才会生成正式方案。</p>
          </section>

          <details class="raw">
            <summary>原始 JSON</summary>
            <pre>{{ JSON.stringify(detail, null, 2) }}</pre>
          </details>
        </template>
        <div v-else class="empty detail-empty">选择左侧疗程查看方案</div>
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
.btn.danger { border-color: #5c2430; color: #f0a8b0; }
.btn.danger:hover:not(:disabled) { border-color: #a33; color: #ffb4bc; }
.banner.err { padding: 10px 12px; border-radius: 8px; background: #2a1518; border: 1px solid #5c2430; color: var(--red); font-size: 0.88rem; }
.workspace { flex: 1; min-height: 0; display: grid; grid-template-columns: minmax(240px, 320px) 1fr; gap: 12px; }
.list-panel, .detail-panel { min-height: 0; background: var(--panel); border: 1px solid var(--line); border-radius: 10px; overflow: auto; }
.plist { list-style: none; margin: 0; padding: 6px; }
.plist li { padding: 10px 12px; border-radius: 8px; cursor: pointer; border: 1px solid transparent; margin-bottom: 4px; }
.plist li:hover { background: #132033; }
.plist li.active { background: #13262a; border-color: #1f4a45; }
.row1 { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
.cond { font-weight: 600; font-size: 0.92rem; }
.status { font-size: 0.72rem; color: var(--muted); }
.status[data-s='active'] { color: var(--primary); }
.status[data-s='generating'] { color: var(--yellow); }
.status[data-s='refer'] { color: var(--yellow); }
.row2 { display: flex; gap: 10px; margin-top: 4px; font-size: 0.75rem; color: var(--muted); }
.row2 .id { font-family: Consolas, Menlo, monospace; }
.detail-panel { padding: 14px; display: flex; flex-direction: column; gap: 12px; }
.detail-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; margin-bottom: 8px; }
.detail-head h2 { margin: 0; font-size: 1.1rem; }
.card { background: var(--bg); border: 1px solid var(--line); border-radius: 10px; padding: 14px; }
.card h2 { margin: 0 0 8px; font-size: 1.1rem; }
.card h3 { margin: 0 0 10px; font-size: 0.98rem; }
.card h4 { margin: 10px 0 6px; font-size: 0.78rem; color: var(--muted); text-transform: uppercase; letter-spacing: 0.04em; }
.tags, .chips { display: flex; flex-wrap: wrap; gap: 6px; }
.chip { padding: 4px 9px; border-radius: 999px; background: #1a2436; border: 1px solid var(--line); font-size: 0.78rem; color: #c9d4e8; }
.chip.goal { border-color: #1f4a45; color: #8fe0d0; }
.chips.warn .chip { border-color: #5c2430; color: #f0a8b0; background: #241418; }
.summary { margin: 10px 0; color: #c9d4e8; font-size: 0.9rem; line-height: 1.55; }
.item { border-top: 1px dashed var(--line); padding: 10px 0; }
.item:first-of-type { border-top: none; }
.item-head { display: flex; align-items: center; gap: 10px; font-size: 0.86rem; flex-wrap: wrap; }
.order { width: 20px; height: 20px; border-radius: 50%; background: #1a2436; display: inline-grid; place-items: center; font-size: 0.72rem; color: var(--muted); }
.role { font-size: 0.72rem; color: var(--muted); }
.vid { font-family: Consolas, Menlo, monospace; color: var(--primary); }
.dose { margin-left: auto; color: #c9d4e8; }
.notes { margin: 6px 0; color: var(--muted); font-size: 0.82rem; }
.vplayer { width: 100%; max-height: 300px; background: #000; border-radius: 8px; margin-top: 8px; display: block; }
.raw { border-top: 1px solid var(--line); padding-top: 10px; }
.raw summary { cursor: pointer; color: var(--muted); font-size: 0.85rem; }
.raw pre { margin: 10px 0 0; padding: 12px; border-radius: 8px; background: #0c111b; border: 1px solid var(--line); overflow: auto; max-height: 320px; font-size: 0.78rem; font-family: Consolas, Menlo, monospace; }
.empty { padding: 24px 16px; color: var(--muted); text-align: center; font-size: 0.9rem; }
.detail-empty { margin: auto; }
@media (max-width: 900px) { .workspace { grid-template-columns: 1fr; grid-template-rows: minmax(200px, 34%) 1fr; } }
</style>
