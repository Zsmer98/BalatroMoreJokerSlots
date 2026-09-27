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

  // SMODS.poll_rarity：权重 × <rarity>_mod 后归一化，再累加比较。
  // append：商店是 "sho"，小丑包是 "buf"（流 key = "rarity" + 底注 + append）
  function pollRarity(s, rng, ante, append) {
    const rar = (s.poll_config && s.poll_config.joker_rarities) || [];
    const d = rng.draw("rarity" + ante + (append == null ? "sho" : append));
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

  // poll_edition。需要 state.editions（mod 端 dump 的版本池与权重）。
  // mod：非保底时每个版本权重的倍数（smods overrides.lua:2278、2291），标准包传 2
  function pollEdition(s, rng, key, noNeg, guaranteed, mod) {
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

    let weights = avail.map(v => v.w), modifier = 1;
    if (!guaranteed) { total = total + total / 4 * 96; weights = avail.map(v => v.gw); modifier = mod || 1; }

    let wi = 0;
    for (let i = 0; i < avail.length; i++) {
      wi += weights[i] * modifier;
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
    // 有演出家时 get_current_pool 不剔除已用过的牌（SMODS.showman，common_events.lua:2332），
    // 同一次 reroll 里前面格子抽中的牌后面还能再出 → 不做逐格剔除
    const showman = !!(s.pool_state && s.pool_state.showman);
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
            if (!showman) consume(jp, String(pr.rarity), center);
            const ed = pollEdition(s, rng, "edisho" + ante, false, false);
            if (ed.edition) entry.edition = ed.edition;
            if (ed.unavailable) entry.editionUnknown = true;
          } else entry.note = "缺稀有度 " + pr.rarity + " 的池子快照";
        } else if (cp[ty]) {
          const center = pickCenter(rng, cp[ty].pool, cp[ty].key, trace, "pool");
          entry.key = center;
          if (!showman) consume(cp, ty, center);
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

  // ================= 补充包 =================
  // 开包时按顺序生成 extra 张牌（card.lua:2062-2122）。每张先走包自己的 create_card
  // （smods game_object.lua:1619-1769），再进 create_card（common_events.lua:2433）。
  // 和商店一样，每生成一张就登记 used_jokers（card.lua:476），同一个包里后面的牌不会再抽到它（有演出家除外）。
  // 每个包都按「下一个就开它」从当前状态算：各包用独立的影子 RNG 和池子副本。

  // 旧版快照（没有 packs 字段）按 key 推种类和张数：p_<种类>_<normal|jumbo|mega>_<n>（game.lua 的原版包）
  const PACK_FALLBACK = { arcana: ["Arcana", 3, 5], celestial: ["Celestial", 3, 5], spectral: ["Spectral", 2, 4],
                          standard: ["Standard", 3, 5], buffoon: ["Buffoon", 2, 4] };
  function packInfo(b) {
    if (b.kind && b.extra != null) return { kind: b.kind, size: b.extra, choose: b.choose || 1 };
    const m = /^p_([a-z]+)_(normal|jumbo|mega)/.exec(b.key || "");
    const f = m && PACK_FALLBACK[m[1]];
    if (!f) return null;
    return { kind: f[0], size: m[2] === "normal" ? f[1] : f[2], choose: m[2] === "mega" ? 2 : 1 };
  }

  function packCtx(s) {
    const ps = s.pool_state || {};
    const { jp, cp } = clonePools(s);
    return {
      s, ante: s.run.ante, rng: makeRng(s), jp, cp,
      held: new Set(ps.used_jokers || []),      // 当前场上存在的所有牌（持有的、商店里摆着的…）
      banned: new Set(ps.banned_keys || []),
      vouchers: new Set(ps.used_vouchers || []),
      showman: !!ps.showman,
      std: s.packs && s.packs.std,
    };
  }
  // 生成了一张牌：登记 used_jokers，并（没有演出家时）从池子里剔除
  function created(ctx, store, poolName, key) {
    ctx.held.add(key);
    if (!ctx.showman) consume(store, poolName, key);
  }

  // create_card 的 soulable 分支（common_events.lua:2439-2471）。
  // 原版没有模组灵魂牌：soul_smods_ 那一发照掷，但不影响结果，而且是独立的流，这里不用管。
  // 注意：手上已经有灵魂牌 / 黑洞（且没有演出家）时，对应那一发**根本不掷**。
  function soulCheck(ctx, type) {
    if (ctx.banned.has("c_soul")) return null;   // 整个分支被跳过
    const owned = (k) => ctx.held.has(k) && !ctx.showman;
    let forced = null;
    if ((type === "Tarot" || type === "Spectral") && !owned("c_soul")) {
      if (ctx.rng.draw("soul_" + type + ctx.ante) > 0.997) forced = "c_soul";
    }
    if ((type === "Planet" || type === "Spectral") && !owned("c_black_hole")) {
      if (ctx.rng.draw("soul_" + type + ctx.ante) > 0.997) forced = "c_black_hole";
    }
    return forced && !ctx.banned.has(forced) ? forced : null;
  }

  // 消耗牌：forced（灵魂/黑洞/望远镜）就不抽池子；否则池 key = 类型 + append + 底注
  function pickConsumable(ctx, type, append, forced) {
    let key = forced;
    if (!key) {
      const e = ctx.cp[type];
      if (!e) return null;
      key = pickCenter(ctx.rng, e.pool, type + append + ctx.ante);
    }
    if (key) created(ctx, ctx.cp, type, key);
    return key;
  }

  // 小丑包：稀有度 rarity<底注>buf → 池 Joker<r>buf<底注> → 版本 edibuf<底注>（贴纸走 packetper/packssjr，独立的流，不影响）
  function pickJoker(ctx) {
    const pr = pollRarity(ctx.s, ctx.rng, ctx.ante, "buf");
    const e = ctx.jp[String(pr.rarity)];
    if (!e) return { set: "Joker", rarity: pr.rarity, key: null };
    const key = pickCenter(ctx.rng, e.pool, "Joker" + pr.rarity + "buf" + ctx.ante);
    if (key) created(ctx, ctx.jp, String(pr.rarity), key);
    const ed = pollEdition(ctx.s, ctx.rng, "edibuf" + ctx.ante, false, false);
    const c = { set: "Joker", key, rarity: pr.rarity };
    if (ed.edition) c.edition = ed.edition;
    return c;
  }

  // SMODS.poll_seal({mod = 10})（smods utils.lua）：基础权重之和 ×50（基础 2%），乘 mod 后决定出不出蜡封，再按权重选种类
  function pollSeal(std, rng, ante, mod) {
    const avail = (std.seals || []).filter(x => x.k !== "UNAVAILABLE" && (x.w || 0) > 0);
    let total = 0, typeW = 0;
    for (const x of avail) { total += x.w; typeW += (x.gw != null ? x.gw : x.w); }
    total += total / 2 * 98;
    const d = rng.draw("stdseal" + ante);
    if (!(d > 1 - typeW * mod / total)) return null;
    const d2 = rng.draw("stdsealtype" + ante);
    let wi = 0;
    for (const x of avail) { wi += (x.gw != null ? x.gw : x.w); if (d2 > 1 - wi / typeW) return x.k; }
    return null;
  }

  // 标准包：版本 standard_edition<底注>（×2，不出负片）→ 蜡封 → stdset>0.6 才是附魔牌 →
  // 附魔池 Enhancedsta<底注> → 牌面 frontsta<底注>（G.P_CARDS 过滤排序后的顺序，由 mod 导出）
  function pickStandard(ctx) {
    const std = ctx.std;
    const ed = pollEdition(ctx.s, ctx.rng, "standard_edition" + ctx.ante, true, false, 2);
    const seal = pollSeal(std, ctx.rng, ctx.ante, 10);
    const enhanced = ctx.rng.draw("stdset" + ctx.ante) > 0.6;
    const key = enhanced ? pickCenter(ctx.rng, std.enhanced, "Enhancedsta" + ctx.ante) : "c_base";
    const front = std.fronts[Math.floor(ctx.rng.draw("frontsta" + ctx.ante) * std.fronts.length)];
    const c = { set: enhanced ? "Enhanced" : "Base", key, front };
    if (ed.edition) c.edition = ed.edition;
    if (seal) c.seal = seal;
    return c;
  }

  // 用灵魂牌时会变出哪个传奇：create_card('Joker', G.jokers, true, …, 'sou')（card.lua:1738）。
  // 传奇池的 key 是 'Joker4'（不带底注，整局共用一条流），版本走 edisou<底注>。
  // 和开包本身用的流不重叠，单独一个影子 RNG 算。
  function soulLegendary(s) {
    const e = s.pools && s.pools.joker && s.pools.joker["4"];
    if (!e) return null;
    const rng = makeRng(s);
    const key = pickCenter(rng, e.pool.slice(), e.pool_key || "Joker4");
    const ed = pollEdition(s, rng, "edisou" + s.run.ante, false, false);
    return key ? { key, edition: ed.edition || undefined } : null;
  }

  // 按顺序生成一个包的 size 张牌。ctx 里的影子 RNG / 池子 / used_jokers 会被推进（测试时可复用 ctx 模拟连开）
  function openPack(ctx, kind, size, P) {
    const res = { cards: [] };
    for (let i = 1; i <= size; i++) {
      let c;
      if (kind === "Buffoon") c = pickJoker(ctx);
      else if (kind === "Arcana") {
        const omen = ctx.vouchers.has("v_omen_globe") && ctx.rng.draw("omen_globe") > 0.8;
        const type = omen ? "Spectral" : "Tarot";
        c = { set: type, key: pickConsumable(ctx, type, omen ? "ar2" : "ar1", soulCheck(ctx, type)) };
        if (omen) c.omen = true;
      } else if (kind === "Celestial") {
        // 望远镜：第 1 张直接给打出次数最多的牌型的星球，不掷灵魂那一发，也不抽池子
        const tp = (ctx.vouchers.has("v_telescope") && i === 1) ? P.telescope_planet : null;
        c = { set: "Planet", key: pickConsumable(ctx, "Planet", "pl1", tp || soulCheck(ctx, "Planet")) };
        if (tp) c.telescope = true;
        if (ctx.vouchers.has("v_telescope") && i === 1 && !("telescope_planet" in P)) res.telescopeUnknown = true;
      } else if (kind === "Spectral") {
        c = { set: "Spectral", key: pickConsumable(ctx, "Spectral", "spe", soulCheck(ctx, "Spectral")) };
      } else if (kind === "Standard") c = pickStandard(ctx);
      if (!c) { res.unknown = "unsupported"; break; }   // 页面按语言翻译（unknown / std_restart / unsupported）
      // 灵魂牌 / 黑洞本身属于幻灵牌（create_card 里 _type 跟着 center.set 改，common_events.lua:2488）
      if (c.key === "c_soul" || c.key === "c_black_hole") c.set = "Spectral";
      res.cards.push(c);
    }
    return res;
  }

  function predictPacks(s) {
    if (!s || !s.run || s.run.ante == null || !s.pools) return null;
    const P = s.packs || {};
    const list = P.list || (s.shop && s.shop.boosters) || [];
    const out = [];
    list.forEach((b, idx) => {
      const pack = { index: idx + 1, key: b.key, name: b.name, sprite: b.sprite, cost: b.cost, cards: [] };
      const info = packInfo(b);
      if (!info) { pack.unknown = "unknown"; out.push(pack); return; }   // 不认识的包（模组包？）
      pack.kind = info.kind;
      pack.size = Math.max(1, info.size + (P.size_mod || 0));
      pack.choose = Math.min(info.choose + (P.choice_mod || 0), pack.size);
      if (info.kind === "Standard" && !(P.std && P.std.fronts && P.std.enhanced && P.std.seals)) {
        pack.unknown = "std_restart";   // 标准包需要新版 mod 导出的牌面顺序和附魔、蜡封池（重启游戏）
        out.push(pack); return;
      }
      const r = openPack(packCtx(s), info.kind, pack.size, P);
      pack.cards = r.cards;
      if (r.unknown) pack.unknown = r.unknown;
      if (r.telescopeUnknown) pack.telescopeUnknown = true;
      for (const c of pack.cards) if (c.key === "c_soul") c.legendary = soulLegendary(s);
      out.push(pack);
    });
    // 同种包共用同一组随机流：先开的那个才是算出来的这些
    for (const p of out) {
      const same = out.filter(q => q.kind && q.kind === p.kind);
      if (same.length > 1) p.sameKind = same.filter(q => q !== p).map(q => q.index);
    }
    return out;
  }

  return { predict, makeRng, pollEdition, pollRarity, predictPacks,
           _packCtx: packCtx, _openPack: openPack };   // 后两个给离线测试用（模拟连开几个包）
});
