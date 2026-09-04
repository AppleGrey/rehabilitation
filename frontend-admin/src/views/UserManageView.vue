<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import {
  createAdmin,
  fetchUserPrograms,
  fetchUsers,
  resetUserPassword,
  revokeAdmin,
  setUserStatus,
  type ManagedUser,
  type UserProgramBrief,
} from '../api'
import { getUser, isSuperAdmin } from '../auth'

const me = getUser()
const canManageAdmins = isSuperAdmin()

const busy = ref(false)
const error = ref('')
const note = ref('')

const users = ref<ManagedUser[]>([])
const total = ref(0)
const keyword = ref('')
const roleFilter = ref('')
const statusFilter = ref('')

const selectedId = ref('')
const programs = ref<UserProgramBrief[]>([])
const programsBusy = ref(false)

const showCreate = ref(false)
const newAdmin = ref({ phone: '', password: '', nickname: '' })
const creating = ref(false)

const selected = computed(() => users.value.find((u) => u.id === selectedId.value) ?? null)

const ROLE_LABEL: Record<string, string> = {
  user: '普通用户',
  admin: '管理员',
  superadmin: '超级管理员',
}

function roleLabel(r?: string) {
  return ROLE_LABEL[r || ''] || r || '—'
}

function fmtDate(s?: string | null): string {
  if (!s) return '—'
  const d = new Date(s)
  return isNaN(d.getTime()) ? String(s) : d.toLocaleString()
}

function maskPhone(p: string): string {
  return p.length === 11 ? `${p.slice(0, 3)}****${p.slice(7)}` : p
}

async function load() {
  busy.value = true
  error.value = ''
  try {
    const data = await fetchUsers({
      q: keyword.value.trim(),
      role: roleFilter.value,
      status: statusFilter.value,
      limit: 100,
    })
    users.value = data.users || []
    total.value = data.total || 0
    if (users.value.length && !users.value.some((u) => u.id === selectedId.value)) {
      void select(users.value[0].id)
    } else if (!users.value.length) {
      selectedId.value = ''
      programs.value = []
    }
  } catch (err) {
    error.value = String(err instanceof Error ? err.message : err)
    users.value = []
  } finally {
    busy.value = false
  }
}

async function select(id: string) {
  selectedId.value = id
  programs.value = []
  programsBusy.value = true
  try {
    const data = await fetchUserPrograms(id)
    programs.value = data.programs || []
  } catch (err) {
    error.value = String(err instanceof Error ? err.message : err)
  } finally {
    programsBusy.value = false
  }
}

/** 把一次写操作的成功/失败统一收口，省得每个动作都写一遍 try/catch。 */
async function act(fn: () => Promise<unknown>, okMsg: string) {
  error.value = ''
  note.value = ''
  try {
    await fn()
    note.value = okMsg
    await load()
  } catch (err) {
    error.value = String(err instanceof Error ? err.message : err)
  }
}

function toggleStatus(u: ManagedUser) {
  const next = u.status === 'active' ? 'disabled' : 'active'
  const verb = next === 'disabled' ? '停用' : '启用'
  if (!window.confirm(`确定${verb}用户「${u.nickname || maskPhone(u.phone)}」？`)) return
  void act(() => setUserStatus(u.id, next), `已${verb}该账号`)
}

function doResetPassword(u: ManagedUser) {
  const pwd = window.prompt(`为「${u.nickname || maskPhone(u.phone)}」设置新密码（6-64 位）`)
  if (!pwd) return
  void act(() => resetUserPassword(u.id, pwd), '密码已重置，请线下告知本人')
}

function doRevokeAdmin(u: ManagedUser) {
  if (!window.confirm(`确定把「${u.nickname || maskPhone(u.phone)}」降级为普通用户？`)) return
  void act(() => revokeAdmin(u.id), '已降级为普通用户')
}

async function submitCreateAdmin() {
  if (creating.value) return
  const phone = newAdmin.value.phone.trim()
  if (!phone || !newAdmin.value.password) {
    error.value = '请填写手机号与密码'
    return
  }
  creating.value = true
  error.value = ''
  note.value = ''
  try {
    const res = await createAdmin({
      phone,
      password: newAdmin.value.password,
      nickname: newAdmin.value.nickname.trim() || undefined,
    })
    note.value = res.promoted ? '该手机号已存在，已提升为管理员' : '管理员创建成功'
    showCreate.value = false
    newAdmin.value = { phone: '', password: '', nickname: '' }
    await load()
    void select(res.user.id)
  } catch (err) {
    error.value = String(err instanceof Error ? err.message : err)
  } finally {
    creating.value = false
  }
}

onMounted(load)
</script>

<template>
  <div class="wrap">
    <header class="page-head">
      <div>
        <h1>用户管理</h1>
        <p class="sub">
          来自 core-svc <code>GET /api/admin/users</code>。当前登录：{{ me?.nickname || '—' }}（{{
            roleLabel(me?.role)
          }}）
        </p>
      </div>
      <div class="head-actions">
        <span class="count">共 {{ total }} 人</span>
        <button
          v-if="canManageAdmins"
          type="button"
          class="btn"
          @click="showCreate = !showCreate"
        >
          {{ showCreate ? '取消' : '+ 创建管理员' }}
        </button>
        <button type="button" class="btn" :disabled="busy" @click="load">刷新</button>
      </div>
    </header>

    <form v-if="showCreate && canManageAdmins" class="create-bar" @submit.prevent="submitCreateAdmin">
      <input v-model="newAdmin.phone" placeholder="手机号（11 位）" maxlength="11" inputmode="numeric" />
      <input v-model="newAdmin.password" type="password" placeholder="初始密码（6-64 位）" />
      <input v-model="newAdmin.nickname" placeholder="昵称（可选）" />
      <button class="btn primary" type="submit" :disabled="creating">
        {{ creating ? '创建中…' : '创建' }}
      </button>
      <span class="hint">手机号已注册为普通用户时，将就地提升为管理员（不改动其密码）。</span>
    </form>

    <div class="filter-bar">
      <input v-model="keyword" placeholder="搜索手机号 / 昵称" @keyup.enter="load" />
      <select v-model="roleFilter" @change="load">
        <option value="">全部角色</option>
        <option value="user">普通用户</option>
        <option value="admin">管理员</option>
        <option value="superadmin">超级管理员</option>
      </select>
      <select v-model="statusFilter" @change="load">
        <option value="">全部状态</option>
        <option value="active">启用</option>
        <option value="disabled">停用</option>
      </select>
      <button type="button" class="btn" :disabled="busy" @click="load">查询</button>
    </div>

    <div v-if="error" class="banner err">{{ error }}</div>
    <div v-if="note" class="banner ok">{{ note }}</div>

    <div class="workspace">
      <aside class="list-panel">
        <ul v-if="users.length" class="plist">
          <li
            v-for="u in users"
            :key="u.id"
            :class="{ active: u.id === selectedId }"
            @click="select(u.id)"
          >
            <div class="row1">
              <span class="cond">{{ u.nickname || maskPhone(u.phone) }}</span>
              <span class="status" :data-s="u.status">
                {{ u.status === 'active' ? '启用' : '停用' }}
              </span>
            </div>
            <div class="row2">
              <span class="id">{{ maskPhone(u.phone) }}</span>
              <span class="role-tag" :data-r="u.role">{{ roleLabel(u.role) }}</span>
              <span>{{ u.program_count }} 疗程</span>
            </div>
          </li>
        </ul>
        <div v-else-if="!busy" class="empty">没有匹配的用户</div>
      </aside>

      <main class="detail-panel">
        <template v-if="selected">
          <div class="detail-head">
            <div>
              <h2>{{ selected.nickname || maskPhone(selected.phone) }}</h2>
              <div class="row2">
                <span class="id">{{ selected.phone }}</span>
                <span class="role-tag" :data-r="selected.role">{{ roleLabel(selected.role) }}</span>
                <span class="status" :data-s="selected.status">
                  {{ selected.status === 'active' ? '启用' : '停用' }}
                </span>
              </div>
            </div>
            <div class="head-actions">
              <button
                type="button"
                class="btn"
                :disabled="selected.id === me?.id"
                @click="toggleStatus(selected)"
              >
                {{ selected.status === 'active' ? '停用' : '启用' }}
              </button>
              <button
                type="button"
                class="btn"
                :disabled="selected.id === me?.id"
                @click="doResetPassword(selected)"
              >
                重置密码
              </button>
              <button
                v-if="canManageAdmins && selected.role !== 'user' && selected.id !== me?.id"
                type="button"
                class="btn danger"
                @click="doRevokeAdmin(selected)"
              >
                降为普通用户
              </button>
            </div>
          </div>

          <section class="card">
            <h3>康复数据概览</h3>
            <div class="stats">
              <div class="stat">
                <span class="v">{{ selected.program_count }}</span>
                <span class="k">康复疗程</span>
              </div>
              <div class="stat">
                <span class="v">{{ selected.training_count }}</span>
                <span class="k">训练/评估次数</span>
              </div>
              <div class="stat">
                <span class="v small">{{ fmtDate(selected.last_program_at) }}</span>
                <span class="k">最近建方案</span>
              </div>
              <div class="stat">
                <span class="v small">{{ fmtDate(selected.last_login_at) }}</span>
                <span class="k">最近登录</span>
              </div>
              <div class="stat">
                <span class="v small">{{ fmtDate(selected.created_at) }}</span>
                <span class="k">注册时间</span>
              </div>
            </div>
          </section>

          <section class="card">
            <h3>康复方案</h3>
            <div v-if="programsBusy" class="empty">加载中…</div>
            <table v-else-if="programs.length" class="ptable">
              <thead>
                <tr>
                  <th>病症 / 部位</th>
                  <th>状态</th>
                  <th>分期</th>
                  <th>创建时间</th>
                  <th>ID</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="p in programs" :key="p.program_id">
                  <td>{{ p.condition || p.body_part || '—' }}</td>
                  <td><span class="status" :data-s="p.status">{{ p.status }}</span></td>
                  <td>第 {{ p.current_stage_no }} 期</td>
                  <td>{{ fmtDate(p.created_at) }}</td>
                  <td class="id">{{ p.program_id.slice(0, 8) }}</td>
                </tr>
              </tbody>
            </table>
            <div v-else class="empty">该用户还没有康复方案</div>
          </section>
        </template>
        <div v-else class="empty detail-empty">选择左侧用户查看详情</div>
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
.head-actions { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.count { color: var(--muted); font-size: 0.85rem; }
.btn { padding: 8px 14px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); color: var(--fg); font: inherit; cursor: pointer; }
.btn:hover:not(:disabled) { border-color: var(--primary); color: var(--primary); }
.btn:disabled { opacity: 0.5; cursor: default; }
.btn.primary { border-color: #1f4a45; background: #13262a; color: var(--primary); }
.btn.danger { border-color: #5c2430; color: #f0a8b0; }
.btn.danger:hover:not(:disabled) { border-color: #a33; color: #ffb4bc; }
.create-bar, .filter-bar { display: flex; align-items: center; gap: 8px; flex: 0 0 auto; flex-wrap: wrap; }
.create-bar input, .filter-bar input, .filter-bar select {
  padding: 8px 11px; border: 1px solid var(--line); border-radius: 8px;
  background: var(--panel); color: var(--fg); font: inherit;
}
.create-bar input:focus, .filter-bar input:focus { outline: none; border-color: var(--primary); }
.filter-bar input { min-width: 220px; }
.hint { color: var(--muted); font-size: 0.76rem; }
.banner { padding: 10px 12px; border-radius: 8px; font-size: 0.88rem; flex: 0 0 auto; }
.banner.err { background: #2a1518; border: 1px solid #5c2430; color: var(--red); }
.banner.ok { background: #13262a; border: 1px solid #1f4a45; color: var(--primary); }
.workspace { flex: 1; min-height: 0; display: grid; grid-template-columns: minmax(240px, 320px) 1fr; gap: 12px; }
.list-panel, .detail-panel { min-height: 0; background: var(--panel); border: 1px solid var(--line); border-radius: 10px; overflow: auto; }
.plist { list-style: none; margin: 0; padding: 6px; }
.plist li { padding: 10px 12px; border-radius: 8px; cursor: pointer; border: 1px solid transparent; margin-bottom: 4px; }
.plist li:hover { background: #132033; }
.plist li.active { background: #13262a; border-color: #1f4a45; }
.row1 { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
.cond { font-weight: 600; font-size: 0.92rem; }
.row2 { display: flex; gap: 10px; margin-top: 4px; font-size: 0.75rem; color: var(--muted); flex-wrap: wrap; align-items: center; }
.row2 .id { font-family: Consolas, Menlo, monospace; }
.status { font-size: 0.72rem; color: var(--muted); }
.status[data-s='active'] { color: var(--primary); }
.status[data-s='disabled'] { color: var(--red); }
.status[data-s='generating'] { color: var(--yellow); }
.status[data-s='discharged'] { color: var(--blue); }
.role-tag { font-size: 0.72rem; padding: 1px 7px; border-radius: 999px; border: 1px solid var(--line); color: var(--muted); }
.role-tag[data-r='admin'] { border-color: #2a4a6d; color: #9cc3ff; }
.role-tag[data-r='superadmin'] { border-color: #4a3670; color: #c0a8ff; }
.detail-panel { padding: 14px; display: flex; flex-direction: column; gap: 12px; }
.detail-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; }
.detail-head h2 { margin: 0 0 4px; font-size: 1.1rem; }
.card { background: var(--bg); border: 1px solid var(--line); border-radius: 10px; padding: 14px; }
.card h3 { margin: 0 0 12px; font-size: 0.98rem; }
.stats { display: flex; flex-wrap: wrap; gap: 10px; }
.stat { flex: 1 1 130px; background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 10px 12px; display: flex; flex-direction: column; gap: 4px; }
.stat .v { font-size: 1.3rem; font-weight: 600; }
.stat .v.small { font-size: 0.82rem; font-weight: 500; color: #c9d4e8; }
.stat .k { font-size: 0.74rem; color: var(--muted); }
.ptable { width: 100%; border-collapse: collapse; font-size: 0.84rem; }
.ptable th { text-align: left; padding: 6px 8px; color: var(--muted); font-weight: 500; font-size: 0.76rem; border-bottom: 1px solid var(--line); }
.ptable td { padding: 8px; border-bottom: 1px dashed var(--line); }
.ptable td.id { font-family: Consolas, Menlo, monospace; color: var(--muted); }
.empty { padding: 24px 16px; color: var(--muted); text-align: center; font-size: 0.9rem; }
.detail-empty { margin: auto; }
@media (max-width: 900px) { .workspace { grid-template-columns: 1fr; grid-template-rows: minmax(200px, 34%) 1fr; } }
</style>
