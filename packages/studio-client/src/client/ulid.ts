/**
 * Monotonic ULID minting for `instanceId` and request `id`
 * (bridge-contract.md §1.2: "ULID, 仅 req/res. 单调递增便于排序调试").
 *
 * Crockford base32, 10 timestamp characters + 16 randomness characters. Same
 * millisecond mints increment the randomness field, so the lexical order of
 * two ids from one page load always matches their mint order — that is the
 * whole reason the contract asks for ULIDs instead of UUIDs.
 */

/** Crockford base32 alphabet (no I, L, O, U). */
const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
const TIME_LEN = 10
const RANDOM_LEN = 16

/** Random-source seam: `crypto.getRandomValues` where present, arithmetic fallback otherwise. */
function randomBytes(length: number): Uint8Array {
  const bytes = new Uint8Array(length)
  const webcrypto: Crypto | undefined = globalThis.crypto
  if (webcrypto !== undefined && typeof webcrypto.getRandomValues === 'function') {
    webcrypto.getRandomValues(bytes)
    return bytes
  }
  for (let i = 0; i < length; i += 1) bytes[i] = Math.floor(Math.random() * 256)
  return bytes
}

function encodeTime(now: number): string {
  let out = ''
  let rest = now
  for (let i = 0; i < TIME_LEN; i += 1) {
    out = (ALPHABET[rest % 32] ?? '0') + out
    rest = Math.floor(rest / 32)
  }
  return out
}

function encodeRandom(): string {
  const bytes = randomBytes(RANDOM_LEN)
  let out = ''
  for (let i = 0; i < RANDOM_LEN; i += 1) out += ALPHABET[(bytes[i] ?? 0) % 32] ?? '0'
  return out
}

/** Increment a Crockford base32 string in place (used for same-millisecond monotonicity). */
function incrementRandom(random: string): string {
  const chars = [...random]
  for (let i = chars.length - 1; i >= 0; i -= 1) {
    const index = ALPHABET.indexOf(chars[i] ?? '0')
    if (index < 31) {
      chars[i] = ALPHABET[index + 1] ?? '0'
      return chars.join('')
    }
    chars[i] = '0'
  }
  // Overflowed a full 16-character randomness field inside one millisecond:
  // fall back to a fresh draw rather than returning a duplicate.
  return encodeRandom()
}

/** ULID factory with its own monotonic state (one per bridge, injectable in tests). */
export interface UlidFactory {
  (): string
}

/**
 * Create a monotonic ULID factory.
 * @param now - clock seam, defaults to `Date.now`.
 * @returns a factory minting strictly increasing ULIDs.
 */
export function createUlid(now: () => number = Date.now): UlidFactory {
  let lastTime = -1
  let lastRandom = ''
  return () => {
    const time = now()
    if (time === lastTime) {
      lastRandom = incrementRandom(lastRandom)
    } else {
      lastTime = time
      lastRandom = encodeRandom()
    }
    return encodeTime(time) + lastRandom
  }
}

/** Process-wide monotonic ULID source. */
export const ulid: UlidFactory = createUlid()
