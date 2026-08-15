/** Classifies every union in the contract, since unions are the only place the emitter has real choices to make. */
import { openContract } from './resolve.mjs'

const contract = openContract()
const { z } = await contract.zod()
const modules = await contract.schemaModules()
const isSchema = (v) => v && typeof v === 'object' && typeof v._zod === 'object'

const shapes = new Map()
const record = (kind, where) => {
  const hit = shapes.get(kind) ?? { n: 0, where: [] }
  hit.n++
  if (hit.where.length < 3) hit.where.push(where)
  shapes.set(kind, hit)
}

function classify(branches) {
  if (branches.every((b) => b.type === 'string' && 'const' in b)) return 'string-literals'
  if (branches.every((b) => b.type === 'object')) {
    const discriminants = branches.map((b) => {
      const consts = Object.entries(b.properties ?? {}).filter(([, v]) => 'const' in v)
      return consts.length === 1 ? consts[0][0] : null
    })
    if (discriminants.every((d) => d && d === discriminants[0])) return `discriminated(by ${discriminants[0]})`
    const multi = branches.map((b) =>
      Object.entries(b.properties ?? {})
        .filter(([, v]) => 'const' in v)
        .map(([k]) => k),
    )
    if (multi.every((m) => m.includes('type'))) return 'discriminated(by type, +extra consts)'
    return 'objects-no-discriminant'
  }
  if (branches.some((b) => b.type === 'null')) return 'nullable'
  return 'mixed: ' + branches.map((b) => b.type ?? (b.anyOf ? 'anyOf' : b.oneOf ? 'oneOf' : '?')).join('|')
}

function walk(node, path) {
  if (node === null || typeof node !== 'object') return
  if (Array.isArray(node)) return node.forEach((n, i) => walk(n, `${path}[${i}]`))
  if (Array.isArray(node.type)) record(`type-array: ${node.type.join('|')}`, path)

  const union = node.anyOf ?? node.oneOf
  if (union) record(classify(union), path)

  for (const [k, v] of Object.entries(node)) {
    if (k === 'properties' || k === '$defs') for (const [pk, pv] of Object.entries(v)) walk(pv, `${path}.${pk}`)
    else if (['items', 'additionalProperties', 'not'].includes(k)) walk(v, `${path}.${k}`)
    else if (['anyOf', 'oneOf', 'allOf', 'prefixItems'].includes(k)) walk(v, `${path}.${k}`)
  }
}

for (const [domain, mod] of modules) {
  for (const [name, val] of Object.entries(mod)) {
    if (!isSchema(val)) continue
    try {
      walk(z.toJSONSchema(val, { io: 'output', unrepresentable: 'any' }), `${domain}.${name}`)
    } catch {}
  }
}

console.log('联合类型分类:')
for (const [k, v] of [...shapes].sort((a, b) => b[1].n - a[1].n)) {
  console.log(`\n  ${v.n}x  ${k}`)
  for (const w of v.where) console.log(`        ${w}`)
}
