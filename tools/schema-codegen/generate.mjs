/**
 * Emits the Swift face of the DeepSeek Harness wire contract from the official
 * zod schemas.
 *
 * Two rules shape everything here:
 *   - Unknown FIELDS must break the build. That is the whole point of
 *     generating instead of hand-writing against a versionless preview API.
 *   - Unknown ENUM CASES must not break the app. The contract is
 *     merge-extensible by design (plugins add event and tool kinds), so every
 *     closed set decodes an unrecognized value into `.unknown` instead of
 *     throwing.
 */
import { writeFileSync, mkdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { openContract, defaultModulesDir, methodStem } from './resolve.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const args = process.argv.slice(2)
const argOf = (flag, fallback) => {
  const i = args.indexOf(flag)
  return i === -1 ? fallback : args[i + 1]
}
const from = argOf('--from', defaultModulesDir())
const outDir = argOf('--out', join(here, '..', '..', 'app', 'Sources', 'DSHKit', 'Generated'))

const contract = openContract(from)
const { z } = await contract.zod()
const modules = await contract.schemaModules()
const isSchema = (v) => v && typeof v === 'object' && typeof v._zod === 'object'

// ── naming ──────────────────────────────────────────────────────────────────

const pascal = (s) => s.trim().replace(/(^|[^a-zA-Z0-9])([a-zA-Z0-9])/g, (_, __, c) => c.toUpperCase())
const typeNameOf = (exportName) => pascal(exportName.replace(/Schema$/, ''))

const SWIFT_KEYWORDS = new Set([
  'associatedtype', 'class', 'deinit', 'enum', 'extension', 'fileprivate', 'func', 'import', 'init',
  'inout', 'internal', 'let', 'open', 'operator', 'private', 'protocol', 'public', 'rethrows',
  'static', 'struct', 'subscript', 'typealias', 'var', 'break', 'case', 'catch', 'continue',
  'default', 'defer', 'do', 'else', 'fallthrough', 'for', 'guard', 'if', 'in', 'repeat', 'return',
  'switch', 'where', 'while', 'as', 'any', 'false', 'is', 'nil', 'self', 'Self', 'super', 'throw',
  'throws', 'true', 'try', 'Type', 'Protocol',
])
const ident = (name) => (SWIFT_KEYWORDS.has(name) ? `\`${name}\`` : name)
const caseName = (literal) => {
  const camel = String(literal)
    .replace(/[^a-zA-Z0-9]+(.)?/g, (_, c) => (c ? c.toUpperCase() : ''))
    .replace(/^(.)/, (c) => c.toLowerCase())
  const safe = /^[0-9]/.test(camel) ? `v${camel}` : camel
  return SWIFT_KEYWORDS.has(safe) ? `\`${safe}\`` : safe
}

// ── shape identity ──────────────────────────────────────────────────────────
// No $defs means every reused shape is inlined and would otherwise generate a
// near-duplicate type per use site. Hashing the structure collapses them, and
// registering top-level exports first makes the collapsed name the meaningful
// one (`SessionSummary`, not `SessionListValueItemsItem`).

const IRRELEVANT = new Set([
  '$schema', 'minLength', 'maxLength', 'pattern', 'minimum', 'maximum',
  'exclusiveMinimum', 'exclusiveMaximum', 'minItems', 'maxItems', 'description', 'propertyNames',
])
function structuralKey(node) {
  if (node === null || typeof node !== 'object') return JSON.stringify(node)
  if (Array.isArray(node)) return `[${node.map(structuralKey).join(',')}]`
  const keys = Object.keys(node).filter((k) => !IRRELEVANT.has(k)).sort()
  return `{${keys.map((k) => `${k}:${structuralKey(node[k])}`).join(',')}}`
}

const declarations = new Map() // swift type name → source
const nameByShape = new Map() // structural key → swift type name
const usedNames = new Set()

function reserve(preferred) {
  let name = preferred
  let n = 2
  while (usedNames.has(name)) name = `${preferred}${n++}`
  usedNames.add(name)
  return name
}

// ── union classification ────────────────────────────────────────────────────

/**
 * The smallest set of const properties whose combined values identify each
 * branch. Usually one key (`type`), but some unions need a pair: subagent
 * entries are `(kind: child, mode: one-shot)`, `(kind: child, mode:
 * continuable)`, `(kind: diagnostic)` — neither key alone separates them.
 * Returns null when nothing discriminates, which is a hard codegen failure
 * rather than a guess.
 */
function discriminantOf(branches) {
  if (!branches.every((b) => b.type === 'object' && b.properties)) return null

  const constKeys = [...new Set(branches.flatMap((b) => Object.entries(b.properties).filter(([, v]) => 'const' in v).map(([k]) => k)))]
  const signature = (branch, keys) => JSON.stringify(keys.map((k) => branch.properties[k]?.const ?? null))
  const separates = (keys) => new Set(branches.map((b) => signature(b, keys))).size === branches.length
  const presentEverywhere = (key) => branches.every((b) => b.properties[key] && 'const' in b.properties[key])

  // A key every branch carries is the best discriminant: each branch then has a
  // literal to be named after. A key some branch omits still separates, but the
  // omitting branch would have no name, so a compound is preferred over it.
  for (const key of constKeys) if (presentEverywhere(key) && separates([key])) return [key]
  if (constKeys.length > 1 && separates(constKeys)) return constKeys
  for (const key of constKeys) if (separates([key])) return [key]
  return null
}

// ── emission ────────────────────────────────────────────────────────────────

/**
 * `nominal` forces a fresh named type instead of reusing a structurally
 * identical one. Request and response types must be nominal: `session.cancel`
 * and `session.models` both take `{ sessionId }`, and if they collapse into one
 * Swift type they cannot carry different `WireRequest.Response` types. Nested
 * shapes still dedup normally.
 */
function swiftType(node, hint, nominal = false) {
  if (node === null || typeof node !== 'object') fail(hint, 'not a schema node')

  const keys = Object.keys(node).filter((k) => k !== '$schema')
  if (keys.length === 0) return 'JSONValue' // z.unknown(): merge-extensible by design

  const union = node.anyOf ?? node.oneOf
  if (union) return unionType(union, node, hint, nominal)

  if (Array.isArray(node.type)) fail(hint, `type array ${node.type.join('|')} unsupported`)

  switch (node.type) {
    case 'string':
      return 'String'
    case 'integer':
      return 'Int'
    case 'number':
      return 'Double'
    case 'boolean':
      return 'Bool'
    case 'null':
      return 'JSONValue'
    case 'array':
      return `[${node.items ? swiftType(node.items, `${hint}Item`) : 'JSONValue'}]`
    case 'object':
      return objectType(node, hint, nominal)
    default:
      fail(hint, `unhandled node ${JSON.stringify(keys)}`)
  }
}

function objectType(node, hint, nominal = false) {
  // A record (`Record<string, V>`) carries no declared properties, only a value schema.
  if (!node.properties && node.additionalProperties && typeof node.additionalProperties === 'object') {
    return `[String: ${swiftType(node.additionalProperties, `${hint}Value`)}]`
  }
  if (!node.properties) return 'JSONValue'

  const key = structuralKey(node)
  if (!nominal) {
    const known = nameByShape.get(key)
    if (known) return known
  }

  const name = reserve(hint)
  if (!nameByShape.has(key)) nameByShape.set(key, name)

  const required = new Set(node.required ?? [])
  const fields = Object.entries(node.properties).map(([prop, sub]) => {
    const optional = !required.has(prop)
    const nullable = isNullable(sub)
    const inner = nullable ? swiftType(stripNull(sub), pascal(`${name} ${prop}`)) : swiftType(sub, pascal(`${name} ${prop}`))
    return { prop, type: `${inner}${optional || nullable ? '?' : ''}` }
  })

  const body = fields.map((f) => `    public let ${ident(f.prop)}: ${f.type}`).join('\n')
  const initArgs = fields
    .map((f) => `        ${ident(f.prop)}: ${f.type}${f.type.endsWith('?') ? ' = nil' : ''}`)
    .join(',\n')
  const initBody = fields.map((f) => `        self.${ident(f.prop)} = ${ident(f.prop)}`).join('\n')

  declarations.set(
    name,
    `public struct ${name}: Codable, Hashable, Sendable {\n${body}\n\n` +
      `    public init(\n${initArgs}\n    ) {\n${initBody}\n    }\n}`,
  )
  return name
}

const isNullable = (node) => {
  const u = node.anyOf ?? node.oneOf
  return Array.isArray(u) && u.length === 2 && u.some((b) => b.type === 'null')
}
const stripNull = (node) => (node.anyOf ?? node.oneOf).find((b) => b.type !== 'null')

function unionType(branches, node, hint, nominal = false) {
  if (isNullable(node)) return swiftType(stripNull(node), hint, nominal)

  const key = structuralKey(node)
  if (!nominal) {
    const known = nameByShape.get(key)
    if (known) return known
  }

  if (branches.every((b) => b.type === 'string' && 'const' in b)) {
    const name = reserve(hint)
    if (!nameByShape.has(key)) nameByShape.set(key, name)
    declarations.set(name, stringEnum(name, branches.map((b) => b.const)))
    return name
  }

  const keys = discriminantOf(branches)
  if (!keys) fail(hint, `union with no discriminating const property (${branches.length} branches)`)

  const swiftLiteralType = (k) => {
    const values = branches.map((b) => b.properties[k]?.const).filter((v) => v !== undefined)
    if (values.every((v) => typeof v === 'boolean')) return 'Bool'
    if (values.every((v) => typeof v === 'string')) return 'String'
    if (values.every((v) => typeof v === 'number')) return 'Double'
    return fail(hint, `discriminant '${k}' mixes literal types`)
  }
  const discriminants = keys.map((k) => ({ key: k, type: swiftLiteralType(k) }))

  // A boolean discriminant reads terribly as `.true` / `.false`; name those
  // branches after the flag itself (`ok` / `notOk`).
  const labelFor = (k, value) =>
    typeof value === 'boolean' ? (value ? k : `not-${k}`) : String(value)

  const name = reserve(hint)
  if (!nameByShape.has(key)) nameByShape.set(key, name)
  // Reserve the name before generating payloads so a self-referential branch resolves.
  const cases = branches.map((b, index) => {
    const literals = keys.map((k) => (k in b.properties && 'const' in b.properties[k] ? b.properties[k].const : null))
    // A branch that omits every discriminant key has no literal to be named
    // after; its position is the only thing left that identifies it.
    const label =
      keys
        .map((k, i) => (literals[i] === null ? null : labelFor(k, literals[i])))
        .filter((l) => l !== null)
        .join('-') || `case${index}`
    return { literals, label, payload: objectType(b, pascal(`${name} ${label}`)) }
  })
  declarations.set(name, discriminatedEnum(name, discriminants, cases))
  return name
}

function stringEnum(name, literals) {
  const cases = literals.map((l) => `    case ${caseName(l)}`).join('\n')
  const raws = literals.map((l) => `        case .${caseName(l)}: return ${JSON.stringify(l)}`).join('\n')
  const parse = literals.map((l) => `        case ${JSON.stringify(l)}: self = .${caseName(l)}`).join('\n')
  return `public enum ${name}: Codable, Hashable, Sendable {
${cases}
    /// Upstream added a case this build does not know. Surfaced, never fatal.
    case unknown(String)

    public var rawValue: String {
        switch self {
${raws}
        case .unknown(let raw): return raw
        }
    }

    public init(from decoder: any Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
${parse}
        case let other: self = .unknown(other)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}`
}

function discriminatedEnum(name, discriminants, cases) {
  const slot = (i) => `k${i}`
  const pattern = (literals) =>
    `(${literals.map((l) => (l === null ? '_' : `.some(${JSON.stringify(l)})`)).join(', ')})`

  const body = cases.map((c) => `    case ${caseName(c.label)}(${c.payload})`).join('\n')
  const reads = discriminants
    .map(
      ({ key, type }, i) =>
        `        let ${slot(i)} = (try? container.decodeIfPresent(${type}.self, forKey: .${ident(key)})) ?? nil`,
    )
    .join('\n')
  const keys = discriminants.map((d) => d.key)
  const decode = cases
    .map(
      (c) =>
        `        case ${pattern(c.literals)}: self = .${caseName(c.label)}(try ${c.payload}(from: decoder))`,
    )
    .join('\n')
  const encode = cases
    .map((c) => `        case .${caseName(c.label)}(let payload): try payload.encode(to: encoder)`)
    .join('\n')
  const tuple = `(${keys.map((_, i) => slot(i)).join(', ')})`

  return `public enum ${name}: Codable, Hashable, Sendable {
${body}
    /// Upstream added a variant this build does not know. Carries the raw value
    /// so a client can log or skip it without dropping the stream.
    case unknown(JSONValue)

    private enum Discriminant: String, CodingKey {
${keys.map((k) => `        case ${ident(k)}`).join('\n')}
    }

    public init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: Discriminant.self) else {
            self = .unknown(try JSONValue(from: decoder))
            return
        }
${reads}
        switch ${tuple} {
${decode}
        default: self = .unknown(try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
${encode}
        case .unknown(let raw): try raw.encode(to: encoder)
        }
    }
}`
}

const problems = []
function fail(where, why) {
  problems.push(`${where}: ${why}`)
  throw new Error(`${where}: ${why}`)
}

// ── run ─────────────────────────────────────────────────────────────────────

const jsonSchemas = new Map() // "domain.exportName" → json schema
for (const [domain, mod] of modules) {
  for (const [exportName, val] of Object.entries(mod)) {
    if (!isSchema(val)) continue
    try {
      jsonSchemas.set(`${domain}.${exportName}`, z.toJSONSchema(val, { io: 'output', unrepresentable: 'any' }))
    } catch (e) {
      problems.push(`${domain}.${exportName}: toJSONSchema failed — ${e.message.split('\n')[0]}`)
    }
  }
}

// ── the method table: the assertion that matters more than the types ────────
//
// Resolved before anything is emitted, because the request and response types
// have to be emitted first and nominally.

const byStem = new Map()
for (const qualified of jsonSchemas.keys()) {
  const exportName = qualified.split('.')[1]
  const m = /^(.*?)(RequestSchema|ValueSchema)$/.exec(exportName)
  if (!m) continue
  const entry = byStem.get(m[1]) ?? {}
  entry[m[2] === 'RequestSchema' ? 'request' : 'value'] = { qualified, typeName: typeNameOf(exportName) }
  byStem.set(m[1], entry)
}

const methods = []
const missing = []
for (const method of contract.methodKeys()) {
  const stem = methodStem(method)
  const pair = byStem.get(stem)
  if (!pair?.request || !pair?.value) {
    missing.push(`${method} → 期望 ${stem}RequestSchema / ${stem}ValueSchema，实际 ${JSON.stringify(Object.keys(pair ?? {}))}`)
    continue
  }
  methods.push({ method, request: pair.request, value: pair.value })
}

if (missing.length) {
  console.error(
    `\n方法→schema 的命名约定被打破了 —— 这是约定不是契约，上游改名就会漏。\n` +
      `缺失 ${missing.length}/${contract.methodKeys().length}:\n  ${missing.join('\n  ')}\n`,
  )
  process.exit(1)
}

// Nominal first (distinct types per method), then everything else, which is
// free to dedup into whatever already exists.
const skipped = []
const emitTopLevel = (qualified, nominal) => {
  const name = typeNameOf(qualified.split('.')[1])
  if (usedNames.has(name)) return
  try {
    const emitted = swiftType(jsonSchemas.get(qualified), name, nominal)
    if (emitted !== name) {
      usedNames.add(name)
      declarations.set(name, `public typealias ${name} = ${emitted}`)
    }
  } catch (e) {
    skipped.push(`${qualified}: ${e.message}`)
  }
}

for (const { request, value } of methods) {
  emitTopLevel(request.qualified, true)
  emitTopLevel(value.qualified, true)
}
for (const qualified of jsonSchemas.keys()) emitTopLevel(qualified, false)

const methodTable = `/// Every wire method in \`RpcMethodMap\`, with its request and response types.
/// Generated from the map itself, so a method that gains or loses a schema
/// fails codegen rather than silently disappearing from this list.
public enum WireMethod: String, CaseIterable, Sendable {
${methods.map((m) => `    case ${caseName(m.method.replace('.', '-'))} = ${JSON.stringify(m.method)}`).join('\n')}
}

${methods
  .map(
    (m) => `extension ${m.request.typeName}: WireRequest {
    public typealias Response = ${m.value.typeName}
    public static var wireMethod: WireMethod { .${caseName(m.method.replace('.', '-'))} }
}`,
  )
  .join('\n\n')}`

// ── write ───────────────────────────────────────────────────────────────────

const header = `// Generated by tools/schema-codegen from @deepseek-ai/dsh-host-apiproxy ${contract.version}.
// Do not edit. Run \`node tools/schema-codegen/generate.mjs\` instead.

import Foundation

/// The upstream version this file was generated from. \`dsh-probe\` checks it
/// against the running host so a mismatch is loud, not mysterious.
public let generatedContractVersion = ${JSON.stringify(contract.version)}
`

mkdirSync(outDir, { recursive: true })
writeFileSync(
  join(outDir, 'Contract.swift'),
  `${header}\n${[...declarations.values()].sort().join('\n\n')}\n`,
)
writeFileSync(
  join(outDir, 'WireMethods.swift'),
  `// Generated by tools/schema-codegen from @deepseek-ai/dsh-host-apiproxy ${contract.version}.\n// Do not edit.\n\n${methodTable}\n`,
)

console.log(`契约版本      ${contract.version}`)
console.log(`schema 转换   ${jsonSchemas.size}`)
console.log(`Swift 类型    ${declarations.size}`)
console.log(`方法覆盖      ${methods.length}/${contract.methodKeys().length}`)
if (skipped.length) {
  console.log(`\n未生成 ${skipped.length} 个（不在方法表上则无害）:`)
  for (const s of skipped) console.log('  ' + s)
}
console.log(`\n→ ${outDir}`)
