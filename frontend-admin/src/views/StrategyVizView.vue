<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref } from 'vue'
import { DataSet, Network } from 'vis-network/standalone'
import type { Data } from 'vis-network'
import { fetchHistory, fetchSessions } from '../api'
import type { SessionItem, Snapshot, TraceEvent, TreeNode } from '../types'

const sessions = ref<SessionItem[]>([])
const sessionId = ref('')
const snapshots = ref<Snapshot[]>([])
const activeTurn = ref(0)
const meta = ref('—')
const loadingSessions = ref(false)
const graphEl = ref<HTMLElement | null>(null)

let network: Network | null = null

const currentSnap = computed(() => snapshots.value[activeTurn.value] ?? null)
const latestSnap = computed(() =>
  snapshots.value.length ? snapshots.value[snapshots.value.length - 1] : null,
)

function shortText(t: string | undefined, n: number) {
  const s = t || ''
  return s.length > n ? `${s.slice(0, n)}…` : s
}

function intentColor(intent?: string, type?: string, term?: string) {
  if (type === 'terminal') return term === 'refer' ? '#ff5c6c' : '#f5b02e'
  if (intent === 'red_flag' || intent === 'contraindication') return '#ff5c6c'
  return '#4c8bff'
}

function buildAggregate(snaps: Snapshot[]) {
  const nodes: any[] = []
  const edges: any[] = []
  let prevSpine: string | null = null

  snaps.forEach((s, idx) => {
    const turn = s.turn_no
    const tnodes = s.tree_nodes || []
    const selId = s.selected_question_id
    const sel = tnodes.find((n) => n.node_id === selId)
    const spineId = `t${turn}`
    const label = sel
      ? `T${turn}｜${shortText(sel.question_text, 22)}`
      : `T${turn}｜${s.phase === 'warmup' ? '粗问了解' : '（无问题）'}`
    const col = sel ? intentColor(sel.intent, 'question') : '#00a68c'
    nodes.push({
      id: spineId,
      label,
      shape: 'box',
      level: idx,
      color: {
        background: '#0f2233',
        border: col,
        highlight: { background: '#16233d', border: col },
      },
      borderWidth: 2,
      font: { color: '#e6ebf5', size: 13 },
      _turn: idx,
    })
    if (prevSpine) {
      edges.push({
        from: prevSpine,
        to: spineId,
        arrows: 'to',
        color: { color: '#00a68c' },
        smooth: { type: 'cubicBezier', forceDirection: 'vertical', roundness: 0.5 },
      })
    }
    prevSpine = spineId

    tnodes
      .filter((n) => n.type === 'question' && n.node_id !== selId)
      .forEach((n, i) => {
        const cid = `${spineId}_${n.node_id}_${i}`
        nodes.push({
          id: cid,
          label: shortText(n.question_text, 20),
          shape: 'box',
          level: idx + 0.5,
          color: { background: '#0d1626', border: '#3a4560' },
          font: { color: '#8ea0be', size: 11 },
          _detail: n,
        })
        edges.push({
          from: spineId,
          to: cid,
          dashes: true,
          color: { color: '#33405c' },
          smooth: { type: 'cubicBezier', forceDirection: 'vertical', roundness: 0.4 },
        })
      })

    tnodes
      .filter((n) => n.type === 'terminal')
      .forEach((n, i) => {
        const cid = `${spineId}_term_${i}`
        nodes.push({
          id: cid,
          label: `⛔ ${n.terminal_type || 'terminal'}`,
          shape: 'hexagon',
          level: idx + 0.5,
          color: { background: '#2a1520', border: '#ff5c6c' },
          font: { color: '#ffb3ba', size: 11 },
          _detail: n,
        })
        edges.push({ from: spineId, to: cid, dashes: true, color: { color: '#5a2730' } })
      })
  })

  const last = snaps[snaps.length - 1]
  if (last && prevSpine) {
    const hyps = (last.hypotheses || [])
      .filter((h) => (h.status || 'active') === 'active')
      .sort((a, b) => (b.confidence || 0) - (a.confidence || 0))
    const top = hyps[0]
    nodes.push({
      id: 'conclusion',
      label: `结论方向\n${top ? `${shortText(top.name, 16)} ${(top.confidence || 0).toFixed(2)}` : '—'}`,
      shape: 'box',
      level: snaps.length,
      color: { background: '#3a2f12', border: '#f5b02e' },
      font: { color: '#ffe0a3', size: 12 },
    })
    edges.push({ from: prevSpine, to: 'conclusion', arrows: 'to', color: { color: '#f5b02e' } })
  }

  return { nodes, edges }
}

function renderGraph(snaps: Snapshot[]) {
  if (!graphEl.value) return
  const { nodes, edges } = buildAggregate(snaps)
  const data = {
    nodes: new DataSet(nodes),
    edges: new DataSet(edges),
  } as Data
  const options = {
    layout: {
      hierarchical: {
        enabled: true,
        direction: 'UD',
        sortMethod: 'directed',
        levelSeparation: 95,
        nodeSpacing: 170,
      },
    },
    physics: false,
    interaction: { hover: true, dragNodes: true, zoomView: true, dragView: true },
    nodes: { shadow: { enabled: true, size: 8, color: 'rgba(0,0,0,0.4)' } },
  }
  if (network) network.destroy()
  network = new Network(graphEl.value, data, options)
  network.on('click', (p) => {
    if (!p.nodes.length) return
    const n = (data.nodes as DataSet<any>).get(p.nodes[0]) as any
    if (n && n._turn != null) selectTurn(n._turn)
  })
}

function selectTurn(i: number) {
  if (i < 0 || i >= snapshots.value.length) return
  activeTurn.value = i
}

async function loadSessions() {
  loadingSessions.value = true
  try {
    const data = await fetchSessions()
    sessions.value = data.sessions || []
    if (!sessions.value.length) {
      sessionId.value = ''
      snapshots.value = []
      meta.value = '暂无会话'
      return
    }
    if (!sessionId.value || !sessions.value.some((s) => s.session_id === sessionId.value)) {
      sessionId.value = sessions.value[0].session_id
    }
    await loadSession(sessionId.value)
  } catch {
    sessions.value = []
    meta.value = '加载会话失败'
  } finally {
    loadingSessions.value = false
  }
}

async function loadSession(sid: string) {
  if (!sid) return
  sessionId.value = sid
  try {
    const data = await fetchHistory(sid)
    snapshots.value = data.snapshots || []
    if (!snapshots.value.length) {
      meta.value = '无快照'
      if (network) {
        network.destroy()
        network = null
      }
      return
    }
    const last = snapshots.value[snapshots.value.length - 1]
    meta.value = `共 ${snapshots.value.length} 轮 · 末轮 ${last.phase || ''} · ${last.strategy_source || ''}`
    await nextTick()
    renderGraph(snapshots.value)
    selectTurn(snapshots.value.length - 1)
  } catch (e) {
    meta.value = `加载失败：${e}`
  }
}

function sessionLabel(s: SessionItem) {
  const imp = s.impression?.[0]?.name || '—'
  return `第${s.turn_no}轮 · ${imp} · ${s.session_id.slice(0, 8)}`
}

function selectedQuestion(snap: Snapshot | null): TreeNode | null {
  if (!snap) return null
  const nodes = snap.tree_nodes || []
  const sel = nodes.find((n) => n.node_id === snap.selected_question_id)
  return sel && sel.type === 'question' ? sel : null
}

const discrimNode = computed(() => selectedQuestion(currentSnap.value))

const activeHyps = computed(() => {
  const snap = latestSnap.value
  if (!snap) return []
  return (snap.hypotheses || [])
    .filter((h) => (h.status || 'active') === 'active')
    .sort((a, b) => (b.confidence || 0) - (a.confidence || 0))
})

const orderedSlots = computed(() => {
  const slots = [...(latestSnap.value?.slots || [])]
  const order: Record<string, number> = { S: 0, P: 1, D: 2 }
  slots.sort((a, b) => (order[a.category || ''] ?? 9) - (order[b.category || ''] ?? 9))
  return slots
})

function formatSlotValue(s: { status?: string; value?: unknown }) {
  if (s.status !== 'known') return ''
  if (typeof s.value === 'object') return JSON.stringify(s.value)
  return s.value == null ? '' : String(s.value)
}

function traceHead(ev: TraceEvent) {
  const kind = ev.t || '?'
  if (kind === 'kg') return `🔎 ${ev.action}`
  if (kind === 'llm_a') return `🧠 ${ev.action}`
  if (kind === 'llm_b') return `🌳 ${ev.action}`
  if (kind === 'seed') return `📝 ${ev.action}`
  if (kind === 'decision') return `⚙️ ${ev.action}`
  if (kind === 'pick') return `✅ ${ev.action}`
  return ev.action || kind
}

function traceBody(ev: TraceEvent) {
  const kind = ev.t || '?'
  if (kind === 'kg') {
    return (
      `query: ${ev.query}\nmode: ${ev.mode} · top_k: ${ev.top_k} · 返回 ${ev.chars} 字` +
      (ev.degraded ? ' · [降级:kg-svc不可用/空]' : '') +
      (ev.error ? `\nerror: ${ev.error}` : '')
    )
  }
  if (kind === 'llm_a') {
    return (
      `facts: ${JSON.stringify(ev.facts)}\ndeltas: ${JSON.stringify(ev.hypothesis_deltas)}` +
      `\nred_flag: ${JSON.stringify(ev.red_flag)}\n\n[原文]\n${ev.raw || ''}`
    )
  }
  if (kind === 'llm_b') {
    return (
      `ok=${ev.ok} 问题数=${ev.n_questions ?? ''}` +
      (ev.errors?.length ? `\nerrors: ${JSON.stringify(ev.errors)}` : '') +
      `\n\n[原文]\n${ev.raw || ''}`
    )
  }
  if (kind === 'seed') {
    return `seed: ${JSON.stringify(ev.seed)}\n\n[原文]\n${ev.raw || ''}`
  }
  if (kind === 'decision') {
    return (
      `stop=${ev.stop} rebuild=${ev.rebuild} reason=${ev.reason}` +
      `\ndeviated=${ev.deviated} candidate_shift=${ev.candidate_shift} horizon_exhausted=${ev.horizon_exhausted}`
    )
  }
  if (kind === 'pick') {
    return (
      `问题: ${ev.question}\nintent=${ev.intent} score=${ev.score}` +
      `\ntarget_slots=${JSON.stringify(ev.target_slots)}\nbreakdown=${JSON.stringify(ev.breakdown)}`
    )
  }
  return ''
}

onMounted(() => {
  loadSessions()
})

onBeforeUnmount(() => {
  if (network) {
    network.destroy()
    network = null
  }
})
</script>

<template>
  <div class="page">
    <header>
      <h1>
        问诊策略树
        <span class="sub">整段问诊 · 策略/行为可视化 · 内网调试</span>
      </h1>
      <select v-model="sessionId" class="session-sel" @change="loadSession(sessionId)">
        <option v-if="!sessions.length" value="">
          {{ loadingSessions ? '加载中…' : '（暂无会话，先在 App 里问诊几轮）' }}
        </option>
        <option v-for="s in sessions" :key="s.session_id" :value="s.session_id">
          {{ sessionLabel(s) }}
        </option>
      </select>
      <button type="button" @click="loadSessions">刷新会话</button>
      <button type="button" @click="loadSession(sessionId)">重载当前</button>
      <span class="badge">{{ meta }}</span>
    </header>

    <main>
      <div ref="graphEl" class="graph" />
      <aside>
        <div class="card">
          <h3>问诊轮次（点节点或按钮看该轮 AI 行为）</h3>
          <div v-if="!snapshots.length" class="empty">选择一个会话</div>
          <div v-else class="turns">
            <button
              v-for="(s, i) in snapshots"
              :key="`${s.turn_no}-${i}`"
              type="button"
              class="turnbtn"
              :class="{ active: i === activeTurn }"
              @click="selectTurn(i)"
            >
              T{{ s.turn_no }}{{ s.phase === 'warmup' ? '·粗问' : '' }}
            </button>
          </div>
        </div>

        <div class="card">
          <h3>本轮鉴别方向（这题在区分哪些候选 · 答案导向）</h3>
          <div v-if="!discrimNode" class="empty">本轮无鉴别问题（粗问/收束）</div>
          <template v-else>
            <div class="qtext">{{ discrimNode.question_text || '' }}</div>
            <div class="muted">
              意图：{{ discrimNode.intent || '-' }}｜区分候选：{{
                discrimNode.discriminates?.length
                  ? discrimNode.discriminates.join(' / ')
                  : '（未标注）'
              }}
            </div>
            <template v-if="Object.keys(discrimNode.option_leanings || {}).length">
              <div class="muted">答案 → 倾向病症：</div>
              <div
                v-for="(v, k) in discrimNode.option_leanings"
                :key="String(k)"
                class="slot"
              >
                <span class="fg">{{ k }}</span>
                <span class="dim">→</span>
                <span class="blue">{{ v }}</span>
              </div>
            </template>
            <div v-else class="dim">（该题未提供答案→病症映射）</div>
          </template>
        </div>

        <div class="card">
          <h3>本轮 AI 行为（原文 / 知识图谱查询 / 决策）</h3>
          <div v-if="!(currentSnap?.trace || []).length" class="empty">该轮无 trace（可能是旧数据）</div>
          <details v-for="(ev, idx) in currentSnap?.trace || []" :key="idx" class="tr">
            <summary>
              <span class="kind" :class="`k-${ev.t || 'x'}`">{{ ev.t || '?' }}</span>
              {{ traceHead(ev) }}
            </summary>
            <pre>{{ traceBody(ev) }}</pre>
          </details>
        </div>

        <div class="card">
          <h3>临床印象（最新，内部候选，非诊断）</h3>
          <div v-if="!activeHyps.length" class="empty">暂无候选</div>
          <div v-for="(h, i) in activeHyps" :key="i" class="hyp">
            <span class="hyp-name">{{ h.name }}</span>
            <span class="bar"><i :style="{ width: `${Math.round((h.confidence || 0) * 100)}%` }" /></span>
            <span class="muted">{{ (h.confidence || 0).toFixed(2) }}</span>
          </div>
        </div>

        <div class="card">
          <h3>信息槽（S 安全 / P 必填 / D 鉴别，最新）</h3>
          <div v-if="!orderedSlots.length" class="empty">暂无信息槽（粗问阶段）</div>
          <div v-for="(s, i) in orderedSlots" :key="i" class="slot">
            <span class="tag" :class="s.category">{{ s.category }}</span>
            <span class="grow">{{ s.title || s.slot_id }}</span>
            <span :class="`st-${s.status}`">
              {{ s.status }}{{ formatSlotValue(s) ? ` · ${formatSlotValue(s)}` : '' }}
            </span>
          </div>
        </div>
      </aside>
    </main>

    <div class="legend">
      <span><i class="dot" style="background: #00a68c" />已问(路径)</span>
      <span><i class="dot" style="background: #ff5c6c" />红旗/安全</span>
      <span><i class="dot" style="background: #4c8bff" />鉴别/功能</span>
      <span><i class="dot" style="background: #6b7688" />候选(未选)</span>
      <span><i class="dot" style="background: #f5b02e" />结论/终止</span>
      <span class="dim">拖拽平移 · 滚轮缩放</span>
    </div>
  </div>
</template>

<style scoped>
.page {
  height: 100%;
  min-height: 0;
  display: flex;
  flex-direction: column;
}
header {
  padding: 12px 18px;
  background: var(--panel);
  border-bottom: 1px solid var(--line);
  display: flex;
  align-items: center;
  gap: 14px;
  flex-wrap: wrap;
}
header h1 {
  font-size: 16px;
  margin: 0;
  font-weight: 600;
}
.sub {
  color: var(--muted);
  font-size: 12px;
  font-weight: 400;
  margin-left: 8px;
}
.session-sel {
  min-width: 260px;
}
select,
button {
  background: #0d1626;
  color: var(--fg);
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: 7px 10px;
  font-size: 13px;
}
button {
  cursor: pointer;
}
button:hover {
  border-color: var(--primary);
}
.badge {
  font-size: 11px;
  padding: 2px 8px;
  border-radius: 10px;
  background: #0d1626;
  border: 1px solid var(--line);
  color: var(--muted);
}
main {
  flex: 1;
  display: flex;
  min-height: 0;
}
.graph {
  flex: 1;
  min-width: 0;
  background: radial-gradient(circle at 50% 20%, #14203a 0%, var(--bg) 70%);
}
aside {
  width: 380px;
  border-left: 1px solid var(--line);
  background: var(--panel);
  overflow-y: auto;
  padding: 14px;
}
.card {
  background: #0d1626;
  border: 1px solid var(--line);
  border-radius: 10px;
  padding: 12px;
  margin-bottom: 12px;
}
.card h3 {
  margin: 0 0 8px;
  font-size: 13px;
  color: var(--muted);
  font-weight: 600;
  letter-spacing: 0.03em;
}
.hyp {
  display: flex;
  align-items: center;
  gap: 8px;
  margin: 6px 0;
  font-size: 13px;
}
.hyp-name {
  flex: 0 0 auto;
  max-width: 160px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.bar {
  flex: 1;
  height: 8px;
  background: #1b2740;
  border-radius: 5px;
  overflow: hidden;
}
.bar > i {
  display: block;
  height: 100%;
  background: linear-gradient(90deg, var(--blue), var(--primary));
}
.slot {
  font-size: 12.5px;
  padding: 5px 0;
  border-bottom: 1px dashed var(--line);
  display: flex;
  gap: 8px;
  align-items: baseline;
}
.slot:last-child {
  border-bottom: none;
}
.tag {
  font-size: 10px;
  padding: 1px 6px;
  border-radius: 6px;
  border: 1px solid var(--line);
}
.tag.S {
  color: var(--red);
  border-color: #5a2730;
}
.tag.P {
  color: var(--yellow);
  border-color: #5a4a1f;
}
.tag.D {
  color: var(--blue);
  border-color: #264062;
}
.st-known {
  color: var(--green);
}
.st-missing {
  color: var(--muted);
}
.st-unknown {
  color: var(--gray);
}
.legend {
  display: flex;
  gap: 12px;
  flex-wrap: wrap;
  font-size: 11px;
  color: var(--muted);
  padding: 8px 18px;
  background: var(--panel);
  border-top: 1px solid var(--line);
}
.legend span {
  display: inline-flex;
  align-items: center;
  gap: 5px;
}
.dot {
  width: 10px;
  height: 10px;
  border-radius: 50%;
  display: inline-block;
}
.empty {
  color: var(--muted);
  font-size: 13px;
  padding: 16px;
  text-align: center;
}
.tr {
  border: 1px solid var(--line);
  border-radius: 8px;
  margin: 6px 0;
  overflow: hidden;
}
.tr > summary {
  cursor: pointer;
  padding: 7px 10px;
  font-size: 12.5px;
  list-style: none;
  display: flex;
  gap: 8px;
  align-items: center;
}
.tr > summary::-webkit-details-marker {
  display: none;
}
.kind {
  font-size: 10px;
  padding: 1px 6px;
  border-radius: 6px;
  border: 1px solid var(--line);
  flex: 0 0 auto;
}
.k-kg {
  color: var(--green);
  border-color: #1f4a34;
}
.k-llm_a {
  color: var(--blue);
  border-color: #264062;
}
.k-llm_b {
  color: var(--purple);
  border-color: #3a2a5a;
}
.k-seed {
  color: var(--yellow);
  border-color: #5a4a1f;
}
.k-decision {
  color: var(--muted);
}
.k-pick {
  color: var(--primary);
  border-color: #1f4a44;
}
.tr pre {
  margin: 0;
  padding: 8px 10px;
  background: #0a1120;
  border-top: 1px solid var(--line);
  font-size: 11px;
  color: var(--muted);
  white-space: pre-wrap;
  word-break: break-all;
  max-height: 220px;
  overflow: auto;
}
.turnbtn {
  display: inline-block;
  margin: 3px 4px 0 0;
  padding: 3px 9px;
  font-size: 12px;
  border-radius: 8px;
  background: #0d1626;
  border: 1px solid var(--line);
  cursor: pointer;
  color: var(--fg);
}
.turnbtn.active {
  border-color: var(--primary);
  color: var(--primary);
}
.qtext {
  margin-bottom: 8px;
}
.muted {
  font-size: 12px;
  color: var(--muted);
  margin-bottom: 6px;
}
.dim {
  font-size: 12px;
  color: var(--gray);
}
.fg {
  flex: 0 0 auto;
  color: var(--fg);
}
.blue {
  flex: 1;
  color: var(--blue);
}
.grow {
  flex: 1;
}
</style>