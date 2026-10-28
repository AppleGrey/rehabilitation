<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import { fetchLlmConfigs, saveLlmConfig, type LlmProfile } from '../api'

interface Draft {
  id: string
  title: string
  description: string
  base_url: string
  model: string
  api_key: string
  enable_thinking: boolean
  max_tokens: number
  temperature: number
  concat_standard_video: boolean
  api_key_hint: string
  has_api_key: boolean
  updated_at: string
}

const busy = ref(false)
const error = ref('')
const note = ref('')
const saving = ref('')
const drafts = reactive<Draft[]>([])

function fromProfile(item: LlmProfile): Draft {
  return {
    id: item.id,
    title: item.title,
    description: item.description,
    base_url: item.base_url,
    model: item.model,
    api_key: '',
    enable_thinking: item.enable_thinking,
    max_tokens: item.max_tokens,
    temperature: item.temperature,
    concat_standard_video: item.concat_standard_video,
    api_key_hint: item.api_key_hint,
    has_api_key: item.has_api_key,
    updated_at: item.updated_at,
  }
}

function fmtDate(s?: string) {
  if (!s) return '—'
  const d = new Date(s)
  return Number.isNaN(d.getTime()) ? s : d.toLocaleString()
}

async function load() {
  busy.value = true
  error.value = ''
  try {
    const data = await fetchLlmConfigs()
    drafts.splice(0, drafts.length, ...(data.profiles || []).map(fromProfile))
  } catch (err) {
    error.value = err instanceof Error ? err.message : String(err)
  } finally {
    busy.value = false
  }
}

async function save(draft: Draft) {
  note.value = ''
  error.value = ''
  if (!draft.base_url.trim() || !draft.model.trim()) {
    error.value = '接口地址和模型名称都要填写'
    return
  }
  saving.value = draft.id
  try {
    const body: {
      api_key?: string
      base_url: string
      model: string
      enable_thinking?: boolean
      max_tokens?: number
      temperature?: number
      concat_standard_video?: boolean
    } = {
      base_url: draft.base_url.trim(),
      model: draft.model.trim(),
    }
    if (draft.api_key.trim()) body.api_key = draft.api_key.trim()
    const maxTokens = Number(draft.max_tokens)
    if (!Number.isFinite(maxTokens) || maxTokens < 256 || maxTokens > 32768) {
      error.value = '最大输出 token 需要在 256 到 32768 之间'
      saving.value = ''
      return
    }
    if (draft.id === 'consult') {
      const temperature = Number(draft.temperature)
      if (!Number.isFinite(temperature) || temperature < 0 || temperature > 2) {
        error.value = '问诊温度需要在 0 到 2 之间'
        saving.value = ''
        return
      }
      body.temperature = temperature
      body.max_tokens = maxTokens
      body.enable_thinking = draft.enable_thinking
    }
    if (draft.id === 'vision') {
      body.enable_thinking = draft.enable_thinking
      body.max_tokens = maxTokens
      body.concat_standard_video = draft.concat_standard_video
    }
    if (draft.id === 'catalog') {
      body.enable_thinking = draft.enable_thinking
      body.max_tokens = maxTokens
    }
    const saved = await saveLlmConfig(draft.id, body)
    const next = fromProfile(saved.profile)
    const index = drafts.findIndex((item) => item.id === draft.id)
    if (index >= 0) drafts.splice(index, 1, next)
    note.value = `${draft.title}已保存，大约两秒后新的调用会使用这份配置`
  } catch (err) {
    error.value = err instanceof Error ? err.message : String(err)
  } finally {
    saving.value = ''
  }
}

onMounted(load)
</script>

<template>
  <div class="wrap">
    <header class="page-head">
      <div>
        <h1>配置管理</h1>
        <p class="sub">问诊、跟做评估和视频库处理各自使用一份配置。视频库处理只负责提取教学视频内容和制定评分规则。保存后无需重启服务。</p>
      </div>
      <button type="button" class="ghost" :disabled="busy" @click="load">刷新</button>
    </header>

    <p v-if="error" class="banner error">{{ error }}</p>
    <p v-else-if="note" class="banner ok">{{ note }}</p>
    <p v-else-if="busy" class="banner">正在读取配置…</p>

    <section v-for="draft in drafts" :key="draft.id" class="card">
      <h2>{{ draft.title }}</h2>
      <p class="sub">{{ draft.description }}</p>
      <label>
        <span>API Key</span>
        <input
          v-model="draft.api_key"
          type="password"
          autocomplete="new-password"
          :placeholder="draft.has_api_key ? `已配置 ${draft.api_key_hint}，留空则不修改` : '尚未配置'"
        />
      </label>
      <label>
        <span>接口地址</span>
        <input v-model="draft.base_url" type="url" spellcheck="false" />
      </label>
      <label>
        <span>模型名称</span>
        <input v-model="draft.model" type="text" spellcheck="false" />
      </label>
      <template v-if="draft.id === 'consult'">
        <label>
          <span>温度</span>
          <input v-model.number="draft.temperature" type="number" min="0" max="2" step="0.1" />
        </label>
        <label class="check">
          <input v-model="draft.enable_thinking" type="checkbox" />
          <span>开启思考。建树只要最终 JSON 时保持关闭，否则思考会占用最大输出 token。</span>
        </label>
        <label>
          <span>最大输出 token</span>
          <input v-model.number="draft.max_tokens" type="number" min="256" max="32768" step="256" />
        </label>
        <p class="sub">建树时思考和正文共用这个额度。接口允许的最大值是 32768，模型若拒绝再往下调。</p>
      </template>
      <template v-if="draft.id === 'catalog'">
        <label class="check">
          <input v-model="draft.enable_thinking" type="checkbox" />
          <span>开启思考。内容提取和规则只要最终 JSON 时保持关闭，否则思考会占用最大输出 token。</span>
        </label>
        <label>
          <span>最大输出 token</span>
          <input v-model.number="draft.max_tokens" type="number" min="256" max="32768" step="256" />
        </label>
      </template>
      <template v-if="draft.id === 'vision'">
        <label class="check">
          <input v-model="draft.concat_standard_video" type="checkbox" />
          <span>评估时把标准视频和用户视频拼成一条再送给模型。关闭后只送用户视频，动作要点和合格线仍写在提示词里。</span>
        </label>
        <label class="check">
          <input v-model="draft.enable_thinking" type="checkbox" />
          <span>开启思考。评估只要最终正文时保持关闭。</span>
        </label>
        <label>
          <span>最大输出 token</span>
          <input v-model.number="draft.max_tokens" type="number" min="256" max="32768" step="256" />
        </label>
      </template>
      <div class="row">
        <button type="button" class="primary" :disabled="saving === draft.id" @click="save(draft)">
          {{ saving === draft.id ? '保存中…' : '保存' }}
        </button>
        <span class="meta">上次保存 {{ fmtDate(draft.updated_at) }}</span>
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
.page-head h1,
.card h2 {
  margin: 0;
  color: #e6ebf5;
}
.page-head h1 { font-size: 18px; }
.card h2 { font-size: 16px; }
.sub {
  margin: 6px 0 0;
  font-size: 12px;
  color: #8b98b3;
}
.banner {
  margin: 0;
  padding: 8px 12px;
  border-radius: 8px;
  background: #1a2436;
  color: #c9d4e8;
  font-size: 13px;
}
.banner.error { color: #ffb4bc; }
.banner.ok { color: #8ee0c2; }
.card {
  max-width: 720px;
  display: flex;
  flex-direction: column;
  gap: 12px;
  padding: 16px;
  border: 1px solid var(--line);
  border-radius: 12px;
  background: var(--panel);
}
label {
  display: flex;
  flex-direction: column;
  gap: 6px;
  font-size: 12px;
  color: #93a1bd;
}
input[type='text'],
input[type='url'],
input[type='password'],
input[type='number'] {
  font: inherit;
  font-size: 14px;
  color: #e6ebf5;
  background: #101826;
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: 8px 10px;
}
.check {
  flex-direction: row;
  align-items: center;
  gap: 8px;
}
.row {
  display: flex;
  align-items: center;
  gap: 12px;
}
button {
  font: inherit;
  font-size: 13px;
  border-radius: 8px;
  padding: 7px 14px;
  cursor: pointer;
}
button:disabled { opacity: 0.6; cursor: default; }
.primary {
  border: none;
  background: var(--primary);
  color: #04231e;
  font-weight: 700;
}
.ghost {
  border: 1px solid var(--line);
  background: transparent;
  color: #c9d4e8;
}
.meta { font-size: 12px; color: #8b98b3; }
</style>
