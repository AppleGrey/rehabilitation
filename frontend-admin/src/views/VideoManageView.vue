<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import {
  deleteMotionRule,
  fetchMotionRule,
  fetchMotionRuleIds,
  fetchVideos,
  playUrl,
  saveMotionRule,
  type VideoItem,
} from '../api'

const busy = ref(false)
const error = ref('')
const videos = ref<VideoItem[]>([])
const selectedId = ref('')
const filterJoint = ref('')
const filterSeverity = ref('')
const search = ref('')

const uploadOpen = ref(false)
const uploadFile = ref<File | null>(null)
const uploadPreviewUrl = ref('')
const uploadDragging = ref(false)
const uploadNote = ref('')
const fileInputRef = ref<HTMLInputElement | null>(null)
const uploadForm = ref({
  video_id: '',
  target_joint: '',
  severity: '轻度',
  difficulty: 2,
  description_cn: '',
})

const LANDMARKS = [
  'nose',
  'left_shoulder',
  'right_shoulder',
  'left_elbow',
  'right_elbow',
  'left_wrist',
  'right_wrist',
  'left_hip',
  'right_hip',
  'left_knee',
  'right_knee',
  'left_ankle',
  'right_ankle',
  'mid_shoulder',
  'mid_hip',
]

const ruleIds = ref<Set<string>>(new Set())
const ruleBusy = ref(false)
const ruleMessage = ref('')
const ruleIsError = ref(false)
const ruleJson = ref('')
const jsonDirty = ref(false)
interface StandardDraft {
  id: string
  name: string
  kind: string
  output: string
  from: string
  to: string
  pointA: string
  pointB: string
  pointC: string
  passOp: string
  pass: number
  excellent: number
  reset: number
  hint: string
}

interface PeakDraft {
  id: string
  name: string
  t: number | null
  standards: StandardDraft[]
}

let peakSerial = 0
let standardSerial = 0

function nextPeakId() {
  peakSerial += 1
  return `peak_${peakSerial}`
}

function nextStandardId() {
  standardSerial += 1
  return `std_${standardSerial}`
}

function noteSerial(id: string, prefix: string, current: number) {
  const match = new RegExp(`^${prefix}_(\\d+)$`).exec(id)
  return match ? Math.max(current, Number(match[1])) : current
}

function blankStandard(name: string): StandardDraft {
  return {
    id: nextStandardId(),
    name,
    kind: 'segment_to_axis',
    output: 'degrees_from_down',
    from: 'right_hip',
    to: 'right_ankle',
    pointA: 'left_hip',
    pointB: 'left_knee',
    pointC: 'left_ankle',
    passOp: 'gte',
    pass: 40,
    excellent: 50,
    reset: 15,
    hint: '请再接近合格线一些',
  }
}

function blankPeak(name: string, t: number | null = null): PeakDraft {
  return {
    id: nextPeakId(),
    name,
    t,
    standards: [blankStandard('动作标准 1')],
  }
}

const ruleForm = reactive({
  title: '',
  visibility: 0.45,
  hold: 300,
  cycleStart: null as number | null,
  cycleEnd: null as number | null,
  peaks: [blankPeak('关键点 1')] as PeakDraft[],
})
const playerRef = ref<HTMLVideoElement | null>(null)
const playhead = ref(0)
let ruleLoadSeq = 0
let suppressJsonSync = 0

const selected = computed(
  () => videos.value.find((v) => v.video_id === selectedId.value) ?? null,
)

const joints = computed(() => {
  const set = new Set<string>()
  for (const v of videos.value) {
    if (v.target_joint) set.add(String(v.target_joint))
  }
  return [...set].sort()
})

const severities = computed(() => {
  const set = new Set<string>()
  for (const v of videos.value) {
    if (v.severity) set.add(String(v.severity))
  }
  return [...set].sort()
})

const filtered = computed(() => {
  const q = search.value.trim().toLowerCase()
  return videos.value.filter((v) => {
    if (filterJoint.value && v.target_joint !== filterJoint.value) return false
    if (filterSeverity.value && v.severity !== filterSeverity.value) return false
    if (!q) return true
    const hay = [
      v.video_id,
      v.description_cn,
      v.file_name,
      ...(v.action_keywords || []),
      ...(v.symptom_tags || []),
    ]
      .filter(Boolean)
      .join(' ')
      .toLowerCase()
    return hay.includes(q)
  })
})

const metaRows = computed(() => {
  const v = selected.value
  if (!v) return []
  return [
    { label: 'video_id', value: v.video_id },
    { label: '目标关节', value: v.target_joint },
    { label: '严重程度', value: v.severity },
    { label: '康复阶段', value: v.rehab_stage },
    { label: '难度', value: v.difficulty != null ? String(v.difficulty) : undefined },
    { label: '时长(秒)', value: v.duration_seconds != null ? String(v.duration_seconds) : undefined },
    { label: '器械', value: v.equipment },
    { label: '空间', value: v.space_required },
    { label: '安全等级', value: v.safety_level },
    { label: '文件名', value: v.file_name },
    { label: '播放路径', value: v.url || '（MinIO 未找到文件）' },
  ].filter((r) => r.value != null && r.value !== '')
})

async function load() {
  busy.value = true
  error.value = ''
  try {
    const data = await fetchVideos({ limit: 500 })
    videos.value = data.videos || []
    try {
      const rules = await fetchMotionRuleIds()
      ruleIds.value = new Set(rules.video_ids || [])
    } catch {
      ruleIds.value = new Set()
    }
    if (!selectedId.value && videos.value.length) {
      selectedId.value = videos.value[0].video_id
    } else if (selectedId.value && !videos.value.some((v) => v.video_id === selectedId.value)) {
      selectedId.value = videos.value[0]?.video_id || ''
    }
  } catch (err) {
    error.value = String(err)
    videos.value = []
  } finally {
    busy.value = false
  }
}

function selectVideo(id: string) {
  selectedId.value = id
}

function defaultTitle(video: VideoItem | null, videoId: string) {
  const keyword = video?.action_keywords?.find(Boolean)
  return keyword || video?.description_cn || videoId
}

function metricFromStandard(standard: StandardDraft) {
  const passOp = standard.passOp === 'lte' ? 'lte' : 'gte'
  const definition =
    standard.kind === 'angle_3point'
      ? {
          kind: standard.kind,
          output: standard.output,
          from: null,
          to: null,
          points: [standard.pointA, standard.pointB, standard.pointC],
        }
      : {
          kind: standard.kind,
          output: standard.output,
          from: standard.from,
          to: standard.to,
          points: [],
        }
  return {
    id: standard.id,
    name_cn: standard.name || standard.id,
    enabled: true,
    weight: 1,
    definition,
    pass: { op: passOp, value: Number(standard.pass) },
    excellent: { op: passOp, value: Number(standard.excellent) },
    attempt: { op: passOp, value: Number(standard.pass) / 2 },
    reset: { op: passOp === 'gte' ? 'lte' : 'gte', value: Number(standard.reset) },
    fail_hint: standard.hint,
  }
}

function formRule() {
  const timedPeaks = ruleForm.peaks
    .filter((peak) => peak.t != null)
    .slice()
    .sort((a, b) => Number(a.t) - Number(b.t))
  const standards = ruleForm.peaks.flatMap((peak) => peak.standards)
  const points = [
    ruleForm.cycleStart == null ? null : { role: 'cycle_start', t: ruleForm.cycleStart },
    ...timedPeaks.map((peak) => ({
      role: 'peak',
      id: peak.id,
      name_cn: peak.name,
      metric_ids: peak.standards.map((standard) => standard.id),
      ...(peak.standards[0] ? { metric_id: peak.standards[0].id } : {}),
      t: peak.t,
    })),
    ruleForm.cycleEnd == null ? null : { role: 'cycle_end', t: ruleForm.cycleEnd },
  ].filter((item) => item != null)
  return {
    title_cn: ruleForm.title || selectedId.value,
    min_visibility: Number(ruleForm.visibility),
    metrics: standards.map(metricFromStandard),
    rep_logic: {
      required_metric_ids: standards.map((standard) => standard.id),
      hold_ms: Number(ruleForm.hold),
    },
    keyframes: { points },
  }
}

function formatClock(seconds: number | null) {
  if (seconds == null || Number.isNaN(seconds)) return '未设定'
  const sign = seconds < 0 ? '-' : ''
  const abs = Math.abs(seconds)
  const min = Math.floor(abs / 60)
  const sec = abs - min * 60
  return `${sign}${min}:${sec.toFixed(2).padStart(5, '0')}`
}

const cycleReady = computed(() => {
  const start = ruleForm.cycleStart
  const end = ruleForm.cycleEnd
  const times = ruleForm.peaks.map((peak) => peak.t)
  const any = start != null || end != null || times.some((time) => time != null)
  if (!any) return true
  if (start == null || end == null || times.some((time) => time == null)) return false
  const ordered = [start, ...times.filter((time): time is number => time != null).sort((a, b) => a - b), end]
  return ordered.every((time, index) => index === 0 || ordered[index - 1] < time)
})

function keyframeTime(rule: Record<string, unknown>, role: string) {
  const kf = rule.keyframes as { points?: Array<{ role?: string; t?: number }> } | undefined
  const found = kf?.points?.find((item) => item?.role === role)
  return typeof found?.t === 'number' ? found.t : null
}

function onPlayhead(event: Event) {
  const video = event.target as HTMLVideoElement
  playhead.value = video.currentTime || 0
}

function currentPlayhead() {
  const video = playerRef.value
  if (!video || !Number.isFinite(video.currentTime)) return null
  return Math.round(video.currentTime * 1000) / 1000
}

function rememberForm() {
  if (jsonDirty.value) {
    try {
      const rule = JSON.parse(ruleJson.value) as Record<string, unknown>
      const next = formRule()
      rule.metrics = next.metrics
      rule.keyframes = next.keyframes
      rule.rep_logic = next.rep_logic
      ruleJson.value = JSON.stringify(rule, null, 2)
      return
    } catch {
      /* 手改 JSON 已损坏时，用表单覆盖 */
    }
  }
  syncJsonFromForm()
}

function markCycle(field: 'cycleStart' | 'cycleEnd') {
  const time = currentPlayhead()
  if (time == null) {
    sayRule('请先把播放条拖到这一轮的对应画面', true)
    return
  }
  ruleForm[field] = time
  rememberForm()
  sayRule('')
}

function addPeak() {
  const time = currentPlayhead()
  if (time == null) {
    sayRule('请先把播放条拖到这个关键点', true)
    return
  }
  ruleForm.peaks.push(blankPeak(`关键点 ${ruleForm.peaks.length + 1}`, time))
  rememberForm()
  sayRule('')
}

function retimestampPeak(index: number) {
  const time = currentPlayhead()
  if (time == null) {
    sayRule('请先把播放条拖到这个关键点', true)
    return
  }
  const peak = ruleForm.peaks[index]
  if (!peak) return
  peak.t = time
  rememberForm()
  sayRule('')
}

function removePeak(index: number) {
  if (ruleForm.peaks.length <= 1) {
    sayRule('至少保留一个关键点', true)
    return
  }
  ruleForm.peaks.splice(index, 1)
  rememberForm()
  sayRule('')
}

function addStandard(peakIndex: number) {
  const peak = ruleForm.peaks[peakIndex]
  if (!peak) return
  peak.standards.push(blankStandard(`动作标准 ${peak.standards.length + 1}`))
  rememberForm()
  sayRule('')
}

function removeStandard(peakIndex: number, standardIndex: number) {
  const peak = ruleForm.peaks[peakIndex]
  if (!peak || peak.standards.length <= 1) {
    sayRule('每个关键点至少保留一条动作标准', true)
    return
  }
  peak.standards.splice(standardIndex, 1)
  rememberForm()
  sayRule('')
}

function seekCycle(seconds: number | null) {
  const video = playerRef.value
  if (!video || seconds == null) return
  video.currentTime = seconds
  playhead.value = seconds
}

function syncJsonFromForm() {
  jsonDirty.value = false
  ruleJson.value = JSON.stringify(formRule(), null, 2)
}

function standardFromStored(metric: Record<string, unknown>, id: string): StandardDraft {
  const definition = (metric.definition || {}) as Record<string, unknown>
  const pass = (metric.pass || {}) as Record<string, unknown>
  const excellent = (metric.excellent || {}) as Record<string, unknown>
  const reset = (metric.reset || {}) as Record<string, unknown>
  const joints = Array.isArray(definition.points) ? definition.points.map(String) : []
  standardSerial = noteSerial(id, 'std', standardSerial)
  return {
    id,
    name: String(metric.name_cn || id),
    kind: String(definition.kind || 'segment_to_axis'),
    output: String(definition.output || 'degrees_from_down'),
    from: String(definition.from || 'right_hip'),
    to: String(definition.to || 'right_ankle'),
    pointA: joints[0] || 'left_hip',
    pointB: joints[1] || 'left_knee',
    pointC: joints[2] || 'left_ankle',
    passOp: pass.op === 'lte' ? 'lte' : 'gte',
    pass: Number(pass.value ?? 40),
    excellent: Number(excellent.value ?? 50),
    reset: Number(reset.value ?? 15),
    hint: String(metric.fail_hint || '请再接近合格线一些'),
  }
}

function standardsForPoint(point: Record<string, unknown>, metrics: Record<string, unknown>[], index: number) {
  if (Array.isArray(point.metric_ids) && point.metric_ids.length === 0 && !point.metric_id) return []
  const listed = Array.isArray(point.metric_ids) ? point.metric_ids.map(String).filter(Boolean) : []
  const ids = listed.length
    ? listed
    : [String(point.metric_id || point.id || metrics[index]?.id || '')].filter(Boolean)
  return (ids.length ? ids : ['']).map((id) => {
    const metric = metrics.find((item) => String(item.id || '') === id) || metrics[index] || {}
    return standardFromStored(metric, id || nextStandardId())
  })
}

function fillRuleForm(rule: Record<string, unknown>, videoId: string) {
  suppressJsonSync += 1
  const metrics = (Array.isArray(rule.metrics) ? rule.metrics : []) as Record<string, unknown>[]
  const logic = (rule.rep_logic || {}) as Record<string, unknown>
  const kf = rule.keyframes as { points?: Array<Record<string, unknown>> } | undefined
  const storedPoints = Array.isArray(kf?.points) ? kf.points : []
  const peakPoints = storedPoints.filter((item) => item.role === 'peak' || item.role === 'wait_peak')
  ruleForm.title = String(rule.title_cn || defaultTitle(selected.value, videoId))
  ruleForm.visibility = Number(rule.min_visibility ?? 0.45)
  ruleForm.hold = Number(logic.hold_ms ?? 300)
  ruleForm.cycleStart = keyframeTime(rule, 'cycle_start')
  ruleForm.cycleEnd = keyframeTime(rule, 'cycle_end')
  const peaks = peakPoints.length
    ? peakPoints.map((point, index) => {
        const id = String(point.id || point.metric_id || `peak_${index + 1}`)
        peakSerial = noteSerial(id, 'peak', peakSerial)
        return {
          id,
          name: String(point.name_cn || `关键点 ${index + 1}`),
          t: typeof point.t === 'number' ? point.t : null,
          standards: standardsForPoint(point, metrics, index),
        }
      })
    : (metrics.length ? metrics : [{}]).map((metric, index) => {
        const id = `peak_${index + 1}`
        peakSerial = noteSerial(id, 'peak', peakSerial)
        const standardId = String(metric.id || '') || nextStandardId()
        return {
          id,
          name: `关键点 ${index + 1}`,
          t: index === 0 ? keyframeTime(rule, 'wait_peak') : null,
          standards: [standardFromStored(metric, standardId)],
        }
      })
  ruleForm.peaks.splice(0, ruleForm.peaks.length, ...peaks)
  jsonDirty.value = false
  ruleJson.value = JSON.stringify(rule, null, 2)
  void nextTick(() => {
    suppressJsonSync = Math.max(0, suppressJsonSync - 1)
  })
}

function resetRuleForm(videoId: string) {
  fillRuleForm(
    {
      title_cn: defaultTitle(selected.value, videoId),
      min_visibility: 0.45,
      metrics: [
        {
          name_cn: '主动作',
          definition: {
            kind: 'segment_to_axis',
            output: 'degrees_from_down',
            from: 'right_hip',
            to: 'right_ankle',
          },
          pass: { op: 'gte', value: 40 },
          excellent: { value: 50 },
          reset: { value: 15 },
          fail_hint: '请再接近合格线一些',
        },
      ],
      rep_logic: { hold_ms: 300 },
    },
    videoId,
  )
  syncJsonFromForm()
}

function sayRule(text: string, isError = false) {
  ruleMessage.value = text
  ruleIsError.value = isError
}

async function loadRule(videoId: string) {
  const seq = ++ruleLoadSeq
  ruleBusy.value = true
  sayRule('')
  try {
    const data = await fetchMotionRule(videoId)
    if (seq !== ruleLoadSeq) return
    if (!data?.rule) {
      resetRuleForm(videoId)
      sayRule('这个视频还没有规则。保存后，用户跟做才会按这里的标准打实时分。')
      return
    }
    fillRuleForm(data.rule, videoId)
    const standards = Array.isArray(data.rule.metrics) ? data.rule.metrics.length : 0
    const points = (data.rule.keyframes as { points?: unknown[] } | undefined)?.points
    const peaks = Array.isArray(points)
      ? points.filter((item) => {
          const role = (item as { role?: string }).role
          return role === 'peak' || role === 'wait_peak'
        }).length
      : 0
    sayRule(
      standards > 1
        ? `已载入当前规则，${Math.max(peaks, 1)} 个关键点，共 ${standards} 条动作标准。`
        : '已载入当前规则。',
    )
  } catch (err) {
    if (seq !== ruleLoadSeq) return
    sayRule(err instanceof Error ? err.message : String(err), true)
  } finally {
    if (seq === ruleLoadSeq) ruleBusy.value = false
  }
}

async function saveRule() {
  const videoId = selectedId.value
  if (!videoId) return
  if (!cycleReady.value) {
    sayRule('开始、每个关键点和结束都要设定，并且时间不能重叠。也可以先都不设定。', true)
    return
  }
  let rule: Record<string, unknown>
  try {
    rule = JSON.parse(ruleJson.value) as Record<string, unknown>
  } catch {
    sayRule('JSON 无法解析', true)
    return
  }
  ruleBusy.value = true
  try {
    const data = await saveMotionRule(videoId, rule)
    fillRuleForm(data.rule, videoId)
    ruleIds.value = new Set([...ruleIds.value, videoId])
    sayRule('已保存。下次跟做会按这份规则打分。')
  } catch (err) {
    sayRule(err instanceof Error ? err.message : String(err), true)
  } finally {
    ruleBusy.value = false
  }
}

async function removeRule() {
  const videoId = selectedId.value
  if (!videoId) return
  ruleBusy.value = true
  try {
    await deleteMotionRule(videoId)
    const next = new Set(ruleIds.value)
    next.delete(videoId)
    ruleIds.value = next
    resetRuleForm(videoId)
    sayRule('已删除。这个视频跟做时只显示骨架。')
  } catch (err) {
    sayRule(err instanceof Error ? err.message : String(err), true)
  } finally {
    ruleBusy.value = false
  }
}

function onRuleJsonInput() {
  jsonDirty.value = true
}

function asList(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value.map(String).filter(Boolean)
}

function formatBytes(n: number) {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / (1024 * 1024)).toFixed(1)} MB`
}

function clearUploadPreview() {
  if (uploadPreviewUrl.value) {
    URL.revokeObjectURL(uploadPreviewUrl.value)
    uploadPreviewUrl.value = ''
  }
  uploadFile.value = null
}

function openUpload() {
  uploadOpen.value = true
  uploadNote.value = ''
  uploadDragging.value = false
}

function closeUpload() {
  uploadOpen.value = false
  uploadDragging.value = false
  uploadNote.value = ''
  clearUploadPreview()
  uploadForm.value = {
    video_id: '',
    target_joint: '',
    severity: '轻度',
    difficulty: 2,
    description_cn: '',
  }
  if (fileInputRef.value) fileInputRef.value.value = ''
}

function pickFile(file: File | undefined | null) {
  if (!file) return
  if (!file.type.startsWith('video/') && !/\.(mp4|webm|mov|m4v)$/i.test(file.name)) {
    uploadNote.value = '请选择视频文件（mp4 / webm / mov）'
    return
  }
  clearUploadPreview()
  uploadFile.value = file
  uploadPreviewUrl.value = URL.createObjectURL(file)
  uploadNote.value = ''
  if (!uploadForm.value.video_id) {
    uploadForm.value.video_id = file.name.replace(/\.[^.]+$/, '')
  }
}

function onFileInput(e: Event) {
  const input = e.target as HTMLInputElement
  pickFile(input.files?.[0])
}

function onDrop(e: DragEvent) {
  e.preventDefault()
  uploadDragging.value = false
  pickFile(e.dataTransfer?.files?.[0])
}

function submitUploadDemo() {
  if (!uploadFile.value) {
    uploadNote.value = '请先选择视频文件'
    return
  }
  uploadNote.value = `已选择「${uploadFile.value.name}」（${formatBytes(uploadFile.value.size)}）。当前为展示模式，尚未上传或落库。`
}

watch(
  ruleForm,
  () => {
    if (suppressJsonSync > 0 || jsonDirty.value) return
    syncJsonFromForm()
  },
  { deep: true },
)

watch(selectedId, (id) => {
  playhead.value = 0
  if (id) void loadRule(id)
})

watch(filtered, (list) => {
  if (!list.length) return
  if (!list.some((v) => v.video_id === selectedId.value)) {
    selectedId.value = list[0].video_id
  }
})

onMounted(load)

onBeforeUnmount(() => {
  clearUploadPreview()
})
</script>

<template>
  <div class="wrap">
    <header class="page-head">
      <div>
        <h1>视频库</h1>
        <p class="sub">
          视频来自 core-svc。选中一条后，可以在右侧设定跟做时的实时评分规则。
        </p>
      </div>
      <div class="head-actions">
        <span class="count">{{ filtered.length }} / {{ videos.length }}</span>
        <button type="button" class="btn" :disabled="busy" @click="load">刷新</button>
        <button type="button" class="btn btn-primary" @click="openUpload">上传视频</button>
      </div>
    </header>

    <div v-if="error" class="banner err">{{ error }}</div>

    <div
      v-if="uploadOpen"
      class="modal-backdrop"
      @click.self="closeUpload"
      @keydown.esc="closeUpload"
    >
      <div class="modal" role="dialog" aria-modal="true" aria-labelledby="upload-title">
        <header class="modal-head">
          <div>
            <h2 id="upload-title">上传视频</h2>
            <p class="modal-sub">当前仅做界面展示，不会写入数据库或对象存储。</p>
          </div>
          <button type="button" class="btn-icon" aria-label="关闭" @click="closeUpload">×</button>
        </header>

        <div class="modal-body">
          <div
            class="dropzone"
            :class="{ dragging: uploadDragging, filled: !!uploadFile }"
            @click="fileInputRef?.click()"
            @dragenter.prevent="uploadDragging = true"
            @dragover.prevent="uploadDragging = true"
            @dragleave.prevent="uploadDragging = false"
            @drop="onDrop"
          >
            <input
              ref="fileInputRef"
              type="file"
              accept="video/*,.mp4,.webm,.mov,.m4v"
              hidden
              @change="onFileInput"
            />
            <template v-if="!uploadFile">
              <div class="drop-title">拖拽视频到此处，或点击选择文件</div>
              <div class="drop-hint">支持 mp4 / webm / mov</div>
            </template>
            <template v-else>
              <div class="drop-title">{{ uploadFile.name }}</div>
              <div class="drop-hint">
                {{ formatBytes(uploadFile.size) }}
                <span v-if="uploadFile.type"> · {{ uploadFile.type }}</span>
                · 点击可更换
              </div>
            </template>
          </div>

          <video
            v-if="uploadPreviewUrl"
            class="upload-preview"
            :src="uploadPreviewUrl"
            controls
            preload="metadata"
          />

          <div class="upload-fields">
            <label>
              <span>video_id</span>
              <input v-model="uploadForm.video_id" type="text" placeholder="默认取文件名（不含扩展名）" />
            </label>
            <label>
              <span>目标关节</span>
              <input v-model="uploadForm.target_joint" type="text" placeholder="如：髋部、肩部" list="joint-options" />
              <datalist id="joint-options">
                <option v-for="j in joints" :key="j" :value="j" />
              </datalist>
            </label>
            <label>
              <span>严重程度</span>
              <select v-model="uploadForm.severity">
                <option value="轻度">轻度</option>
                <option value="中度">中度</option>
                <option value="重度">重度</option>
              </select>
            </label>
            <label>
              <span>难度</span>
              <input v-model.number="uploadForm.difficulty" type="number" min="1" max="5" />
            </label>
            <label class="span-2">
              <span>描述</span>
              <textarea
                v-model="uploadForm.description_cn"
                rows="3"
                placeholder="简要说明动作要点…"
              />
            </label>
          </div>

          <p v-if="uploadNote" class="upload-note">{{ uploadNote }}</p>
        </div>

        <footer class="modal-foot">
          <button type="button" class="btn" @click="closeUpload">取消</button>
          <button type="button" class="btn btn-primary" @click="submitUploadDemo">确认</button>
        </footer>
      </div>
    </div>

    <div class="workspace">
      <aside class="list-panel">
        <div class="filters">
          <input v-model="search" type="search" placeholder="搜索 ID / 描述 / 关键词…" />
          <select v-model="filterJoint">
            <option value="">全部关节</option>
            <option v-for="j in joints" :key="j" :value="j">{{ j }}</option>
          </select>
          <select v-model="filterSeverity">
            <option value="">全部严重度</option>
            <option v-for="s in severities" :key="s" :value="s">{{ s }}</option>
          </select>
        </div>

        <div v-if="busy && !videos.length" class="empty">加载中…</div>
        <div v-else-if="!filtered.length" class="empty">无匹配视频</div>
        <ul v-else class="video-list">
          <li
            v-for="v in filtered"
            :key="v.video_id"
            :class="{ active: v.video_id === selectedId, offline: !v.url }"
            @click="selectVideo(v.video_id)"
          >
            <div class="vid-id">{{ v.video_id }}</div>
            <div class="vid-meta">
              <span>{{ v.target_joint || '—' }}</span>
              <span>{{ v.severity || '—' }}</span>
              <span v-if="v.difficulty != null">D{{ v.difficulty }}</span>
              <span v-if="!v.url" class="warn">无文件</span>
            </div>
            <div class="vid-desc">{{ v.description_cn || v.file_name || '' }}</div>
            <span v-if="ruleIds.has(v.video_id)" class="rule-tag">已有规则</span>
          </li>
        </ul>
      </aside>

      <main class="detail-panel">
        <template v-if="selected">
          <section class="player-card">
            <div class="player-title">
              <h2>{{ selected.video_id }}</h2>
              <p>{{ selected.description_cn || '暂无描述' }}</p>
            </div>
            <div v-if="selected.url" class="player-layout">
            <div class="player-frame">
              <video
                :key="selected.video_id"
                ref="playerRef"
                class="player"
                :src="playUrl(selected)"
                controls
                preload="metadata"
                @timeupdate="onPlayhead"
              />
            </div>
            <div class="cycle-bar">
              <p class="cycle-lead">
                拖到对应画面后点「记为当前画面」。左右交替可以添加多个关键点。当前
                {{ formatClock(playhead) }}
              </p>
              <div class="cycle-points">
                <div class="cycle-row">
                  <span class="peak-label">开始</span>
                  <button type="button" class="btn cycle-mark" @click="markCycle('cycleStart')">记为当前画面</button>
                  <button
                    type="button"
                    class="time-chip"
                    :disabled="ruleForm.cycleStart == null"
                    @click="seekCycle(ruleForm.cycleStart)"
                  >
                    {{ formatClock(ruleForm.cycleStart) }}
                  </button>
                </div>
                <div v-for="(peak, index) in ruleForm.peaks" :key="peak.id" class="cycle-row">
                  <span class="peak-label" :title="peak.name || `关键点 ${index + 1}`">
                    {{ peak.name || `关键点 ${index + 1}` }}
                  </span>
                  <button type="button" class="btn cycle-mark" @click="retimestampPeak(index)">记为当前画面</button>
                  <button
                    type="button"
                    class="time-chip"
                    :disabled="peak.t == null"
                    @click="seekCycle(peak.t)"
                  >
                    {{ formatClock(peak.t) }}
                  </button>
                  <button type="button" class="btn danger" @click="removePeak(index)">移除</button>
                </div>
                <div class="cycle-row">
                  <span class="peak-label">结束</span>
                  <button type="button" class="btn cycle-mark" @click="markCycle('cycleEnd')">记为当前画面</button>
                  <button
                    type="button"
                    class="time-chip"
                    :disabled="ruleForm.cycleEnd == null"
                    @click="seekCycle(ruleForm.cycleEnd)"
                  >
                    {{ formatClock(ruleForm.cycleEnd) }}
                  </button>
                </div>
              </div>
              <button type="button" class="btn" @click="addPeak">在当前画面添加关键点</button>
              <p v-if="!cycleReady" class="rule-message error">
                开始、每个关键点和结束都要设定，并且按这个时间顺序排列。
              </p>
            </div>
            </div>
            <div v-else class="player-missing">MinIO 中未找到该视频文件，无法预览。</div>
          </section>

          <section class="meta-card">
            <h3>元数据</h3>
            <dl class="meta-grid">
              <template v-for="row in metaRows" :key="row.label">
                <dt>{{ row.label }}</dt>
                <dd>{{ row.value }}</dd>
              </template>
            </dl>

            <div v-if="asList(selected.target_body_parts).length" class="chip-block">
              <h4>目标部位</h4>
              <div class="chips">
                <span v-for="t in asList(selected.target_body_parts)" :key="t" class="chip">{{ t }}</span>
              </div>
            </div>
            <div v-if="asList(selected.action_keywords).length" class="chip-block">
              <h4>动作关键词</h4>
              <div class="chips">
                <span v-for="t in asList(selected.action_keywords)" :key="t" class="chip">{{ t }}</span>
              </div>
            </div>
            <div v-if="asList(selected.symptom_tags).length" class="chip-block">
              <h4>症状标签</h4>
              <div class="chips">
                <span v-for="t in asList(selected.symptom_tags)" :key="t" class="chip">{{ t }}</span>
              </div>
            </div>
            <div v-if="asList(selected.contraindications).length" class="chip-block">
              <h4>禁忌</h4>
              <div class="chips warn">
                <span v-for="t in asList(selected.contraindications)" :key="t" class="chip">{{ t }}</span>
              </div>
            </div>
            <div v-if="asList(selected.pose_landmarks_required).length" class="chip-block">
              <h4>姿态关键点</h4>
              <div class="chips">
                <span
                  v-for="t in asList(selected.pose_landmarks_required)"
                  :key="t"
                  class="chip mono"
                  >{{ t }}</span
                >
              </div>
            </div>

            <details class="raw">
              <summary>原始 JSON</summary>
              <pre>{{ JSON.stringify(selected, null, 2) }}</pre>
            </details>
          </section>

          <section class="meta-card rule-card">
            <h3>实时评分规则</h3>
            <p class="rule-lead">
              同一个关键点可以同时要求多条动作标准，比如胳膊、腿和躯干一起到位。不同关键点按时间先后出现。没有规则时，跟做只显示骨架。
            </p>
            <div class="rule-grid">
              <label>动作名称<input v-model="ruleForm.title" type="text" /></label>
              <label>最低可见度 0–1<input v-model.number="ruleForm.visibility" type="number" step="0.05" /></label>
              <label>保持毫秒<input v-model.number="ruleForm.hold" type="number" step="50" /></label>
            </div>
            <article v-for="(peak, index) in ruleForm.peaks" :key="peak.id" class="peak-card">
              <h4>{{ peak.name || `关键点 ${index + 1}` }} · {{ formatClock(peak.t) }}</h4>
              <label class="rule-span">这个关键点的名称<input v-model="peak.name" type="text" /></label>
              <article v-for="(standard, standardIndex) in peak.standards" :key="standard.id" class="standard-card">
                <div class="standard-head">
                  <h5>{{ standard.name || `动作标准 ${standardIndex + 1}` }}</h5>
                  <button
                    v-if="peak.standards.length > 1"
                    type="button"
                    class="btn danger"
                    @click="removeStandard(index, standardIndex)"
                  >
                    移除这条标准
                  </button>
                </div>
                <div class="rule-grid">
                  <label>这条标准的名称<input v-model="standard.name" type="text" /></label>
                  <label>
                    计算方式
                    <select v-model="standard.kind">
                      <option value="segment_to_axis">两点相对竖直方向的夹角</option>
                      <option value="angle_3point">三个关节点的夹角</option>
                    </select>
                  </label>
                  <label>
                    角度含义
                    <select v-model="standard.output">
                      <option value="degrees_from_down">相对竖直向下，抬得越高角度越大</option>
                      <option value="degrees_from_vertical">与竖直线的夹角，最大 90°</option>
                      <option value="abs_degrees_from_vertical">竖直线夹角的绝对值</option>
                    </select>
                  </label>
                  <template v-if="standard.kind === 'segment_to_axis'">
                    <label>
                      起点
                      <select v-model="standard.from">
                        <option v-for="name in LANDMARKS" :key="standard.id + name" :value="name">{{ name }}</option>
                      </select>
                    </label>
                    <label>
                      终点
                      <select v-model="standard.to">
                        <option v-for="name in LANDMARKS" :key="standard.id + '-to-' + name" :value="name">{{ name }}</option>
                      </select>
                    </label>
                  </template>
                  <template v-else>
                    <label>
                      关节点 1
                      <select v-model="standard.pointA">
                        <option v-for="name in LANDMARKS" :key="standard.id + '-a-' + name" :value="name">{{ name }}</option>
                      </select>
                    </label>
                    <label>
                      关节点 2（顶点）
                      <select v-model="standard.pointB">
                        <option v-for="name in LANDMARKS" :key="standard.id + '-b-' + name" :value="name">{{ name }}</option>
                      </select>
                    </label>
                    <label>
                      关节点 3
                      <select v-model="standard.pointC">
                        <option v-for="name in LANDMARKS" :key="standard.id + '-c-' + name" :value="name">{{ name }}</option>
                      </select>
                    </label>
                  </template>
                  <label>合格线<input v-model.number="standard.pass" type="number" step="1" /></label>
                  <label>
                    合格比较
                    <select v-model="standard.passOp">
                      <option value="gte">大于等于</option>
                      <option value="lte">小于等于</option>
                    </select>
                  </label>
                  <label>优秀线<input v-model.number="standard.excellent" type="number" step="1" /></label>
                  <label>回到起始的复位线<input v-model.number="standard.reset" type="number" step="1" /></label>
                </div>
                <label class="rule-span">没做到时的提示<input v-model="standard.hint" type="text" /></label>
              </article>
              <button type="button" class="btn" @click="addStandard(index)">为这个关键点添加动作标准</button>
            </article>
            <label class="rule-span">
              结构化规则 JSON。改表单会更新这里；直接改 JSON 后，保存以 JSON 为准。
              <textarea v-model="ruleJson" rows="12" spellcheck="false" @input="onRuleJsonInput" />
            </label>
            <p class="rule-message" :class="{ error: ruleIsError }">{{ ruleMessage }}</p>
            <div class="rule-actions">
              <button type="button" class="btn btn-primary" :disabled="ruleBusy" @click="saveRule">保存规则</button>
              <button type="button" class="btn" :disabled="ruleBusy" @click="syncJsonFromForm">用表单更新 JSON</button>
              <button type="button" class="btn danger" :disabled="ruleBusy" @click="removeRule">删除规则</button>
            </div>
          </section>
        </template>
        <div v-else class="empty detail-empty">选择左侧视频以预览</div>
      </main>
    </div>
  </div>
</template>

<style scoped>
.wrap {
  height: 100%;
  min-height: 0;
  display: flex;
  flex-direction: column;
  padding: 16px 18px 18px;
  gap: 12px;
  overflow: hidden;
}
.page-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 12px;
  flex: 0 0 auto;
}
h1 {
  margin: 0 0 4px;
  font-size: 1.35rem;
  font-weight: 600;
}
.sub {
  margin: 0;
  color: var(--muted);
  font-size: 0.86rem;
}
.sub code {
  font-family: Consolas, Menlo, monospace;
  font-size: 0.85em;
}
.head-actions {
  display: flex;
  align-items: center;
  gap: 10px;
}
.count {
  color: var(--muted);
  font-size: 0.85rem;
  font-variant-numeric: tabular-nums;
}
.btn {
  padding: 8px 14px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--panel);
  color: var(--fg);
  font: inherit;
  cursor: pointer;
}
.btn:hover:not(:disabled) {
  border-color: var(--primary);
  color: var(--primary);
}
.btn:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}
.btn-primary {
  background: var(--primary);
  border-color: var(--primary);
  color: #041512;
  font-weight: 600;
}
.btn-primary:hover:not(:disabled) {
  filter: brightness(1.08);
  color: #041512;
  border-color: var(--primary);
}
.modal-backdrop {
  position: fixed;
  inset: 0;
  z-index: 40;
  background: rgba(6, 10, 18, 0.72);
  display: grid;
  place-items: center;
  padding: 20px;
}
.modal {
  width: min(640px, 100%);
  max-height: min(90vh, 860px);
  display: flex;
  flex-direction: column;
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 12px;
  box-shadow: 0 18px 50px rgba(0, 0, 0, 0.45);
  overflow: hidden;
}
.modal-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 12px;
  padding: 16px 18px 12px;
  border-bottom: 1px solid var(--line);
  flex: 0 0 auto;
}
.modal-head h2 {
  margin: 0 0 4px;
  font-size: 1.1rem;
}
.modal-sub {
  margin: 0;
  color: var(--muted);
  font-size: 0.82rem;
}
.btn-icon {
  width: 32px;
  height: 32px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: transparent;
  color: var(--muted);
  font-size: 1.25rem;
  line-height: 1;
  cursor: pointer;
}
.btn-icon:hover {
  color: var(--fg);
  border-color: #3a4a68;
}
.modal-body {
  padding: 16px 18px;
  overflow: auto;
  display: flex;
  flex-direction: column;
  gap: 14px;
  flex: 1;
  min-height: 0;
}
.dropzone {
  border: 1px dashed #3a4a68;
  border-radius: 10px;
  padding: 28px 16px;
  text-align: center;
  cursor: pointer;
  background: #0f1624;
  transition: border-color 0.15s, background 0.15s;
}
.dropzone:hover,
.dropzone.dragging {
  border-color: var(--primary);
  background: #12201f;
}
.dropzone.filled {
  border-style: solid;
  border-color: #2a4a45;
}
.drop-title {
  font-size: 0.95rem;
  font-weight: 600;
  word-break: break-all;
}
.drop-hint {
  margin-top: 6px;
  color: var(--muted);
  font-size: 0.8rem;
}
.upload-preview {
  width: 100%;
  max-height: 240px;
  background: #000;
  border-radius: 8px;
  display: block;
}
.upload-fields {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px;
}
.upload-fields label {
  display: flex;
  flex-direction: column;
  gap: 6px;
  font-size: 0.78rem;
  color: var(--muted);
}
.upload-fields label.span-2 {
  grid-column: 1 / -1;
}
.upload-fields input,
.upload-fields select,
.upload-fields textarea {
  width: 100%;
  padding: 8px 10px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--bg);
  color: var(--fg);
  font: inherit;
  font-size: 0.9rem;
}
.upload-fields textarea {
  resize: vertical;
}
.upload-note {
  margin: 0;
  padding: 10px 12px;
  border-radius: 8px;
  background: #1a2430;
  border: 1px solid #2a3d52;
  color: #c9d4e8;
  font-size: 0.85rem;
  line-height: 1.45;
}
.modal-foot {
  display: flex;
  justify-content: flex-end;
  gap: 10px;
  padding: 12px 18px 16px;
  border-top: 1px solid var(--line);
  flex: 0 0 auto;
}
@media (max-width: 560px) {
  .upload-fields {
    grid-template-columns: 1fr;
  }
}
.banner {
  padding: 10px 12px;
  border-radius: 8px;
  font-size: 0.88rem;
  flex: 0 0 auto;
}
.banner.err {
  background: #2a1518;
  border: 1px solid #5c2430;
  color: var(--red);
}
.workspace {
  flex: 1;
  min-height: 0;
  display: grid;
  grid-template-columns: minmax(260px, 340px) 1fr;
  gap: 12px;
}
.list-panel,
.detail-panel {
  min-height: 0;
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 10px;
  overflow: hidden;
}
.list-panel {
  display: flex;
  flex-direction: column;
}
.filters {
  display: grid;
  gap: 8px;
  padding: 12px;
  border-bottom: 1px solid var(--line);
  flex: 0 0 auto;
}
.filters input,
.filters select {
  width: 100%;
  padding: 8px 10px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--bg);
  color: var(--fg);
  font: inherit;
}
.video-list {
  list-style: none;
  margin: 0;
  padding: 6px;
  overflow: auto;
  flex: 1;
}
.video-list li {
  padding: 10px 12px;
  border-radius: 8px;
  cursor: pointer;
  border: 1px solid transparent;
  margin-bottom: 4px;
}
.video-list li:hover {
  background: #132033;
}
.video-list li.active {
  background: #13262a;
  border-color: #1f4a45;
}
.video-list li.offline .vid-id {
  color: var(--muted);
}
.vid-id {
  font-weight: 600;
  font-size: 0.92rem;
}
.vid-meta {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin-top: 4px;
  font-size: 0.75rem;
  color: var(--muted);
}
.vid-meta .warn {
  color: var(--yellow);
}
.vid-desc {
  margin-top: 4px;
  font-size: 0.78rem;
  color: #7f8eab;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
.rule-tag {
  display: inline-block;
  margin-top: 6px;
  padding: 1px 6px;
  border-radius: 999px;
  background: #12352c;
  color: #7ddec4;
  font-size: 0.72rem;
}
.rule-lead {
  margin: 0 0 12px;
  color: var(--muted);
  font-size: 0.84rem;
  line-height: 1.45;
}
.rule-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 10px 12px;
}
.rule-grid label,
.rule-span {
  display: flex;
  flex-direction: column;
  gap: 4px;
  font-size: 0.78rem;
  color: var(--muted);
}
.rule-span {
  margin-top: 10px;
}
.rule-grid input,
.rule-grid select,
.rule-span input,
.rule-span textarea {
  width: 100%;
  padding: 8px 10px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--panel);
  color: var(--fg);
  font: inherit;
  font-size: 0.88rem;
}
.rule-span textarea {
  font-family: Consolas, Menlo, monospace;
  font-size: 0.78rem;
  resize: vertical;
}
.rule-message {
  min-height: 1.2em;
  margin: 10px 0 0;
  color: #7ddec4;
  font-size: 0.84rem;
}
.rule-message.error {
  color: var(--red);
}
.rule-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin-top: 12px;
}
.btn.danger {
  color: #ffb4ab;
  border-color: #5c2430;
}
@media (max-width: 800px) {
  .rule-grid {
    grid-template-columns: 1fr;
  }
}
.detail-panel {
  overflow: auto;
  padding: 14px;
  display: flex;
  flex-direction: column;
  gap: 14px;
}
.player-card,
.meta-card {
  background: var(--bg);
  border: 1px solid var(--line);
  border-radius: 10px;
  padding: 14px;
}
.player-title h2 {
  margin: 0 0 6px;
  font-size: 1.1rem;
}
.player-title p {
  margin: 0 0 12px;
  color: var(--muted);
  font-size: 0.9rem;
  line-height: 1.45;
}
.player-layout {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-start;
  gap: 16px 20px;
}
.player-frame {
  flex: 0 1 auto;
  max-width: 100%;
}
.player {
  width: auto;
  height: auto;
  max-width: 100%;
  max-height: min(52vh, 480px);
  background: #111820;
  border-radius: 8px;
  display: block;
}
.cycle-bar {
  flex: 1 1 22em;
  min-width: min(100%, 22em);
  margin-top: 0;
}
.cycle-lead {
  margin: 0 0 10px;
  color: var(--muted);
  font-size: 0.84rem;
  line-height: 1.45;
}
.cycle-points {
  display: flex;
  flex-direction: column;
  gap: 8px;
  margin-bottom: 10px;
}
.cycle-row {
  display: grid;
  grid-template-columns: minmax(4.5em, 7.5em) max-content 5.75em auto;
  align-items: center;
  justify-content: start;
  column-gap: 8px;
}
.cycle-mark {
  white-space: nowrap;
}
.peak-label {
  font-size: 0.84rem;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.peak-card {
  margin-top: 14px;
  padding-top: 12px;
  border-top: 1px solid var(--line);
}
.peak-card h4 {
  margin: 0 0 10px;
  font-size: 0.92rem;
}
.standard-card {
  margin: 12px 0;
  padding: 12px;
  border: 1px solid var(--line);
  border-radius: 8px;
}
.standard-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  margin-bottom: 10px;
}
.standard-head h5 {
  margin: 0;
  font-size: 0.86rem;
}
.peak-card > .btn {
  margin-top: 4px;
}
.time-chip {
  width: 100%;
  padding: 6px 8px;
  border: 1px dashed var(--line);
  border-radius: 8px;
  background: transparent;
  color: var(--fg);
  font: inherit;
  font-variant-numeric: tabular-nums;
  text-align: center;
  cursor: pointer;
}
.time-chip:disabled {
  color: var(--muted);
  cursor: default;
}
.player-missing {
  min-height: 180px;
  display: grid;
  place-items: center;
  color: var(--muted);
  border: 1px dashed var(--line);
  border-radius: 8px;
  background: #0c111b;
}
.meta-card h3 {
  margin: 0 0 12px;
  font-size: 0.95rem;
}
.meta-grid {
  display: grid;
  grid-template-columns: 120px 1fr;
  gap: 8px 12px;
  margin: 0 0 14px;
  font-size: 0.88rem;
}
.meta-grid dt {
  color: var(--muted);
}
.meta-grid dd {
  margin: 0;
  word-break: break-word;
}
.chip-block {
  margin-bottom: 12px;
}
.chip-block h4 {
  margin: 0 0 8px;
  font-size: 0.78rem;
  color: var(--muted);
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.04em;
}
.chips {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
}
.chip {
  padding: 4px 9px;
  border-radius: 999px;
  background: #1a2436;
  border: 1px solid var(--line);
  font-size: 0.78rem;
  color: #c9d4e8;
}
.chips.warn .chip {
  border-color: #5c2430;
  color: #f0a8b0;
  background: #241418;
}
.chip.mono {
  font-family: Consolas, Menlo, monospace;
}
.raw {
  margin-top: 8px;
  border-top: 1px solid var(--line);
  padding-top: 10px;
}
.raw summary {
  cursor: pointer;
  color: var(--muted);
  font-size: 0.85rem;
}
.raw pre {
  margin: 10px 0 0;
  padding: 12px;
  border-radius: 8px;
  background: #0c111b;
  border: 1px solid var(--line);
  overflow: auto;
  max-height: 320px;
  font-size: 0.78rem;
  line-height: 1.45;
  font-family: Consolas, Menlo, monospace;
}
.empty {
  padding: 24px 16px;
  color: var(--muted);
  text-align: center;
  font-size: 0.9rem;
}
.detail-empty {
  margin: auto;
}

@media (max-width: 900px) {
  .workspace {
    grid-template-columns: 1fr;
    grid-template-rows: minmax(220px, 36%) 1fr;
  }
}
</style>
