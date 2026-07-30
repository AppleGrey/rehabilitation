import type { SessionItem, Snapshot } from './types'

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

async function getJSON<T>(url: string): Promise<T> {
  const resp = await fetch(url)
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
  return resp.json() as Promise<T>
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
  if (video.url?.startsWith('/')) return `${CORE_SVC_BASE}${video.url}`
  if (video.url) return video.url
  return `${CORE_SVC_BASE}/api/videos/${encodeURIComponent(video.video_id)}/play`
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

export async function deleteProgram(id: string) {
  const resp = await fetch(`/admin-api/programs/${encodeURIComponent(id)}`, { method: 'DELETE' })
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
  return resp.json() as Promise<{ ok: boolean; program_id: string }>
}

export function fetchUploads(limit = 50) {
  return getJSON<{ uploads: UploadItem[] }>(`/admin-api/uploads?limit=${limit}`)
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
  const resp = await fetch('/admin-api/app/releases', { method: 'POST', body: form })
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
  return resp.json() as Promise<{ ok: boolean; release: AppRelease }>
}

export async function publishAppRelease(id: string) {
  const resp = await fetch(`/admin-api/app/releases/${encodeURIComponent(id)}/publish`, {
    method: 'POST',
  })
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
  return resp.json() as Promise<{ ok: boolean; release: AppRelease }>
}

export async function deleteAppRelease(id: string) {
  const resp = await fetch(`/admin-api/app/releases/${encodeURIComponent(id)}`, {
    method: 'DELETE',
  })
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
  return resp.json() as Promise<{ ok: boolean; id: string }>
}
