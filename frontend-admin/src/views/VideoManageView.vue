<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { fetchVideos, playUrl, type VideoItem } from '../api'

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
    const data = await fetchVideos({ limit: 200 })
    videos.value = data.videos || []
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
          来自 core-svc <code>GET /api/videos</code>，可预览播放并查看元数据。
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
            <video
              v-if="selected.url"
              :key="selected.video_id"
              class="player"
              :src="playUrl(selected)"
              controls
              preload="metadata"
            />
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
.player {
  width: 100%;
  max-height: min(52vh, 480px);
  background: #000;
  border-radius: 8px;
  display: block;
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
