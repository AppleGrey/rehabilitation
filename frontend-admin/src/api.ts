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
