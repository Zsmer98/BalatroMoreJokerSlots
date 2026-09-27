--------------------------------------------------
-- 预测下一次 reroll 的商店内容
--
-- 全部计算跑在**影子状态**上，绝不写 G.GAME.pseudorandom。
-- 依据（都已实测/已验证，见 NOTES-shop-rng.md）：
--   §8   i = floor(d*N)+1，d = randomseed(u) 后第一发 math.random()
--   §12  每格 cdt×1；Joker 再走 rarity + Joker<r>sho<A>；消耗牌/实体牌各走自己的流
--   §13  N 恒定，剔除靠 UNAVAILABLE 占位；首次重抽的 key 是 _resample2
--   §14  used_jokers 在建卡那一刻写入 -> 后面的格子池子更空
--
-- 只预测**卡牌身份**（类型/稀有度/key），不预测版本和贴纸。
-- 因为流按 key 独立（§5.2 ③），跳过 edisho / etperpoll 不会让其他流错位。
--------------------------------------------------

MJS = MJS or {}

local floor, fmt, abs = math.floor, string.format, math.abs

--------------------------------------------------
-- 影子 RNG
--------------------------------------------------

-- §5.1 的推进公式。自己实现而不调 pseudoseed：
-- 后者在暂停时返回 math.random()（§5.2 ①），且会写真实状态。
local function advance(s)
    return abs(tonumber(fmt("%.13f", (2.134453429141 + s * 1.72431234) % 1)))
end

local function new_rng()
    local pr = G.GAME.pseudorandom or {}
    return {
        shadow = {},                    -- 本地迭代结果
        real   = pr,                    -- 只读真实状态
        seed   = pr.seed or "",
        hashed = pr.hashed_seed or 0,
    }
end

-- 取这条流的下一个值。首次用到时从真实状态拷一份；
-- 真实状态里也没有（本 ante 还没用过这条流）时按 pseudoseed 的初始化逻辑补：
--     G.GAME.pseudorandom[key] = pseudohash(key .. seed)
-- 注意初始化**不**过 %.13f 取整，取整只发生在推进步（misc_functions.lua:337）
local function nxt(rng, key)
    local v = rng.shadow[key]
    if v == nil then
        v = rng.real[key]
        if v == nil then v = pseudohash(key .. rng.seed) end
    end
    v = advance(v)
    rng.shadow[key] = v
    return (v + rng.hashed) / 2
end

-- u -> d。直接用 LuaJIT 自己的 math.random，所以逐位一致（§8 的架构结论）
local function d_of(u)
    math.randomseed(u)
    return math.random()
end

-- pseudorandom_element 的下标
local function pick_index(rng, key, n)
    local u = nxt(rng, key)
    local d = d_of(u)
    return floor(d * n) + 1, u, d
end

-- pseudorandom(seed) == randomseed(seed); math.random()  (misc_functions.lua)
local function poll_value(rng, key)
    local u = nxt(rng, key)
    return d_of(u), u
end

--------------------------------------------------
-- 类型选取：复刻 create_card_for_shop（UI_definitions.lua:822-864）
--------------------------------------------------
local function rate_of(GAME, ty)
    return GAME[tostring(ty):lower() .. "_rate"] or 0
end

-- 返回 rates 列表与 total_rate。
-- 注意 total_rate 的算法与 rates 列表的构成是**两段独立代码**：
--   total = joker_rate + playing_card_rate + Σ(obj_buffer 各自的 rate)
--   rates = Joker, Tarot, Planet, Base/Enhanced, Spectral, 然后追加 obj_buffer 里的其他类型
local function build_rates(GAME, obj_buffer, rng, has_illusion, trace)
    local total = (GAME.joker_rate or 0) + (GAME.playing_card_rate or 0)
    for _, v in ipairs(obj_buffer) do total = total + rate_of(GAME, v) end

    -- v_illusion 时这一格的类型是 Base 还是 Enhanced 要掷 illusion 流。
    -- 关键：这是**表构造器里的表达式**，急切求值 ->
    -- 只要持有 v_illusion，每个格子无论最终什么类型都会推进 illusion 一次。
    local pc_type = "Base"
    if has_illusion then
        local d, u = poll_value(rng, "illusion")
        if d > 0.6 then pc_type = "Enhanced" end
        trace[#trace + 1] = { step = "illusion", key = "illusion", u = u, d = d, result = pc_type }
    end

    local rates = {
        { type = "Joker",    val = GAME.joker_rate or 0 },
        { type = "Tarot",    val = GAME.tarot_rate or 0 },
        { type = "Planet",   val = GAME.planet_rate or 0 },
        { type = pc_type,    val = GAME.playing_card_rate or 0 },
        { type = "Spectral", val = GAME.spectral_rate or 0 },
    }
    for _, v in ipairs(obj_buffer) do
        if not (v == "Tarot" or v == "Planet" or v == "Spectral") then
            rates[#rates + 1] = { type = v, val = rate_of(GAME, v) }
        end
    end
    return rates, total
end

--------------------------------------------------
-- 稀有度选取：复刻 SMODS.poll_rarity（smods/src/utils.lua）
--------------------------------------------------
local VANILLA_RARITY = { Common = 1, Uncommon = 2, Rare = 3, Legendary = 4 }

local function poll_rarity(rng, key, GAME, rarities)
    local d, u = poll_value(rng, key)

    -- 权重 × G.GAME.<rarity>_mod，然后归一化
    local w, total = {}, 0
    for i, r in ipairs(rarities) do
        local mod = GAME[tostring(r.key):lower() .. "_mod"] or 1
        w[i] = (r.weight or 0) * mod
        total = total + w[i]
    end
    if total <= 0 then return 1, u, d end

    local acc = 0
    for i, r in ipairs(rarities) do
        acc = acc + w[i] / total
        if d < acc then return VANILLA_RARITY[r.key] or r.key, u, d end
    end
    -- 浮点误差兜到最后一项
    local last = rarities[#rarities]
    return VANILLA_RARITY[last.key] or last.key, u, d
end

--------------------------------------------------
-- 版本抽取：复刻 SMODS 运行时覆盖的全局 poll_edition（overrides.lua:2227）
--
-- 注意 dump 里 common_events.lua:2354 那份阈值版 poll_edition 是**死代码**——
-- SMODS 在 src/overrides.lua 里用 Lua 重定义了全局，lovely dump 看不见这种替换。
--
-- 结构：
--   1 次 d(key) 掷值
--   get_current_pool("Edition") 取可用版本（无 RNG），原版版本**倒序插到队首**
--   分母 total = Σ原始weight + Σ/4×96   （保底"96% 无版本"）
--   分子换成各版本 get_weight()          （foil/holo ×edition_rate；
--                                         polychrome 吸收 negative 不缩放的份额）
--   从队首往下累加带宽，d 落进哪个带返回哪个
--
-- _guaranteed 时跳过保底通胀和 get_weight 替换；_no_neg 时抽中 negative 不返回、
-- 继续往下落（wheel_of_fortune / illusion 用）。商店 joker 两者都不传。
--------------------------------------------------
local function poll_edition_pred(rng, key, no_neg, guaranteed)
    local d, u = poll_value(rng, key)

    local raw = get_current_pool("Edition", nil, nil, key)
    local opts = {}
    for _, e in ipairs(raw) do
        if G.P_CENTERS[e] and G.P_CENTERS[e].vanilla then
            table.insert(opts, 1, e)      -- 原版倒序到队首
        else
            opts[#opts + 1] = e           -- UNAVAILABLE 也会落到这里，下一步再滤
        end
    end

    local avail, total = {}, 0
    for _, e in ipairs(opts) do
        local c = e ~= "UNAVAILABLE" and G.P_CENTERS[e]
        if c then
            avail[#avail + 1] = { name = e, weight = c.weight or 0 }
            total = total + (c.weight or 0)
        end
    end
    if total <= 0 then return nil, u, d end

    if not guaranteed then
        total = total + total / 4 * 96
        for _, v in ipairs(avail) do
            local c = G.P_CENTERS[v.name]
            if c.get_weight then v.weight = c:get_weight() end
        end
    end

    local wi = 0
    for _, v in ipairs(avail) do
        wi = wi + v.weight                -- 商店调用 _mod=1
        if d > 1 - wi / total then
            if not (v.name == "e_negative" and no_neg) then
                return v.name, u, d
            end
            -- no_neg 抽中 negative：不返回、继续往下落（原版行为）
        end
    end
    return nil, u, d
end

--------------------------------------------------
-- 从池子里选一张，含重抽循环（common_events.lua:2181 的形状）
--------------------------------------------------
local function pick_center(rng, pool, pool_key, trace, label)
    local n = #pool
    if n == 0 then return nil end

    local i, u, d = pick_index(rng, pool_key, n)
    local center = pool[i]
    trace[#trace + 1] = { step = label, key = pool_key, u = u, d = d, index = i, got = center }

    local it = 1
    while center == "UNAVAILABLE" do
        it = it + 1
        -- 第一次重抽是 _resample2，不是 _resample1（it 先自增）
        local k = pool_key .. "_resample" .. it
        local i2, u2, d2 = pick_index(rng, k, n)
        center = pool[i2]
        trace[#trace + 1] = { step = label .. "/resample", key = k, u = u2, d = d2, index = i2, got = center }
        if it > 40 then
            trace[#trace + 1] = { step = label .. "/resample", note = "超过 40 次重抽，放弃" }
            return nil
        end
    end
    return center
end

--------------------------------------------------
-- 主入口
--
-- t = dump_state 刚构建好的 payload（已含 pools / poll_config）
-- 返回下一次 reroll 每一格的预测
--------------------------------------------------
function MJS.predict(t)
    if not (G.GAME and t and t.pools) then return nil end
    local GAME = G.GAME

    local cfg      = t.poll_config or {}
    local rarities = cfg.joker_rarities
    local obj_buf  = cfg.obj_buffer or { "Tarot", "Planet", "Spectral" }
    if not rarities then return { error = "poll_config.joker_rarities 缺失，无法定稀有度顺序" } end

    local slots = t.shop and t.shop.joker_max or 2
    local ante  = GAME.round_resets and GAME.round_resets.ante
    if not ante then return nil end

    local has_illusion = (GAME.used_vouchers or {})["v_illusion"] and true or false

    -- 预测未来多少次 reroll。连续 reroll（不买牌）时 used_jokers 基线不变，
    -- 所以每轮池子从 t.pools 干净副本重置，§14 的 cull 只发生在单轮内部；
    -- 而流状态 rng 全程延续（这是 reroll 之间唯一变化的东西）。
    local N = (t.shop and t.shop.predict_rerolls) or 8

    -- 每轮从快照重建池子的可写副本
    local function fresh_pools()
        local jp, cp = {}, {}
        for r, p in pairs(t.pools.joker or {}) do
            local copy = {}
            for i, v in ipairs(p.pool) do copy[i] = v end
            jp[r] = { pool = copy, pool_key = p.pool_key }
        end
        for ty, p in pairs(t.pools.consumable or {}) do
            local copy = {}
            for i, v in ipairs(p.pool) do copy[i] = v end
            cp[ty] = { pool = copy, pool_key = p.pool_key }
        end
        return jp, cp
    end

    local function consume(store, k, center)
        local e = store[k]
        if not e or not center then return end
        for i, v in ipairs(e.pool) do
            if v == center then e.pool[i] = "UNAVAILABLE"; return end
        end
    end

    -- 预测一格。返回 entry。会推进 rng、就地 cull jp/cp。
    local function predict_slot(slot, rng, jp, cp)
        local trace = {}
        local rates, total = build_rates(GAME, obj_buf, rng, has_illusion, trace)

        local d, u = poll_value(rng, "cdt" .. ante)
        local polled = d * total
        trace[#trace + 1] = { step = "cdt", key = "cdt" .. ante, u = u, d = d,
                              polled_rate = polled, total_rate = total }

        -- 累加区间：check_rate < polled <= check_rate + val
        local ty, check = nil, 0
        for _, v in ipairs(rates) do
            if polled > check and polled <= check + v.val then ty = v.type; break end
            check = check + v.val
        end

        local entry = { slot = slot, set = ty, trace = trace }

        if not ty then
            entry.note = "无类型匹配（polled_rate 恰为 0，原版此时返回 nil）"

        elseif ty == "Joker" then
            local r, ru, rd = poll_rarity(rng, "rarity" .. ante .. "sho", GAME, rarities)
            trace[#trace + 1] = { step = "rarity", key = "rarity" .. ante .. "sho",
                                  u = ru, d = rd, rarity = r }
            entry.rarity = r

            local e = jp[tostring(r)]
            if e then
                local center = pick_center(rng, e.pool, e.pool_key, trace, "pool")
                entry.key = center
                consume(jp, tostring(r), center)

                -- 版本：create_card 只对 Joker 掷（common_events.lua:2477 的守卫，实测 §12）
                local edi_key = "edi" .. "sho" .. ante
                local ed, eu, edd = poll_edition_pred(rng, edi_key)
                entry.edition = ed   -- nil 时 JSON 里省略 == 无版本
                trace[#trace + 1] = { step = "edition", key = edi_key,
                                      u = eu, d = edd, edition = ed or "none" }
            else
                entry.note = "没有稀有度 " .. tostring(r) .. " 的池子快照"
            end

        elseif cp[ty] then
            local e = cp[ty]
            local center = pick_center(rng, e.pool, e.pool_key, trace, "pool")
            entry.key = center
            consume(cp, ty, center)

        else
            -- Base / Enhanced 出的是实体扑克牌，走 frontsho<A>，
            -- 牌面池是 G.P_CARDS 而不是 center 池，本版不预测具体牌面
            entry.note = "类型 " .. tostring(ty) .. " 的具体牌面暂不预测"

            -- v_illusion 的第二掷（>0.8 才给版本）和第三掷（'illusion' 流上的版本抽取，
            -- no_neg + guaranteed）。UI_definitions.lua:859。
            if has_illusion then
                local d2, u2 = poll_value(rng, "illusion")
                trace[#trace + 1] = { step = "illusion_edition_gate", key = "illusion",
                                      u = u2, d = d2, pass = d2 > 0.8 }
                if d2 > 0.8 then
                    local ed = poll_edition_pred(rng, "illusion", true, true)
                    entry.edition = ed
                end
            end
        end

        return entry
    end

    local rng = new_rng()
    local out = { ante = ante, slots = slots, count = N, rerolls = {} }

    for ri = 1, N do
        local jp, cp = fresh_pools()      -- 每轮池子基线重置
        local cards = {}
        for slot = 1, slots do
            cards[#cards + 1] = predict_slot(slot, rng, jp, cp)
        end
        out.rerolls[ri] = { index = ri, cards = cards }
    end

    -- 归还全局 PRNG：d_of 里的 math.randomseed 会把全局状态留在确定值上，
    -- 而 pseudoseed('seed') 和暂停时的 pseudoseed 会读裸 math.random()
    -- （§10 探针踩过同一个坑）
    math.randomseed(os.time() + floor((os.clock() % 1) * 1e6))

    return out
end

sendDebugMessage("[MJS-PRED] predict.lua 已加载")
