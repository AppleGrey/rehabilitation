<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { isLoggedIn, login } from '../auth'

const router = useRouter()
const route = useRoute()

const phone = ref('')
const password = ref('')
const busy = ref(false)
const error = ref('')

function nextPath(): string {
  const raw = route.query.next
  const path = typeof raw === 'string' ? raw : ''
  // 只接受站内相对路径，避免开放重定向
  return path.startsWith('/') && !path.startsWith('//') ? path : '/strategy'
}

async function submit() {
  if (busy.value) return
  error.value = ''
  const p = phone.value.trim()
  if (!p || !password.value) {
    error.value = '请输入手机号与密码'
    return
  }
  busy.value = true
  try {
    await login(p, password.value)
    await router.replace(nextPath())
  } catch (err) {
    error.value = String(err instanceof Error ? err.message : err)
  } finally {
    busy.value = false
  }
}

onMounted(() => {
  if (isLoggedIn()) void router.replace(nextPath())
})
</script>

<template>
  <div class="login-page">
    <form class="card" @submit.prevent="submit">
      <h1>Rehab Admin</h1>
      <p class="sub">康复平台管理后台</p>

      <label class="field">
        <span>手机号</span>
        <input
          v-model="phone"
          type="tel"
          autocomplete="username"
          inputmode="numeric"
          maxlength="11"
          placeholder="11 位手机号"
        />
      </label>

      <label class="field">
        <span>密码</span>
        <input
          v-model="password"
          type="password"
          autocomplete="current-password"
          placeholder="请输入密码"
        />
      </label>

      <div v-if="error" class="banner err">{{ error }}</div>

      <button class="btn primary" type="submit" :disabled="busy">
        {{ busy ? '登录中…' : '登 录' }}
      </button>

      <p class="hint">后台不开放注册。需要账号请联系超级管理员在「用户管理」中创建。</p>
    </form>
  </div>
</template>

<style scoped>
.login-page { height: 100%; display: grid; place-items: center; padding: 24px; }
.card {
  width: min(360px, 100%);
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 14px;
  padding: 28px 26px 22px;
  display: flex;
  flex-direction: column;
  gap: 14px;
}
h1 { margin: 0; font-size: 1.35rem; font-weight: 600; letter-spacing: 0.02em; }
.sub { margin: -8px 0 6px; color: var(--muted); font-size: 0.86rem; }
.field { display: flex; flex-direction: column; gap: 6px; }
.field span { font-size: 0.8rem; color: var(--muted); }
.field input {
  padding: 10px 12px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--bg);
  color: var(--fg);
  font: inherit;
}
.field input:focus { outline: none; border-color: var(--primary); }
.btn {
  padding: 10px 14px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--panel);
  color: var(--fg);
  font: inherit;
  cursor: pointer;
}
.btn.primary { border-color: #1f4a45; background: #13262a; color: var(--primary); font-weight: 600; }
.btn.primary:hover:not(:disabled) { border-color: var(--primary); }
.btn:disabled { opacity: 0.6; cursor: default; }
.banner.err {
  padding: 9px 11px;
  border-radius: 8px;
  background: #2a1518;
  border: 1px solid #5c2430;
  color: var(--red);
  font-size: 0.85rem;
}
.hint { margin: 2px 0 0; color: var(--muted); font-size: 0.76rem; line-height: 1.5; }
</style>
