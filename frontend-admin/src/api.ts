import type { SessionItem, Snapshot } from './types'
import { getToken, onUnauthorized } from './auth'

/** Same-origin proxy → core-svc (:8081) */
export const CORE_SVC_BASE = '/core-svc'

export interface VideoItem {
  video_id: string
  target_joint?: string
  target_body_parts?: string[]
  severity?: string
  rehab_stage?: string
  action_keywords?: string[]
  symptom_tags?: string[]
  description_cn?: string
  duration_seconds?: number
  difficulty?: number
  equipment?: string
  space_required?: string
  body_parts_involved?: string[]
  pose_landmarks_required?: string[]
  safety_level?: string
  contraindications?: string[]
  file_name?: string
  url?: string
  [key: string]: unknown
}

// ── 统一请求层：带令牌 + 401 回登录页 ──

function authHeaders(extra?: HeadersInit): HeadersInit {
  const token = getToken()
  const base: Record<string, string> = token ? { Authorization: `Bearer ${token}` } : {}
  return { ...base, ...(extra as Record<string, string> | undefined) }
}

async function request(url: string, init?: RequestInit): Promise<Response> {
  const resp = await fetch(url, { ...init, headers: authHeaders(init?.headers) })
  if (resp.status === 401) {
    onUnauthorized()
    throw new Error('登录已过期，请重新登录')
  }
  if (!resp.ok) {
    let detail = `${resp.status} ${resp.statusText}`
    try {
      const body = await resp.json()
      if (body?.detail) detail = String(body.detail)
    } catch {
      /* ignore */
    }
    throw new Error(detail)
  }
  return resp
}

async function getJSON<T>(url: string): Promise<T> {
  const resp = await request(url)
  return resp.json() as Promise<T>
}

async function sendJSON<T>(url: string, method: string, body?: unknown): Promise<T> {
  const resp = await request(url, {
    method,
    headers: body === undefined ? undefined : { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  return resp.json() as Promise<T>
}

/**
 * 给由浏览器直接发起的资源请求（<video src>、下载链接）附上令牌。
 * 这类请求没法带 Authorization 头，admin-svc 的鉴权中间件因此也接受 ?token=。
 */
export function withToken(url: string): string {
  const token = getToken()
  if (!token) return url
  return url + (url.includes('?') ? '&' : '?') + `token=${encodeURIComponent(token)}`
}

export function fetchSessions(limit = 30) {
  return getJSON<{ sessions: SessionItem[] }>(`/admin-api/consult/sessions?limit=${limit}`)
}

export function fetchHistory(sessionId: string) {
  return getJSON<{ session_id: string; snapshots: Snapshot[] }>(
    `/admin-api/session/${sessionId}/strategy/history`,
  )
}

export function fetchVideos(opts?: {
  target_joint?: string
  severity?: string
  limit?: number
}) {
  const params = new URLSearchParams()
  if (opts?.target_joint) params.set('target_joint', opts.target_joint)
  if (opts?.severity) params.set('severity', opts.severity)
  params.set('limit', String(opts?.limit ?? 200))
  const qs = params.toString()
  return getJSON<{ videos: VideoItem[] }>(`${CORE_SVC_BASE}/api/videos?${qs}`)
}

/** Resolve playable URL via core-svc proxy (supports Range). */
export function playUrl(video: Pick<VideoItem, 'video_id' | 'url'>): string {
  if (video.url?.startsWith('/')) return withToken(`${CORE_SVC_BASE}${video.url}`)
  if (video.url) return video.url
  return withToken(`${CORE_SVC_BASE}/api/videos/${encodeURIComponent(video.video_id)}/play`)
}

// ── 康复方案（admin-svc 直读库）+ 用户跟练视频 ──

export interface ProgramSummary {
  program_id: string
  condition?: string
  body_part?: string
  status?: string
  current_stage_no?: number
  impression?: { name?: string; confidence?: number }[]
  created_at?: string | null
}

export interface UploadItem {
  task_id: string
  session_id?: string
  standard_video_id?: string
  status?: string
  summary?: string | null
  assessment?: Record<string, unknown> | null
  play_url: string
  created_at?: string | null
}

export function fetchPrograms(limit = 50) {
  return getJSON<{ programs: ProgramSummary[] }>(`/admin-api/programs?limit=${limit}`)
}

export function fetchProgram(id: string) {
  return getJSON<Record<string, any>>(`/admin-api/programs/${encodeURIComponent(id)}`)
}

export function deleteProgram(id: string) {
  return sendJSON<{ ok: boolean; program_id: string }>(
    `/admin-api/programs/${encodeURIComponent(id)}`,
    'DELETE',
  )
}

export function fetchUploads(limit = 50) {
  return getJSON<{ uploads: UploadItem[] }>(`/admin-api/uploads?limit=${limit}`)
}

// ── 用户管理（经 admin-svc 代理到 core-svc /api/admin/*）──

export type UserRole = 'user' | 'admin' | 'superadmin'
export type UserStatus = 'active' | 'disabled'

export interface ManagedUser {
  id: string
  phone: string
  nickname: string
  role: UserRole | string
  status: UserStatus | string
  last_login_at?: string | null
  created_at: string
  updated_at: string
  program_count: number
  training_count: number
  last_program_at?: string | null
  active_program_id?: string
}

export interface UserProgramBrief {
  program_id: string
  condition: string
  body_part: string
  status: string
  current_stage_no: number
  session_id: string
  created_at?: string | null
  updated_at?: string | null
}

const ADMIN_API = `${CORE_SVC_BASE}/api/admin`

export function fetchUsers(opts?: {
  q?: string
  role?: string
  status?: string
  limit?: number
  offset?: number
}) {
  const params = new URLSearchParams()
  if (opts?.q) params.set('q', opts.q)
  if (opts?.role) params.set('role', opts.role)
  if (opts?.status) params.set('status', opts.status)
  params.set('limit', String(opts?.limit ?? 50))
  params.set('offset', String(opts?.offset ?? 0))
  return getJSON<{ users: ManagedUser[]; total: number; limit: number; offset: number }>(
    `${ADMIN_API}/users?${params}`,
  )
}

export function fetchUser(id: string) {
  return getJSON<ManagedUser>(`${ADMIN_API}/users/${encodeURIComponent(id)}`)
}

export function fetchUserPrograms(id: string) {
  return getJSON<{ programs: UserProgramBrief[] }>(
    `${ADMIN_API}/users/${encodeURIComponent(id)}/programs`,
  )
}

export function setUserStatus(id: string, status: UserStatus) {
  return sendJSON<{ ok: boolean; id: string; status: string }>(
    `${ADMIN_API}/users/${encodeURIComponent(id)}/status`,
    'POST',
    { status },
  )
}

export function resetUserPassword(id: string, newPassword: string) {
  return sendJSON<{ ok: boolean; id: string }>(
    `${ADMIN_API}/users/${encodeURIComponent(id)}/password`,
    'POST',
    { new_password: newPassword },
  )
}

/** 超级管理员专用：创建管理员（手机号已存在则就地提升）。 */
export function createAdmin(payload: { phone: string; password: string; nickname?: string }) {
  return sendJSON<{ user: ManagedUser; promoted: boolean }>(`${ADMIN_API}/admins`, 'POST', payload)
}

/** 超级管理员专用：把管理员降级为普通用户。 */
export function revokeAdmin(id: string) {
  return sendJSON<{ ok: boolean; id: string; role: string }>(
    `${ADMIN_API}/admins/${encodeURIComponent(id)}`,
    'DELETE',
  )
}

// ── App OTA 版本发布 ──

export interface AppRelease {
  id: string
  platform: string
  version_name: string
  version_code: number
  force_update: boolean
  changelog: string
  object_key?: string | null
  file_name?: string | null
  file_size: number
  content_type: string
  status: string
  published_at?: string | null
  created_at: string
  updated_at: string
}

export function fetchAppReleases(opts?: { platform?: string; limit?: number }) {
  const params = new URLSearchParams()
  if (opts?.platform) params.set('platform', opts.platform)
  params.set('limit', String(opts?.limit ?? 50))
  return getJSON<{ releases: AppRelease[] }>(`/admin-api/app/releases?${params}`)
}

export async function createAppRelease(form: FormData) {
  const resp = await request('/admin-api/app/releases', { method: 'POST', body: form })
  return resp.json() as Promise<{ ok: boolean; release: AppRelease }>
}

export function publishAppRelease(id: string) {
  return sendJSON<{ ok: boolean; release: AppRelease }>(
    `/admin-api/app/releases/${encodeURIComponent(id)}/publish`,
    'POST',
  )
}

export function deleteAppRelease(id: string) {
  return sendJSON<{ ok: boolean; id: string }>(
    `/admin-api/app/releases/${encodeURIComponent(id)}`,
    'DELETE',
  )
}
