import type { SessionItem, Snapshot } from './types'

async function getJSON<T>(url: string): Promise<T> {
  const resp = await fetch(url)
  if (!resp.ok) {
    throw new Error(`${resp.status} ${resp.statusText}`)
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
