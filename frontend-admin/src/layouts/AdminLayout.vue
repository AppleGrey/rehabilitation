<script setup lang="ts">
import { RouterLink, RouterView, useRouter } from 'vue-router'
import { clearSession, getUser } from '../auth'

const router = useRouter()
const me = getUser()

const ROLE_LABEL: Record<string, string> = {
  admin: '管理员',
  superadmin: '超级管理员',
}

function logout() {
  if (!window.confirm('确定退出登录？')) return
  clearSession()
  void router.replace({ name: 'login' })
}
</script>

<template>
  <div class="layout">
    <nav class="topnav">
      <div class="brand">Rehab Admin</div>
      <RouterLink class="nav-link" to="/strategy">问诊策略树</RouterLink>
      <RouterLink class="nav-link" to="/kg">知识图谱检索</RouterLink>
      <RouterLink class="nav-link" to="/videos">视频库</RouterLink>
      <RouterLink class="nav-link" to="/programs">康复方案</RouterLink>
      <RouterLink class="nav-link" to="/uploads">用户跟练视频</RouterLink>
      <RouterLink class="nav-link" to="/users">用户管理</RouterLink>
      <RouterLink class="nav-link" to="/releases">App 版本</RouterLink>
      <RouterLink class="nav-link" to="/settings">配置管理</RouterLink>
      <div class="spacer" />
      <span class="me" :title="me?.phone">
        {{ me?.nickname || me?.phone || '—' }}
        <em>{{ ROLE_LABEL[me?.role || ''] || me?.role }}</em>
      </span>
      <button type="button" class="logout" @click="logout">退出</button>
    </nav>
    <div class="content">
      <RouterView />
    </div>
  </div>
</template>

<style scoped>
.layout {
  height: 100%;
  display: flex;
  flex-direction: column;
  min-height: 0;
}
.topnav {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 0 14px;
  height: 44px;
  background: #121926;
  border-bottom: 1px solid var(--line, #26324a);
  flex: 0 0 auto;
}
.brand {
  font-size: 13px;
  font-weight: 700;
  color: #c9d4e8;
  margin-right: 10px;
  letter-spacing: 0.02em;
}
.nav-link {
  color: #93a1bd;
  text-decoration: none;
  font-size: 13px;
  padding: 6px 10px;
  border-radius: 8px;
}
.nav-link:hover {
  color: #e6ebf5;
  background: #1a2436;
}
.nav-link.router-link-active {
  color: #00a68c;
  background: #13262a;
}
.spacer { flex: 1; }
.me {
  font-size: 12px;
  color: #c9d4e8;
  display: inline-flex;
  align-items: center;
  gap: 6px;
}
.me em {
  font-style: normal;
  font-size: 11px;
  color: #93a1bd;
  border: 1px solid var(--line, #26324a);
  border-radius: 999px;
  padding: 1px 7px;
}
.logout {
  font: inherit;
  font-size: 12px;
  padding: 5px 11px;
  border: 1px solid var(--line, #26324a);
  border-radius: 8px;
  background: transparent;
  color: #93a1bd;
  cursor: pointer;
}
.logout:hover { color: #f0a8b0; border-color: #5c2430; }
.content {
  flex: 1;
  min-height: 0;
  overflow: hidden;
  display: flex;
  flex-direction: column;
}
</style>
