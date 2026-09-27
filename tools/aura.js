#!/usr/bin/env node
// 算光环(Aura)接下来会给什么版本。读存档，不用开游戏。
// 依据：card.lua:1516 → poll_edition('aura', nil, no_neg=true, guaranteed=true)
// 权重 foil20/holo14/poly3/neg3，排除负片后：d>0.85 多彩 / >0.5 全息 / 其余 闪箔
//   （多彩 15% = 自身 7.5% + 负片被排除后顺延的 7.5%）
const fs = require("fs"), zlib = require("zlib"), path = require("path");
const { firstRandom } = require("./luajit_rng.js");

const SAVE = process.argv[2] || path.join(process.env.APPDATA, "Balatro", "1", "save.jkr");
const N = 40;

const t = zlib.inflateRawSync(fs.readFileSync(SAVE)).toString("latin1");
const seed = (t.match(/\["seed"\]="([^"]+)"/) || [])[1] || "?";
const hs = parseFloat((t.match(/\["hashed_seed"\]=([0-9.eE+-]+)/) || [])[1] || 0);
const auraM = t.match(/\["aura"\]=([0-9.eE+-]+)/);

const pseudohash = (s) => { let n = 1; for (let i = s.length; i >= 1; i--) n = ((1.1239285023 / n) * s.charCodeAt(i - 1) * Math.PI + Math.PI * i) % 1; return n; };
const round13 = (x) => parseFloat(x.toFixed(13));
const advance = (s) => Math.abs(round13((2.134453429141 + s * 1.72431234) % 1));
const label = (d) => d > 0.85 ? "★ 多彩 ×1.5倍率" : d > 0.5 ? "  全息 +10倍率" : "  闪箔 +50筹码";

console.log(`种子 ${seed}   存档时间 ${fs.statSync(SAVE).mtime.toLocaleString()}`);
console.log(`aura 流状态 ${auraM ? auraM[1] : "未初始化（本局还没用过光环）"}`);
console.log("-".repeat(50));

let s = auraM ? parseFloat(auraM[1]) : pseudohash("aura" + seed);
const polys = [];
const rows = [];
for (let n = 1; n <= N; n++) {
  s = advance(s);
  const d = firstRandom((s + hs) / 2);
  if (d > 0.85) polys.push(n);
  rows.push([n, d]);
}
for (const [n, d] of rows.slice(0, 24)) console.log(`  第 ${String(n).padStart(2)} 张  d=${d.toFixed(6)}  ${label(d)}`);
console.log("-".repeat(50));
if (polys.length) {
  console.log(`下一个多彩：第 ${polys[0]} 张` + (polys[0] === 1 ? "  ← 就是下一张！" : `（还要先用掉 ${polys[0] - 1} 张）`));
  console.log(`前 ${N} 张里的多彩位置：${polys.join(", ")}`);
} else {
  console.log(`前 ${N} 张都没有多彩`);
}
