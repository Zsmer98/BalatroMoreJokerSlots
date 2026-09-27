// LuaJIT 2.0.5 的 math.randomseed / math.random 逐位复刻（Tausworthe TW223）
// 跨越 NOTES §8 记的那个障碍：原本判定「预测必须跑在游戏内，因为游戏外没法复刻
// LuaJIT 的 math.random」。这个文件把那条路打通了 —— 任何流都能离线算。
//
// 正确性：用 probe_result.txt 的 10 组 (u -> d) 实测数据验证，10/10 逐位精确。
// 自测：node tools/luajit_rng.js
//
// 双环境：Node 下 module.exports，浏览器下挂 window.LuaJITRNG。
(function (root) {
  "use strict";
  const M64 = (1n << 64n) - 1n;
  const buf = new ArrayBuffer(8);
  const f64 = new Float64Array(buf), u64 = new BigUint64Array(buf);
  const d2b = (d) => { f64[0] = d; return u64[0]; };
  const b2d = (b) => { u64[0] = b & M64; return f64[0]; };

  // TW223_GEN(i,k,q,s): z=gen[i]; z=(((z<<q)^z)>>(k-s)) ^ ((z & (~0 << (64-k)))<<s)
  function gen(state, i, k, q, s) {
    let z = state[i];
    const a = ((((z << BigInt(q)) & M64) ^ z) >> BigInt(k - s)) & M64;
    const b = ((z & ((M64 << BigInt(64 - k)) & M64)) << BigInt(s)) & M64;
    z = (a ^ b) & M64;
    state[i] = z;
    return z;
  }

  function step(state) {
    let r = 0n;
    r ^= gen(state, 0, 63, 31, 18);
    r ^= gen(state, 1, 58, 19, 28);
    r ^= gen(state, 2, 55, 24, 7);
    r ^= gen(state, 3, 47, 21, 8);
    // 构造 [1.0, 2.0) 区间的 double 位模式
    return (r & 0x000fffffffffffffn) | 0x3ff0000000000000n;
  }

  // math.randomseed(d)
  function seed(d) {
    const state = [0n, 0n, 0n, 0n];
    let r = 0x11090601;                 // 四个 8 位常量：1, 6, 9, 17
    for (let i = 0; i < 4; i++) {
      const m = 1n << BigInt(r & 255);
      r >>>= 8;
      d = d * 3.14159265358979323846 + 2.7182818284590452354;
      let u = d2b(d);
      if (u < m) u = (u + m) & M64;     // 保证高位非零
      state[i] = u;
    }
    for (let i = 0; i < 10; i++) step(state);
    return state;
  }

  const random = (state) => b2d(step(state)) - 1.0;      // math.random() → [0,1)
  const firstRandom = (u) => random(seed(u));            // randomseed(u) 后的第一发

  // --- pseudoseed 的流推进（NOTES §5.1，实测 645/645 落在 13 位小数上）---
  const round13 = (x) => parseFloat(x.toFixed(13));
  const advance = (s) => Math.abs(round13((2.134453429141 + s * 1.72431234) % 1));

  // 流首次访问时的初始化：pseudohash(key .. seed)，注意不过 %.13f 取整
  function pseudohash(str) {
    let num = 1;
    for (let i = str.length; i >= 1; i--) {
      num = ((1.1239285023 / num) * str.charCodeAt(i - 1) * Math.PI + Math.PI * i) % 1;
    }
    return num;
  }

  // 从流状态推进一步，返回 { state, u, d }
  function nextDraw(state, hashedSeed) {
    const s = advance(state);
    const u = (s + (hashedSeed || 0)) / 2;
    return { state: s, u: u, d: firstRandom(u) };
  }

  const API = { seed, step, random, firstRandom, advance, round13, pseudohash, nextDraw };

  if (typeof module !== "undefined" && module.exports) module.exports = API;
  else root.LuaJITRNG = API;
})(typeof window !== "undefined" ? window : globalThis);

// ---- 自测（仅 Node 直接运行时）----
if (typeof require !== "undefined" && typeof module !== "undefined" && require.main === module) {
  const { firstRandom } = module.exports;
  const cases = [
    [0, 0.79420629243124097], [9.9999999999999998e-13, 0.84022748598208263],
    [0.10000000000000001, 0.36286040601482883], [0.123456789012345, 0.91935391082288986],
    [0.33333333333333331, 0.16717259723250133], [0.5, 0.09657393438653461],
    [0.69999999989999995, 0.08880449493248288], [0.69999999999999996, 0.74317003625132272],
    [0.84999999999999998, 0.93733791243857856], [0.99999999989999999, 0.88457481162501805],
  ];
  let ok = 0;
  for (const [u, expect] of cases) {
    const got = firstRandom(u);
    if (got === expect) ok++;
    else console.log(`❌ u=${u}  期望 ${expect}  得到 ${got}`);
  }
  console.log(`${ok}/${cases.length} ` + (ok === cases.length ? "✅ 逐位精确" : "❌ 复刻不正确"));
}
