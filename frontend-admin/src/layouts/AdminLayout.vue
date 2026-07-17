<script setup lang="ts">
import { RouterLink, RouterView } from 'vue-router'
</script>

<template>
  <div class="layout">
    <nav class="topnav">
      <div class="brand">Rehab Admin</div>
      <RouterLink class="nav-link" to="/strategy">问诊策略树</RouterLink>
      <RouterLink class="nav-link" to="/kg">知识图谱检索</RouterLink>
      <RouterLink class="nav-link" to="/videos">视频库</RouterLink>
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
.content {
  flex: 1;
  min-height: 0;
  overflow: hidden;
  display: flex;
  flex-direction: column;
}
</style>