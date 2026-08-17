/**
 * Payload narrowing helpers. Everything arriving over the control channel is
 * untrusted input (bridge-contract.md §5, row 3: the peer is "一个装着别人代码
 * 的沙箱"), so each handler narrows its own payload and fails with
 * `bad_payload` instead of trusting a cast.
 */

import { bridgeError } from './bridge.ts'

/** JSON value domain — what may cross the control channel. */
export type JsonValue = string | number | boolean | null | JsonValue[] | { [key: string]: JsonValue }

/**
 * @param value - candidate.
 * @returns true for a non-array plain object.
 */
export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * Read a required string member.
 * @param payload - source object.
 * @param key - member name.
 * @returns the string value.
 * @throws BridgeFailure `bad_payload` when absent or not a string.
 */
export function expectString(payload: Record<string, unknown>, key: string): string {
  const value = payload[key]
  if (typeof value !== 'string' || value.length === 0) {
    throw bridgeError('bad_payload', `"${key}" must be a non-empty string`)
  }
  return value
}

/**
 * Read an optional string member.
 * @param payload - source object.
 * @param key - member name.
 * @returns the string value, or undefined when absent.
 * @throws BridgeFailure `bad_payload` when present but not a string.
 */
export function optionalString(payload: Record<string, unknown>, key: string): string | undefined {
  const value = payload[key]
  if (value === undefined || value === null) return undefined
  if (typeof value !== 'string') throw bridgeError('bad_payload', `"${key}" must be a string when present`)
  return value
}

/**
 * Read a required object member.
 * @param payload - source object.
 * @param key - member name.
 * @returns the object value.
 * @throws BridgeFailure `bad_payload` when absent or not an object.
 */
export function expectRecord(payload: Record<string, unknown>, key: string): Record<string, unknown> {
  const value = payload[key]
  if (!isRecord(value)) throw bridgeError('bad_payload', `"${key}" must be an object`)
  return value
}

/**
 * Read an optional array member.
 * @param payload - source object.
 * @param key - member name.
 * @returns the array, or undefined when absent.
 * @throws BridgeFailure `bad_payload` when present but not an array.
 */
export function optionalArray(payload: Record<string, unknown>, key: string): readonly unknown[] | undefined {
  const value = payload[key]
  if (value === undefined || value === null) return undefined
  if (!Array.isArray(value)) throw bridgeError('bad_payload', `"${key}" must be an array when present`)
  return value
}

/**
 * Project an arbitrary value onto the JSON domain, dropping anything the wire
 * cannot carry (functions, symbols, class instances with cycles). Used on the
 * return value of an injected callback before it rides a `res` back.
 * @param value - arbitrary value.
 * @param seen - cycle guard (internal).
 * @returns a JSON-safe projection; unsupported values become null.
 */
export function jsonSafe(value: unknown, seen: Set<object> = new Set()): JsonValue {
  if (value === null) return null
  switch (typeof value) {
    case 'string':
    case 'boolean':
      return value
    case 'number':
      return Number.isFinite(value) ? value : null
    case 'object': {
      const object = value as object
      if (seen.has(object)) return null
      seen.add(object)
      if (Array.isArray(value)) return value.map(item => jsonSafe(item, seen))
      const out: Record<string, JsonValue> = {}
      for (const [key, member] of Object.entries(value as Record<string, unknown>)) {
        if (typeof member === 'function' || member === undefined) continue
        out[key] = jsonSafe(member, seen)
      }
      return out
    }
    default:
      // undefined, function, symbol, bigint: not orchestration data.
      return null
  }
}
