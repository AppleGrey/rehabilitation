/**
 * 管理平台登录态。
 *
 * 令牌由 core-svc 签发（scope=admin，默认 12 小时），admin-svc 每次请求都会验签
 * 并回库确认账号仍是启用状态的管理员，因此这里只负责存取与过期后的跳转。
 */

const TOKEN_KEY = 'admin_token'
const USER_KEY = 'admin_user'

export interface AdminUser {
  id: string
  phone: string
  nickname?: string
  role: 'admin' | 'superadmin' | string
}

export function getToken(): string {
  return localStorage.getItem(TOKEN_KEY) || ''
}

export function getUser(): AdminUser | null {
  const raw = localStorage.getItem(USER_KEY)
  if (!raw) return null
  try {
    return JSON.parse(raw) as AdminUser
  } catch {
    return null
  }
}

export function isLoggedIn(): boolean {
  return getToken() !== ''
}

export function isSuperAdmin(): boolean {
  return getUser()?.role === 'superadmin'
}

export function setSession(token: string, user: AdminUser) {
  localStorage.setItem(TOKEN_KEY, token)
  localStorage.setItem(USER_KEY, JSON.stringify(user))
}

export function clearSession() {
  localStorage.removeItem(TOKEN_KEY)
  localStorage.removeItem(USER_KEY)
}

export async function login(phone: string, password: string): Promise<AdminUser> {
  const resp = await fetch('/admin-api/auth/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ phone, password }),
  })
  const body = await resp.json().catch(() => null)
  if (!resp.ok) {
    throw new Error(body?.detail || `登录失败（${resp.status}）`)
  }
  const token = String(body?.token || '')
  const user = body?.user as AdminUser | undefined
  if (!token || !user) throw new Error('登录响应格式异常')
  setSession(token, user)
  return user
}

/** 令牌失效时统一处理：清掉本地会话并回登录页。 */
export function onUnauthorized() {
  clearSession()
  const here = window.location.pathname + window.location.search
  const next = here && here !== '/login' ? `?next=${encodeURIComponent(here)}` : ''
  window.location.replace(`/login${next}`)
}
