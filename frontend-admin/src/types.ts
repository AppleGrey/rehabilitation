export interface SessionItem {
  session_id: string
  turn_no: number
  phase?: string
  strategy_source?: string
  impression?: Array<{ name?: string; confidence?: number }>
  created_at?: string | null
}

export interface TreeNode {
  node_id?: string
  type?: string
  question_text?: string
  intent?: string
  terminal_type?: string
  discriminates?: string[]
  option_leanings?: Record<string, string>
}

export interface TraceEvent {
  t?: string
  action?: string
  query?: string
  mode?: string
  top_k?: number
  chars?: number
  degraded?: boolean
  error?: string
  facts?: unknown
  hypothesis_deltas?: unknown
  red_flag?: unknown
  raw?: string
  ok?: boolean
  n_questions?: number
  errors?: unknown[]
  seed?: unknown
  stop?: boolean
  rebuild?: boolean
  reason?: string
  deviated?: boolean
  candidate_shift?: boolean
  horizon_exhausted?: boolean
  question?: string
  intent?: string
  score?: number
  target_slots?: unknown
  breakdown?: unknown
}

export interface Hypothesis {
  name?: string
  confidence?: number
  status?: string
}

export interface SlotItem {
  slot_id?: string
  title?: string
  category?: string
  status?: string
  value?: unknown
}

export interface Snapshot {
  turn_no: number
  phase?: string
  strategy_source?: string
  selected_question_id?: string | null
  tree_nodes?: TreeNode[]
  hypotheses?: Hypothesis[]
  slots?: SlotItem[]
  trace?: TraceEvent[]
}
