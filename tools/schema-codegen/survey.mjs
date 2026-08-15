/**
 * Reports which JSON Schema constructs the contract actually uses, so the
 * emitter only has to handle those — and so an upstream version that starts
 * using a new one shows up here instead of as wrong Swift.
 */
import { openContract } from './resolve.mjs'

const contract = openContract()
const { z } = await contract.zod()
const modules = await contract.schemaModules()

const isSchema = (v) => v && typeof v === 'object' && typeof v._zod === 'object'
const kinds = new Map()
const bump = (k, sample) => {
  const hit = kinds.get(k) ?? { n: 0, sample }
  hit.n++
  kinds.set(k, hit)
}

let hasDefs = false
let hasRef = false

function walk(node, path) {
  if (node === null || typeof node !== 'object') return
  if (Array.isArray(node)) return node.forEach((n, i) => walk(n, `${path}[${i}]`))

  const keys = Object.keys(node).filter((k) => k !== '$schema').sort()
  if (keys.length === 0) bump('<empty: any>', path)
  else bump(keys.join('+'), path)

  if (node.$defs) hasDefs = true
  if (node.$ref) hasRef = true

  for (const [k, v] of Object.entries(node)) {
    if (k === 'properties' || k === '$defs') for (const [pk, pv] of Object.entries(v)) walk(pv, `${path}.${pk}`)
    else if (['items', 'additionalProperties', 'not'].includes(k)) walk(v, `${path}.${k}`)
    else if (['anyOf', 'oneOf', 'allOf', 'prefixItems'].includes(k)) walk(v, `${path}.${k}`)
  }
}

let converted = 0
for (const [domain, mod] of modules) {
  for (const [name, val] of Object.entries(mod)) {
    if (!isSchema(val)) continue
    let js
    try {
      js = z.toJSONSchema(val, { io: 'output', unrepresentable: 'any' })
    } catch (e) {
      console.log(`SKIP ${domain}.${name}: ${e.message.split('\n')[0]}`)
      continue
    }
    converted++
    walk(js, `${domain}.${name}`)
  }
}

console.log(`\n转换成功 ${converted} 个 schema`)
console.log(`$defs 出现: ${hasDefs}    $ref 出现: ${hasRef}\n`)
console.log('节点关键字组合（按出现次数）:')
for (const [k, v] of [...kinds].sort((a, b) => b[1].n - a[1].n)) {
  console.log(`  ${String(v.n).padStart(5)}  ${k.padEnd(52)} e.g. ${v.sample}`)
}
