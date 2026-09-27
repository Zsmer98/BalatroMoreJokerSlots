// 商店队列预测 —— predict.lua 的 JS 移植版。
// 有了 luajit_rng.js（逐位复刻 LuaJIT PRNG），游戏外也能算了，
// 所以不再受 mod 端预算深度（predict_rerolls）的限制，想翻多远算多远。
//
// 输入是 state.json 的快照，逐条对应 predict.lua：
//   类型   create_card_for_shop  (UI_definitions.lua:822)
//   稀有度 SMODS.poll_rarity     (smods/src/utils.lua)
//   选牌   pseudorandom_element + 重抽 (common_events.lua:2181)
//   版本   poll_edition          (smods/src/overrides.lua:2227)
//   逐格 cull：选中就把本地池副本打成 UNAVAILABLE（NOTES §14）
//
// 双环境：Node 下 module.exports，浏览器下挂 window.MJSPredict。
(function (root, factory) {
  const R = (typeof require !== "undefined" && typeof module !== "undefined")
    ? require("./luajit_rng.js") : root.LuaJITRNG;
  const API = factory(R);
  if (typeof module !== "undefined" && module.exports) module.exports = API;
  else root.MJSPredict = API;
})(typeof window !== "undefined" ? window : globalThis, function (R) {
  "use strict";

  const VANILLA_RARITY = { Common: 1, Uncommon: 2, Rare: 3, Legendary: 4 };

  // 影子 RNG：首次用到某流从快照拷一份，之后只在本地迭代，永不回写。
  // 同时记下「读过哪些流、读时是什么值」（deps）—— 调用方据此判断缓存是否失效：
  // 只要这些流一条都没动，结果就一定不变（打牌时别的流在推进也不用重算）。
  function makeRng(state) {
    const real = (state.rng && state.rng.streams) || {};
    const seed = (state.run && state.run.seed) || "";
    const hashed = parseFloat((state.run && state.run.hashed_seed) || 0) || 0;
    const shadow = Object.create(null);
    const deps = Object.create(null);
    return {
      deps,
      // 推进一步并返回 d（= randomseed(u) 后第一发 math.random）
      draw(key) {
        let v = shadow[key];
        if (v === undefined) {
          deps[key] = real[key] !== undefined ? real[key] : null;   // 原始字符串，精确比较
          v = real[key] !== undefined ? parseFloat(real[key]) : R.pseudohash(key + seed);
        }
        v = R.advance(v);
        shadow[key] = v;
        return R.firstRandom((v + hashed) / 2);
      },
    };
  }

  const rateOf = (rates, ty) => (rates && rates[String(ty).toLowerCase()]) || 0;

  // create_card_for_shop：total_rate 的算法与 rates 列表的构成是两段独立代码
  function buildRates(s, rng, hasIllusion, trace) {
    const rates = s.rates || {};
    const objBuf = (s.poll_config && s.poll_config.obj_buffer) || ["Tarot", "Planet", "Spectral"];
    let total = (rates.joker || 0) + (rates.playing_card || 0);
    for (const v of objBuf) total += rateOf(rates, v);

    // v_illusion 时实体牌是 Base 还是 Enhanced 要掷 illusion 流。
    // 这是表构造器里的表达式 → 急切求值：持有它时每格都推进一次，无论最终什么类型。
    let pcType = "Base";
    if (hasIllusion) {
      const d = rng.draw("illusion");
      if (d > 0.6) pcType = "Enhanced";
      if (trace) trace.push({ step: "illusion", d, result: pcType });
    }

    const list = [
      { type: "Joker", val: rates.joker || 0 },
      { type: "Tarot", val: rates.tarot || 0 },
      { type: "Planet", val: rates.planet || 0 },
      { type: pcType, val: rates.playing_card || 0 },
      { type: "Spectral", val: rates.spectral || 0 },
    ];
    for (const v of objBuf) {
      if (v !== "Tarot" && v !== "Planet" && v !== "Spectral") list.push({ type: v, val: rateOf(rates, v) });
    }
    return { list, total };
  }

  // SMODS.poll_rarity：权重 × <rarity>_mod 后归一化，再累加比较
  function pollRarity(s, rng, ante) {
    const rar = (s.poll_config && s.poll_config.joker_rarities) || [];
    const d = rng.draw("rarity" + ante + "sho");
    if (!rar.length) return { rarity: 1, d };

    const mods = s.rarity || {};
    const w = [];
    let total = 0;
    for (const r of rar) {
      const m = mods[String(r.key).toLowerCase() + "_mod"];
      const ww = (r.weight || 0) * (m == null ? 1 : m);
      w.push(ww); total += ww;
    }
    if (total <= 0) return { rarity: 1, d };

    let acc = 0;
    for (let i = 0; i < rar.length; i++) {
      acc += w[i] / total;
      if (d < acc) return { rarity: VANILLA_RARITY[rar[i].key] || rar[i].key, d };
    }
    const last = rar[rar.length - 1];
    return { rarity: VANILLA_RARITY[last.key] || last.key, d };
  }

  // pseudorandom_element + 重抽循环。首次重抽的 key 是 _resample2（it 先自增）
  function pickCenter(rng, pool, poolKey, trace, label) {
    const n = pool.length;
    if (!n) return null;
    let d = rng.draw(poolKey);
    let i = Math.floor(d * n);
    let center = pool[i];
    if (trace) trace.push({ step: label, key: poolKey, d, index: i + 1, got: center });

    let it = 1;
    while (center === "UNAVAILABLE") {
      it++;
      if (it > 40) return null;
      const k = poolKey + "_resample" + it;
      d = rng.draw(k);
      i = Math.floor(d * n);
      center = pool[i];
      if (trace) trace.push({ step: label + "/resample", key: k, d, index: i + 1, got: center });
    }
    return center;
  }

  // poll_edition。需要 state.editions（mod 端 dump 的版本池与权重）
  function pollEdition(s, rng, key, noNeg, guaranteed) {
    const eds = s.editions;
    const d = rng.draw(key);
    if (!eds || !eds.pool) return { edition: null, d, unavailable: true };

    // 原版版本倒序插到队首，其余保持顺序（SMODS overrides.lua 的行为）
    const opts = [];
    for (const e of eds.pool) {
      const meta = eds.weights && eds.weights[e];
      if (meta && meta.vanilla) opts.unshift(e); else opts.push(e);
    }
    const avail = [];
    let total = 0;
    for (const e of opts) {
      const meta = e !== "UNAVAILABLE" && eds.weights && eds.weights[e];
      if (meta) { avail.push({ name: e, w: meta.w || 0, gw: meta.gw || 0 }); total += meta.w || 0; }
    }
    if (total <= 0) return { edition: null, d };

    let weights = avail.map(v => v.w);
    if (!guaranteed) { total = total + total / 4 * 96; weights = avail.map(v => v.gw); }

    let wi = 0;
    for (let i = 0; i < avail.length; i++) {
      wi += weights[i];
      if (d > 1 - wi / total) {
        // no_neg 抽中负片：不返回、继续往下落（原版行为，权重顺延给下一个）
        if (!(avail[i].name === "e_negative" && noNeg)) return { edition: avail[i].name, d };
      }
    }
    return { edition: null, d };
  }

  const clonePools = (s) => {
    const jp = {}, cp = {};
    const pj = (s.pools && s.pools.joker) || {};
    const pc = (s.pools && s.pools.consumable) || {};
    for (const k of Object.keys(pj)) jp[k] = { pool: pj[k].pool.slice(), key: pj[k].pool_key };
    for (const k of Object.keys(pc)) cp[k] = { pool: pc[k].pool.slice(), key: pc[k].pool_key };
    return { jp, cp };
  };
  const consume = (store, k, center) => {
    const e = store[k];
    if (!e || !center) return;
    const i = e.pool.indexOf(center);
    if (i >= 0) e.pool[i] = "UNAVAILABLE";
  };

  // 预测未来 count 次 reroll。池子每轮从快照重置（连续 reroll 不买牌 → used_jokers 基线不变），
  // 流状态全程延续（这是 reroll 之间唯一变化的东西）。
  function predict(s, count, opts) {
    opts = opts || {};
    const ante = s.run && s.run.ante;
    const slots = (s.shop && s.shop.joker_max) || 2;
    if (ante == null || !s.pools) return null;

    const hasIllusion = ((s.pool_state && s.pool_state.used_vouchers) || []).includes("v_illusion");
    const rng = makeRng(s);
    const out = { ante, slots, count, rerolls: [] };

    for (let ri = 1; ri <= count; ri++) {
      const { jp, cp } = clonePools(s);
      const cards = [];
      for (let slot = 1; slot <= slots; slot++) {
        const trace = opts.trace ? [] : null;
        const { list, total } = buildRates(s, rng, hasIllusion, trace);

        const d = rng.draw("cdt" + ante);
        const polled = d * total;
        if (trace) trace.push({ step: "cdt", d, polled, total });

        let ty = null, check = 0;
        for (const v of list) {
          if (polled > check && polled <= check + v.val) { ty = v.type; break; }
          check += v.val;
        }

        const entry = { slot, set: ty };
        if (trace) entry.trace = trace;

        if (!ty) {
          entry.note = "无类型匹配（polled 恰为 0）";
        } else if (ty === "Joker") {
          const pr = pollRarity(s, rng, ante);
          entry.rarity = pr.rarity;
          const e = jp[String(pr.rarity)];
          if (e) {
            const center = pickCenter(rng, e.pool, e.key, trace, "pool");
            entry.key = center;
            consume(jp, String(pr.rarity), center);
            const ed = pollEdition(s, rng, "edisho" + ante, false, false);
            if (ed.edition) entry.edition = ed.edition;
            if (ed.unavailable) entry.editionUnknown = true;
          } else entry.note = "缺稀有度 " + pr.rarity + " 的池子快照";
        } else if (cp[ty]) {
          const center = pickCenter(rng, cp[ty].pool, cp[ty].key, trace, "pool");
          entry.key = center;
          consume(cp, ty, center);
        } else {
          entry.note = "实体牌牌面不预测";
          if (hasIllusion) {
            const d2 = rng.draw("illusion");
            if (d2 > 0.8) {
              const ed = pollEdition(s, rng, "illusion", true, true);
              if (ed.edition) entry.edition = ed.edition;
            }
          }
        }
        cards.push(entry);
      }
      out.rerolls.push({ index: ri, cards });
    }
    out.deps = rng.deps;   // 这次预测实际读过的流及其当时的值
    return out;
  }

  return { predict, makeRng, pollEdition, pollRarity };
});
