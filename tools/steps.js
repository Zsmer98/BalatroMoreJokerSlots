#!/usr/bin/env node
// 离线分析 history.log（config.lua 里 record_history = true 才会生成）：算出每次变化里各条流各走了几步，并自动校验消耗模型。
//
// 依据 NOTES 主笔记 §5.1，pseudoseed 的状态推进是纯函数：
//     s' = abs( round13( (2.134453429141 + s * 1.72431234) % 1 ) )
// 所以拿 from 反复迭代，数几步撞上 to，就是这条流被消耗的次数。
//
// 用法:
//   node tools/steps.js            分析 + 校验
//   node tools/steps.js --verify   只验证推进公式的 13 位小数假设
//   node tools/steps.js --all      连没有流变化的记录一起列出

const fs = require("fs");
const path = require("path");

const DIR   = path.join(__dirname, "..");
const STATE = path.join(DIR, "state.dat");
const HIST  = path.join(DIR, "history.log");

const MAX_STEPS = 64;   // 一次商店操作不可能把同一条流推这么多步

// ---------- 推进公式 ----------
const round13 = (x) => parseFloat(x.toFixed(13));
const advance = (s) => Math.abs(round13((2.134453429141 + s * 1.72431234) % 1));

function stepsBetween(from, to) {
  let s = from;
  for (let n = 1; n <= MAX_STEPS; n++) {
    s = advance(s);
    if (s === to) return n;
  }
  return null;
}

// ---------- 验证：所有状态值都该恰好落在 13 位小数上 ----------
function verify() {
  if (!fs.existsSync(STATE)) return console.error("没有 state.dat");
  const s = JSON.parse(fs.readFileSync(STATE, "utf8"));
  const st = s.rng.streams || {};
  const keys = Object.keys(st);

  let ok = 0; const bad = [];
  for (const k of keys) {
    const v = parseFloat(st[k]);
    if (round13(v) === v) ok++; else bad.push([k, st[k]]);
  }

  console.log(`流状态 ${ok}/${keys.length} 恰好落在 13 位小数上` +
              (bad.length ? "  ← 有例外！" : "  → §5.1 量化假设成立"));
  for (const [k, v] of bad.slice(0, 20)) console.log("   ", k, v);

  const hs = parseFloat(s.run.hashed_seed);
  console.log(`hashed_seed = ${s.run.hashed_seed}  (13位小数=${round13(hs) === hs} ` +
              `→ 所以流状态和 hashed_seed 不同源，必须全精度传输)`);
}

// ---------- 消耗模型 ----------
// 每个商店格子先抽 cdt 定类型，然后按类型走各自的流。
// 期望的每格消耗（ante 记作 A，稀有度记作 r）：
//   任何格子   : cdt<A>                       ×1
//   Joker      : rarity<A>sho, Joker<r>sho<A>, edisho<A>, etperpoll<A>  各 ×1
//   Tarot      : Tarot sho<A>                 ×1
//   Planet     : Planet sho<A>                ×1
//   playing card: frontsho<A>                 ×1
function expected(shop, ante) {
  const A = ante;
  const exp = {};
  const bump = (k, n = 1) => { exp[k] = (exp[k] || 0) + n; };

  bump(`cdt${A}`, shop.length);
  for (const c of shop) {
    if (c.s === "Joker") {
      bump(`rarity${A}sho`);
      bump(`Joker${c.r}sho${A}`);
      bump(`edisho${A}`);
      bump(`etperpoll${A}`);
    } else if (c.s === "Tarot")   bump(`Tarotsho${A}`);
    else if (c.s === "Planet")    bump(`Planetsho${A}`);
    else if (c.s === "Spectral")  bump(`Spectralsho${A}`);
    else if (c.s === "Enhanced") { bump(`frontsho${A}`); bump(`Enhancedsho${A}`); } // 牌面 + 选附魔（v_illusion 才有）
    else                          bump(`frontsho${A}`);   // Default 实体牌只选牌面
  }
  return exp;
}

function analyze() {
  if (!fs.existsSync(HIST))
    return console.error("没有 history.log（需在 config.lua 打开 record_history，并进商店操作几次）");

  const showAll = process.argv.includes("--all");
  const allSessions = process.argv.includes("--all-sessions");
  const allRecs = fs.readFileSync(HIST, "utf8").split("\n").filter(Boolean)
    .map((l, i) => { try { return JSON.parse(l); } catch { console.error(`第 ${i+1} 行解析失败`); return null; } })
    .filter(Boolean);

  // history.log 累积多次游戏 session，每次重启换一版 predict.lua。
  // 拿旧 predict 的预测对账当前逻辑毫无意义（旧版没版本预测/没 illusion 处理）。
  // 按时间戳 gap>60s 切 session，默认只分析最新一段。--all-sessions 看全部。
  let recs = allRecs;
  if (!allSessions) {
    let start = 0;
    for (let i = 1; i < allRecs.length; i++) {
      if ((allRecs[i].t || 0) - (allRecs[i - 1].t || 0) > 60) start = i;
    }
    recs = allRecs.slice(start);
    if (start > 0) console.log(`（已聚焦最新 session：跳过前 ${start} 条旧记录，--all-sessions 看全部）`);
  }

  const real = recs.filter(r => r.changed);
  console.log(`本段 ${recs.length} 条，其中有流变化的 ${real.length} 条` +
              (showAll ? "" : "（只列这些，--all 看全部）"));

  let pass = 0, fail = 0;
  let predHit = 0, predSet = 0, predMiss = 0, predEdiMiss = 0;
  let prevRr = null;
  for (let i = 0; i < recs.length; i++) {
    const r = recs[i];

    // 预测只对"下一次 reroll"负责。一条记录代表真 reroll 的判据：reroll 成本递增。
    // rr 不变的记录是买牌/卖牌/重复帧 —— 那时 shop 已被玩家改动，
    // 拿"对下次 reroll 的预测"去对它必然错，不能算进命中率。
    const isReroll = prevRr !== null && r.rr > prevRr;
    if (r.rr != null) prevRr = r.rr;

    if (!r.changed && !showAll) continue;

    // 兼容旧格式：早期记录的 shop 是纯字符串数组，没有 set
    const shop = (r.shop || []).map(c => typeof c === "string" ? { k: c, s: null } : c);
    const typed = shop.every(c => c.s);

    console.log(`\n--- #${i}  ante=${r.ante}  $${r.money}  reroll=${r.rr}` +
                (r.baseline ? "  [baseline]" : ""));
    console.log("    shop: " + (shop.map(c =>
      c.k + (c.s ? `(${c.s}${c.r != null ? " r" + c.r : ""}${c.e ? " " + c.e : ""})` : "")
    ).join("  ") || "(空)"));

    if (!r.changed) { console.log("    流状态无变化"); continue; }

    // 实测步数
    const got = {};
    for (const [k, { from, to }] of Object.entries(r.changed)) {
      got[k] = from === "NEW" ? "NEW" : stepsBetween(parseFloat(from), parseFloat(to));
    }

    // 期望步数（只有拿到 set 才能算）
    const exp = typed && shop.length ? expected(shop, r.ante) : null;

    const keys = [...new Set([...Object.keys(got), ...(exp ? Object.keys(exp) : [])])].sort();
    let recOk = !!exp;
    for (const k of keys) {
      const g = got[k], e = exp ? exp[k] : undefined;
      // NEW 表示这条流本局首次出现，那一步也是一次真实消耗
      const gN = g === "NEW" ? 1 : g;
      let mark = "";
      if (exp) {
        // illusion 流（v_illusion）无法从 shop 精确反推：每格掷 1 次，实体牌还有
        // 额外的门掷 + 过门后的版本掷。它是独立流，步数错也不影响其他流的预测，
        // 所以只登记、不判 fail。
        if (k === "illusion") { mark = "（illusion 流，独立，不校验）"; }
        // 重抽次数无法从商店内容反推 —— 取决于抽中了几次 UNAVAILABLE 占位符。
        // 但有个真实上限：同一池最多被抽 <基础流步数> 次，故重抽也不会超过这个数。
        else {
        const rs = k.match(/^(.*)_resample\d+$/);
        if (rs) {
          const cap = exp[rs[1]] || 0;
          if (gN >= 0 && gN <= cap) mark = `✓ 重抽 ${gN} 次（上限 ${cap}）`;
          else { mark = `✗ 重抽 ${gN} 次超过上限 ${cap}`; recOk = false; }
        } else if (gN === e) {
          mark = "✓";
        } else {
          mark = `✗ 期望 ${e === undefined ? 0 : e}`; recOk = false;
        }
        }
      }
      console.log(`    ${k.padEnd(26)} ${String(g === null ? "撞不上(>64)" : g).padEnd(6)} ${mark}`);
    }
    // 消耗模型 expected() 只建模一次 reroll 的消耗。买牌/买包帧会动 shop_pack 等
    // 别的流，对它判 fail 无意义 —— 只在真 reroll 记录上计入 pass/fail。
    if (exp && isReroll) { if (recOk) pass++; else fail++; console.log(`    => ${recOk ? "模型吻合" : "模型不吻合"}`); }
    else if (exp) console.log("    => (非 reroll 变化，消耗模型不适用)");

    // 预测 vs 实际。prev_pred 是**上一帧**对"下次 reroll"的预测，
    // 而本条记录的 shop 就是那次 reroll 的实际结果 —— 同一行里直接对照。
    // 只在真 reroll 时对账（见 isReroll）：买牌/卖牌帧的 shop 已被玩家改动。
    if (r.prev_pred && r.prev_pred.length && !isReroll) {
      console.log("    预测 vs 实际: (非 reroll 变化，跳过对账)");
    } else if (r.prev_pred && r.prev_pred.length && isReroll) {
      console.log("    预测 vs 实际:");
      const n = Math.max(r.prev_pred.length, shop.length);
      for (let j = 0; j < n; j++) {
        const p = r.prev_pred[j], a = shop[j];
        const pTxt = p ? (p.key || `<${p.set}${p.rarity != null ? " r" + p.rarity : ""}>`) : "—";
        const aTxt = a ? a.k : "—";

        // create_card_for_shop 用的类型名和卡牌 center 的 set 字段对不上：
        // 类型 'Base' 出来的实体牌，其 center.set 是 'Default'。
        const setEq = p && a && (p.set === a.s || (p.set === "Base" && a.s === "Default"));

        let mark;
        if (!p || !a)                     mark = "格数不符";
        else if (p.key && p.key === a.k) {
          // 牌对了，再对版本（都为空 == 无版本，也算一致）
          const pe = p.e || null, ae = a.e || null;
          if (pe === ae) { mark = "✓ 命中" + (ae ? `（含版本 ${ae}）` : ""); predHit++; }
          else           { mark = `牌对/版本错：预测 ${pe || "无"} 实际 ${ae || "无"}`; predEdiMiss++; }
        }
        else if (!p.key && setEq)         { mark = "✓ 类型对（牌面本版不预测）"; predSet++; }
        else if (setEq)                   { mark = "类型对/牌不对"; predSet++; }
        else                              { mark = "✗ 类型也不对"; predMiss++; }
        console.log(`      slot${j + 1}  预测 ${pTxt.padEnd(22)}${p && p.e ? "+" + p.e : ""} 实际 ${aTxt.padEnd(22)}${a && a.e ? "+" + a.e : ""} ${mark}`);
      }
    }
  }

  if (pass + fail > 0) {
    console.log(`\n${"=".repeat(50)}`);
    console.log(`消耗模型校验: 吻合 ${pass} / 不吻合 ${fail}`);
    if (fail === 0) {
      console.log("→ 每格 cdt×1；Joker 再走 rarity + Joker<r>sho<A> + edisho + etperpoll 各×1；");
      console.log("  Tarot/Planet 各走自己的流×1；实体牌走 frontsho×1");
    }
  }

  if (predHit + predSet + predMiss + predEdiMiss > 0) {
    console.log(`\n${"=".repeat(50)}`);
    console.log(`预测校验: 牌面命中 ${predHit} / 仅类型对 ${predSet} / 牌对版本错 ${predEdiMiss} / 全错 ${predMiss}`);
    if (predMiss === 0 && predEdiMiss === 0) console.log("→ 预测链路逐格正确（仅类型对的是 Base 实体牌，本版不预测牌面）");
    else console.log("→ 有偏差。看对应记录的 trace（在 state.dat 的 prediction 里，需打开 mod_predict）定位是哪一级错的");
  } else {
    console.log("\n（还没有预测/实际配对：需要重启加载 predict.lua，然后进商店 reroll 两次以上）");
  }
}

if (process.argv.includes("--verify")) verify();
else { verify(); console.log(); analyze(); }
