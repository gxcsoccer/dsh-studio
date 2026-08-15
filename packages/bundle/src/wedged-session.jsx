/**
 * Recovery for a session the log has wedged.
 *
 * When a turn dies between a tool call and its result, the append-only log
 * keeps the orphan forever. Every later request is rebuilt from that log, so it
 * carries an assistant message with `tool_calls` and no matching result, and the
 * provider rejects the whole request:
 *
 *   An assistant message with 'tool_calls' must be followed by tool messages
 *   responding to each 'tool_call_id'
 *
 * Nothing about that reaches the person typing. The session simply fails, again,
 * with the same wall of provider text — and retrying is the one thing guaranteed
 * not to work.
 *
 * The log is immutable, so the orphan cannot be removed. But `sessions.fork`
 * cuts a child from a completed-turn prefix, and a prefix that ends before the
 * orphan is clean. Verified against a real wedged session: 293 events with an
 * orphan at seq 262 forked at 195 into a 198-event child with no unmatched
 * calls, and the next prompt completed normally.
 */
import { useEffect, useState } from 'react'

import { diagnoseWedge } from './diagnose.js'

async function diagnose(api, sessionId) {
  const response = await api.sessions.history({ sessionId })
  if (!response?.result?.ok) return null
  return diagnoseWedge(response.result.value.events)
}

export function createWedgedSessionCard(ctx) {
  return function WedgedSessionCard({ useSession, sessionId }) {
    // Cheap trigger, authoritative confirmation: a terminal turn failure is
    // common and usually transient, so it only prompts the log read that can
    // actually tell the two apart.
    const lastFailureSeq = useSession((snapshot) => {
      const failures = snapshot.nodes.filter((node) => node.kind === 'turn-error')
      return failures.length ? failures[failures.length - 1].seq : null
    })

    const [diagnosis, setDiagnosis] = useState(null)
    const [recovering, setRecovering] = useState(false)

    useEffect(() => {
      if (lastFailureSeq === null) {
        setDiagnosis(null)
        return
      }
      let abandoned = false
      diagnose(ctx.connection.api, sessionId).then((result) => {
        if (!abandoned) setDiagnosis(result)
      })
      return () => {
        abandoned = true
      }
    }, [lastFailureSeq, sessionId])

    if (!diagnosis) return null

    async function recover() {
      setRecovering(true)
      try {
        const child = await ctx.sessions.fork({ sessionId, atSeq: diagnosis.anchor })
        ctx.sessions.open(child)
      } finally {
        setRecovering(false)
      }
    }

    return (
      <div role="status" style={styles.card}>
        <div style={styles.title}>这个会话没法继续了</div>
        <p style={styles.body}>
          有一次工具调用没能留下结果，而会话日志是只能追加的。之后每一条消息都会带上那次残缺的调用，
          被模型服务端拒绝——所以重试一定失败。
        </p>
        {diagnosis.anchor === null ? (
          <p style={styles.body}>这个会话第一轮就中断了，没有可以接着走的干净位置。新建一个会话吧。</p>
        ) : (
          <button type="button" onClick={recover} disabled={recovering} style={styles.action}>
            {recovering ? '正在分叉…' : '从上一轮完好的地方继续'}
          </button>
        )}
      </div>
    )
  }
}

const styles = {
  card: {
    margin: '8px 0',
    padding: '12px 14px',
    borderRadius: 10,
    background: 'var(--dsw-color-background-elevated, rgba(255,255,255,0.04))',
    border: '1px solid var(--dsw-color-border-default, rgba(255,255,255,0.12))',
    color: 'var(--dsw-color-text-primary, inherit)',
    font: '13px/1.5 -apple-system, BlinkMacSystemFont, system-ui, sans-serif',
  },
  title: { fontWeight: 600, marginBottom: 4 },
  body: { margin: '0 0 8px', color: 'var(--dsw-color-text-secondary, inherit)' },
  action: {
    padding: '6px 12px',
    borderRadius: 7,
    border: '1px solid var(--dsw-color-border-default, rgba(255,255,255,0.16))',
    background: 'var(--dsw-color-background-default, transparent)',
    color: 'inherit',
    font: 'inherit',
    cursor: 'pointer',
  },
}
