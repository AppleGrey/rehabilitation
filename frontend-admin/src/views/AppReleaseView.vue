<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import {
  CORE_SVC_BASE,
  createAppRelease,
  deleteAppRelease,
  fetchAppReleases,
  publishAppRelease,
  type AppRelease,
} from '../api'

const busy = ref(false)
const error = ref('')
const note = ref('')
const releases = ref<AppRelease[]>([])

const form = ref({
  platform: 'android',
  version_name: '',
  version_code: '',
  force_update: false,
  publish: true,
  changelog: '',
})
const file = ref<File | null>(null)
const fileInputRef = ref<HTMLInputElement | null>(null)

const sorted = computed(() =>
  [...releases.value].sort((a, b) => {
    if (a.platform !== b.platform) return a.platform.localeCompare(b.platform)
    return b.version_code - a.version_code
  }),
)

function formatBytes(n: number) {
  if (!n) return '—'
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / (1024 * 1024)).toFixed(1)} MB`
}

function fmtDate(s?: string | null) {
  if (!s) return '—'
  const d = new Date(s)
  return isNaN(d.getTime()) ? String(s) : d.toLocaleString()
}

function downloadUrl(id: string) {
  return `${CORE_SVC_BASE}/api/app/releases/${encodeURIComponent(id)}/download`
}

async function load() {
  busy.value = true
  error.value = ''
  try {
    const data = await fetchAppReleases({ limit: 100 })
    releases.value = data.releases || []
  } catch (err) {
    error.value = String(err)
    releases.value = []
  } finally {
    busy.value = false
  }
}

function onFileInput(e: Event) {
  const input = e.target as HTMLInputElement
  file.value = input.files?.[0] ?? null
}

async function submit() {
  note.value = ''
  error.value = ''
  if (!form.value.version_name.trim()) {
    error.value = '请填写 version_name（如 1.0.1）'
    return
  }
  const code = Number(form.value.version_code)
  if (!Number.isInteger(code) || code <= 0) {
    error.value = 'version_code 必须是正整数（对应 Flutter +buildNumber）'
    return
  }
  if (!file.value) {
    error.value = '请选择 APK 文件'
    return
  }

  const fd = new FormData()
  fd.set('platform', form.value.platform)
  fd.set('version_name', form.value.version_name.trim())
  fd.set('version_code', String(code))
  fd.set('force_update', String(form.value.force_update))
  fd.set('publish', String(form.value.publish))
  fd.set('changelog', form.value.changelog.trim())
  fd.set('file', file.value)

  busy.value = true
  try {
    await createAppRelease(fd)
    note.value = `已上传 ${form.value.version_name}+${code}`
    form.value.version_name = ''
    form.value.version_code = ''
    form.value.changelog = ''
    form.value.force_update = false
    form.value.publish = true
    file.value = null
    if (fileInputRef.value) fileInputRef.value.value = ''
    await load()
  } catch (err) {
    error.value = String(err)
  } finally {
    busy.value = false
  }
}

async function onPublish(id: string) {
  busy.value = true
  error.value = ''
  try {
    await publishAppRelease(id)
    note.value = '已发布'
    await load()
  } catch (err) {
    error.value = String(err)
  } finally {
    busy.value = false
  }
}

async function onDelete(id: string, label: string) {
  if (!confirm(`确认删除版本 ${label}？`)) return
  busy.value = true
  error.value = ''
  try {
    await deleteAppRelease(id)
    note.value = `已删除 ${label}`
    await load()
  } catch (err) {
    error.value = String(err)
  } finally {
    busy.value = false
  }
}

onMounted(load)
</script>

<template>
  <div class="wrap">
    <header class="page-head">
      <div>
        <h1>App 版本发布</h1>
        <p class="sub">
          上传 APK 到 MinIO，客户端经 core-svc
          <code>GET /api/app/update/check</code> 检查更新。
        </p>
      </div>
      <div class="head-actions">
        <span class="count">{{ releases.length }}</span>
        <button type="button" class="btn" :disabled="busy" @click="load">刷新</button>
      </div>
    </header>

    <div v-if="error" class="banner err">{{ error }}</div>
    <div v-if="note" class="banner ok">{{ note }}</div>

    <section class="card">
      <h2>发布新版本</h2>
      <div class="form-grid">
        <label>
          <span>平台</span>
          <select v-model="form.platform">
            <option value="android">android</option>
            <option value="ios">ios</option>
          </select>
        </label>
        <label>
          <span>version_name</span>
          <input v-model="form.version_name" placeholder="1.0.1" />
        </label>
        <label>
          <span>version_code</span>
          <input v-model="form.version_code" type="number" min="1" placeholder="2" />
        </label>
        <label class="file">
          <span>安装包</span>
          <input ref="fileInputRef" type="file" accept=".apk,application/vnd.android.package-archive" @change="onFileInput" />
          <em v-if="file">{{ file.name }}（{{ formatBytes(file.size) }}）</em>
        </label>
        <label class="check">
          <input v-model="form.force_update" type="checkbox" />
          <span>强制更新</span>
        </label>
        <label class="check">
          <input v-model="form.publish" type="checkbox" />
          <span>上传后立即发布</span>
        </label>
        <label class="full">
          <span>更新说明</span>
          <textarea v-model="form.changelog" rows="3" placeholder="本次更新内容…" />
        </label>
      </div>
      <div class="form-actions">
        <button type="button" class="btn btn-primary" :disabled="busy" @click="submit">上传</button>
      </div>
    </section>

    <section class="card table-card">
      <h2>历史版本</h2>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>平台</th>
              <th>版本</th>
              <th>状态</th>
              <th>强制</th>
              <th>大小</th>
              <th>发布时间</th>
              <th>操作</th>
            </tr>
          </thead>
          <tbody>
            <tr v-if="!sorted.length">
              <td colspan="7" class="empty">暂无版本</td>
            </tr>
            <tr v-for="r in sorted" :key="r.id">
              <td>{{ r.platform }}</td>
              <td>
                <div class="ver">{{ r.version_name }}+{{ r.version_code }}</div>
                <div v-if="r.changelog" class="chg">{{ r.changelog }}</div>
              </td>
              <td>
                <span class="tag" :class="r.status">{{ r.status }}</span>
              </td>
              <td>{{ r.force_update ? '是' : '否' }}</td>
              <td>{{ formatBytes(r.file_size) }}</td>
              <td>{{ fmtDate(r.published_at || r.created_at) }}</td>
              <td class="ops">
                <a
                  v-if="r.status === 'published'"
                  class="link"
                  :href="downloadUrl(r.id)"
                  target="_blank"
                  rel="noreferrer"
                >下载</a>
                <button
                  v-if="r.status !== 'published'"
                  type="button"
                  class="linkbtn"
                  :disabled="busy"
                  @click="onPublish(r.id)"
                >发布</button>
                <button
                  type="button"
                  class="linkbtn danger"
                  :disabled="busy"
                  @click="onDelete(r.id, `${r.version_name}+${r.version_code}`)"
                >删除</button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
  </div>
</template>

<style scoped>
.wrap {
  height: 100%;
  overflow: auto;
  padding: 16px 18px 28px;
  display: flex;
  flex-direction: column;
  gap: 14px;
}
.page-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 12px;
}
.page-head h1 {
  margin: 0;
  font-size: 18px;
  color: #e6ebf5;
}
.sub {
  margin: 6px 0 0;
  font-size: 12px;
  color: #8b98b3;
}
.sub code {
  color: #9eb6d8;
}
.head-actions {
  display: flex;
  align-items: center;
  gap: 8px;
}
.count {
  font-size: 12px;
  color: #7f8eab;
  background: #182234;
  border: 1px solid #2a3853;
  border-radius: 999px;
  padding: 3px 10px;
}
.btn {
  border: 1px solid #2a3853;
  background: #182234;
  color: #d5deee;
  border-radius: 8px;
  padding: 6px 12px;
  font-size: 13px;
  cursor: pointer;
}
.btn:disabled {
  opacity: 0.55;
  cursor: not-allowed;
}
.btn-primary {
  background: #0f766e;
  border-color: #14b8a6;
  color: #ecfeff;
}
.banner {
  border-radius: 8px;
  padding: 8px 12px;
  font-size: 13px;
}
.banner.err {
  background: #3b1d24;
  color: #fecaca;
  border: 1px solid #7f1d1d;
}
.banner.ok {
  background: #13262a;
  color: #99f6e4;
  border: 1px solid #115e59;
}
.card {
  background: #121926;
  border: 1px solid #26324a;
  border-radius: 12px;
  padding: 14px;
}
.card h2 {
  margin: 0 0 12px;
  font-size: 14px;
  color: #c9d4e8;
}
.form-grid {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 12px;
}
label {
  display: flex;
  flex-direction: column;
  gap: 6px;
  font-size: 12px;
  color: #93a1bd;
}
label.full {
  grid-column: 1 / -1;
}
label.check {
  flex-direction: row;
  align-items: center;
  gap: 8px;
  padding-top: 22px;
}
label.file em {
  font-style: normal;
  color: #9eb6d8;
  font-size: 12px;
}
input,
select,
textarea {
  background: #0d1420;
  border: 1px solid #2a3853;
  border-radius: 8px;
  color: #e6ebf5;
  padding: 8px 10px;
  font-size: 13px;
}
.form-actions {
  margin-top: 12px;
}
.table-wrap {
  overflow: auto;
}
table {
  width: 100%;
  border-collapse: collapse;
  font-size: 13px;
}
th,
td {
  text-align: left;
  padding: 10px 8px;
  border-bottom: 1px solid #1e2a40;
  vertical-align: top;
  color: #c9d4e8;
}
th {
  color: #8b98b3;
  font-weight: 600;
  font-size: 12px;
}
.empty {
  text-align: center;
  color: #7f8eab;
  padding: 24px !important;
}
.ver {
  font-weight: 600;
}
.chg {
  margin-top: 4px;
  color: #8b98b3;
  font-size: 12px;
  white-space: pre-wrap;
}
.tag {
  display: inline-block;
  border-radius: 999px;
  padding: 2px 8px;
  font-size: 11px;
  background: #243049;
  color: #c9d4e8;
}
.tag.published {
  background: #13262a;
  color: #5eead4;
}
.tag.draft {
  background: #2a2416;
  color: #fcd34d;
}
.ops {
  display: flex;
  gap: 10px;
  flex-wrap: wrap;
}
.link,
.linkbtn {
  background: none;
  border: none;
  color: #38bdf8;
  cursor: pointer;
  padding: 0;
  font-size: 13px;
  text-decoration: none;
}
.linkbtn.danger {
  color: #f87171;
}
.linkbtn:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}
@media (max-width: 900px) {
  .form-grid {
    grid-template-columns: 1fr;
  }
  label.check {
    padding-top: 0;
  }
}
</style>
