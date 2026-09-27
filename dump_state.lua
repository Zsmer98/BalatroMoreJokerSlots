--------------------------------------------------
-- 运行时状态导出（NOTES-shop-rng.md §8 架构第 1 步：先跑通管道，不做预测）
--
-- 输出 MoreJokerSlots/state.json，内容是复刻商店队列所需的全部输入：
--   · G.GAME.pseudorandom 全量流状态（全精度）
--   · 当前商店内容
--   · 影响 get_current_pool 过滤的所有状态（used_jokers / banned_keys / …）
--   · 影响消耗顺序的所有 modifier（见 NOTES §2 的 #5 / #6 差异）
--
-- 本文件不做任何预测，只如实快照。预测在管道通了之后再加。
--------------------------------------------------

-- 必须在加载期抓路径与配置：运行时 SMODS.current_mod 是 nil（在 tick 里访问会崩，踩过）
local MOD_PATH = SMODS.current_mod.path
local CFG      = SMODS.current_mod.config or {}

-- 数据文件故意不用 .json 扩展名：SMODS loader（src/preflight/loader.lua:300）用**未锚定**的
-- '%.json' 匹配 mod 目录下的文件，.json 和 .jsonl 都会被整个 NFS.read 进内存、当成 mod 清单
-- 解析 —— 每次启动游戏都读一遍（history.jsonl 曾涨到 17MB）。内容依然是 JSON。
local OUT      = MOD_PATH .. "state.dat"      -- 最新快照，覆盖写（网页用）
local HIST     = MOD_PATH .. "history.log"    -- 可选：商店内每次变化追加一行（对齐消耗顺序用）

-- config 也加载期抓死。改了要重启（这几项本就没做成运行时 slider）。
local PREDICT_REROLLS = tonumber(CFG.predict_rerolls) or 40
-- 两个诊断功能默认关闭：它们要验证的东西都已验完
-- （消耗模型 8/8；JS 移植 vs 游戏内 RNG 160/160，含类型/牌面/版本）。
local RECORD_HISTORY  = CFG.record_history == true
local MOD_PREDICT     = CFG.mod_predict == true
local HIST_MAX_BYTES  = 5 * 1024 * 1024   -- 即使打开历史，写到 5MB 也停，不会再无限增长

-- 一次性清理改名前的旧文件：它们还留在目录里的话，loader 每次启动仍会读（见上）。
-- 只删本 mod 自己生成过的这几个文件名。
for _, f in ipairs({ "state.json", "history.jsonl", "history.jsonl.bloated" }) do
    pcall(NFS.remove, MOD_PATH .. f)
end

local fmt, huge = string.format, math.huge

--------------------------------------------------
-- 消毒层
--------------------------------------------------

-- json.lua 的 encode_number 碰到 nan/inf 会直接 error（libs/json/json.lua:106），
-- 而本环境有已知的 nan 污染问题（主笔记 §9.1）。一个 nan 就会让整份 dump 抛异常，
-- 所以所有数字都过这一层。
local function num(v)
    if type(v) ~= "number" then return nil end
    if v ~= v then return "nan" end            -- nan 唯一不等于自身
    if v >= huge then return "inf" end
    if v <= -huge then return "-inf" end
    return v
end

-- json.lua 用 %.14g 编码数字，会截掉 RNG 状态的低位。
-- pseudoseed 每步都过 string.format("%.13f", …)，状态量化在 1e-13；
-- 但 hashed_seed 可能大于 1，那时 14 位有效数字就不够 13 位小数了。
-- 预测靠的就是这些位，所以统一转成 %.17g 字符串（double 往返无损）。
local function f17(v)
    if type(v) ~= "number" then return nil end
    if v ~= v then return "nan" end
    if v >= huge or v <= -huge then return tostring(v) end
    return fmt("%.17g", v)
end

-- json.lua 把空表编码成 [] 而不是 {}（next(val)==nil 就当数组，json.lua:68）。
-- 为了不让 JS 侧区分这两种，空 map 直接省略键：缺失 == 空。
local function map(t)
    if type(t) ~= "table" then return nil end
    local out, n = {}, 0
    for k, v in pairs(t) do
        if type(k) == "string" then
            out[k] = v
            n = n + 1
        end
    end
    return n > 0 and out or nil
end

-- 只收值为真的键，输出成排序过的字符串数组（比 map 好读，也稳定可 diff）
local function keyset(t)
    if type(t) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(t) do
        if v and type(k) == "string" then out[#out + 1] = k end
    end
    if #out == 0 then return nil end
    table.sort(out)
    return out
end

--------------------------------------------------
-- 卡牌快照
--------------------------------------------------

-- center 用哪个图集：复刻 card.lua:172 的选择逻辑。
-- Joker/消耗牌/Voucher 用 set 名做图集名，其余落到 'centers'（Enhancers.png）。
-- 显式 atlas 字段优先（SMODS 卡常用）。
local function atlas_of(ctr)
    return ctr.atlas
        or ((ctr.set == "Joker" or ctr.consumeable or ctr.set == "Voucher") and ctr.set)
        or "centers"
end

-- 图集坐标：{a=图集名, x, y}（格子下标）。网页据此做 CSS sprite。
-- 传奇小丑和全息影像是两层：底框（pos）+ 浮在上面的脸（soul_pos，同一张图集，card.lua:218），
-- 后者放进 s = {x, y}；只导出 pos 的话缩略图里只有底框花纹、没有脸。
local function sprite_of(ctr)
    if not ctr or not ctr.pos then return nil end
    local sp = { a = atlas_of(ctr), x = num(ctr.pos.x), y = num(ctr.pos.y) }
    local sp2 = ctr.soul_pos
    if type(sp2) == "table" and sp2.x and sp2.y then sp.s = { x = num(sp2.x), y = num(sp2.y) } end
    return sp
end

local function snap_card(c)
    if not c or not c.config or not c.config.center then return nil end
    local ctr = c.config.center
    local ab  = c.ability or {}
    local rarity = ctr.rarity
    if type(rarity) == "number" then rarity = num(rarity) end
    return {
        key        = ctr.key,
        name       = ab.name or ctr.name,
        set        = ctr.set,
        rarity     = rarity,                          -- 原版是数字，mod 可能是字符串
        edition    = c.edition and c.edition.key or nil,
        eternal    = ab.eternal and true or nil,
        perishable = ab.perishable and true or nil,
        rental     = ab.rental and true or nil,
        cost       = num(c.cost),
        sort_id    = num(c.sort_id),
        sprite     = sprite_of(ctr),                  -- 当前商店卡的图集坐标
    }
end

local function snap_area(area)
    if not area or not area.cards then return nil end
    local out = {}
    for _, c in ipairs(area.cards) do
        out[#out + 1] = snap_card(c)
    end
    return out
end

--------------------------------------------------
-- 当前持有的标签，按种类聚合成 { key, name, count }，数量多的在前。
-- 游戏里标签横排一行显示，多了会溢出屏幕，网页端用汇总代替。
--
-- G.GAME.tags 是连续数组：追加用 #+1（UI_definitions.lua:1440），
-- 移除用 table.remove（tag.lua:594），所以 ipairs 安全。
-- 名字用游戏自己的 localize（misc_functions.lua:1908），和游戏内显示一致、跟随语言设置。
-- 名字是静态的，按「语言+key」缓存，避免每个 tick 都去查本地化表。
--------------------------------------------------
local tag_names = {}
local function tag_name(k)
    local lang = (G.SETTINGS and G.SETTINGS.language) or ""
    local ck = lang .. "|" .. k
    local n = tag_names[ck]
    if n then return n end
    local ok, s = pcall(localize, { type = "name_text", set = "Tag", key = k })
    if not ok or type(s) ~= "string" or s == "" or s == "ERROR" then
        s = (G.P_TAGS and G.P_TAGS[k] and G.P_TAGS[k].name) or k
    end
    tag_names[ck] = s
    return s
end

local function snap_tags()
    local tags = G.GAME and G.GAME.tags
    if type(tags) ~= "table" then return nil end
    local count, order = {}, {}
    for _, tg in ipairs(tags) do
        local k = type(tg) == "table" and tg.key
        if k then
            if not count[k] then count[k] = 0; order[#order + 1] = k end
            count[k] = count[k] + 1
        end
    end
    if #order == 0 then return nil end   -- 缺失 == 没有标签
    local out = {}
    for i, k in ipairs(order) do
        out[i] = { key = k, name = tag_name(k), count = count[k] }
    end
    table.sort(out, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.key < b.key
    end)
    return out
end

--------------------------------------------------
-- 剔除后的真实卡池
--
-- 不复刻 get_current_pool 的 cull 逻辑，直接调游戏自己的 —— 这是 §8
-- 「预测跑在游戏内 Lua」那条结论用在池子上，零复刻成本、逐位一致。
--
-- 三个必须注意的点：
-- 1. 传显式 rarity 会走 `local rarity = _rarity or SMODS.poll_rarity(...)` 的
--    左分支，**不消耗任何 RNG**。cull 循环本身也不用 RNG。所以这个调用是纯读。
-- 2. rarity 必须传**字符串**。传数字会被当成 poll 的掷值：
--    `(_rarity > 0.95 and 3) or (_rarity > 0.7 and 2) or 1`
--    → get_current_pool('Joker', 4) 拿到的是稀有度 3，不是 4。（common_events.lua:2261）
-- 3. 返回的是 G.ARGS.TEMP_POOL **本体**，下次调用开头就 EMPTY() 掉，必须立刻拷走。
--------------------------------------------------
local RARITY_ARGS = {
    { name = "1", arg = "Common"   , legendary = nil  },
    { name = "2", arg = "Uncommon" , legendary = nil  },
    { name = "3", arg = "Rare"     , legendary = nil  },
    -- 传奇在原版是靠 _legendary=true 走的，池 key 因此不带 ante（'Joker4' 而非 'Joker4sho15'）
    { name = "4", arg = "Legendary", legendary = true },
}

-- create_card_for_shop 里可能出现的消耗牌类型（UI_definitions.lua:832 的 rates 表）
local CONSUMABLE_TYPES = { "Tarot", "Planet", "Spectral" }

local function grab_pool(...)
    local ok, pool, pkey = pcall(get_current_pool, ...)
    if not ok or type(pool) ~= "table" then return nil end
    local avail, copy = 0, {}
    for i, v in ipairs(pool) do
        copy[i] = v
        if v ~= "UNAVAILABLE" then avail = avail + 1 end
    end
    return {
        pool_key  = pkey,       -- 顺带核对 key 命名的理解对不对
        n         = #copy,      -- 这就是 pseudorandom_element 的 N
        available = avail,
        pool      = copy,       -- 含 UNAVAILABLE 占位，下标即抽取结果
    }
end

local function snap_pools()
    if type(get_current_pool) ~= "function" then return nil end
    local out, any = { joker = {}, consumable = {} }, false

    for _, R in ipairs(RARITY_ARGS) do
        local p = grab_pool("Joker", R.arg, R.legendary, "sho")
        if p then out.joker[R.name] = p; any = true end
    end

    -- 非 Joker 类型走 G.P_CENTER_POOLS[_type]，不带 rarity，同样不消耗 RNG
    for _, ty in ipairs(CONSUMABLE_TYPES) do
        local p = grab_pool(ty, nil, nil, "sho")
        if p then out.consumable[ty] = p; any = true end
    end

    if not next(out.joker) then out.joker = nil end
    if not next(out.consumable) then out.consumable = nil end
    return any and out or nil
end

-- 版本池与权重。网页端要自己算版本预测，但它没有 get_current_pool，
-- 所以把池子（含 UNAVAILABLE 占位，顺序即遍历顺序）和每个版本的权重一起抓出来。
-- gw 是 get_weight() 的结果（已应用 edition_rate）；w 是原始权重（guaranteed 时用）。
local function snap_editions()
    if type(get_current_pool) ~= "function" then return nil end
    local ok, pool = pcall(get_current_pool, "Edition", nil, nil, "edisho")
    if not ok or type(pool) ~= "table" then return nil end

    local list, weights, any = {}, {}, false
    for i, k in ipairs(pool) do
        list[i] = k
        if k ~= "UNAVAILABLE" and not weights[k] then
            local c = G.P_CENTERS[k]
            if c then
                local gw = c.weight
                if c.get_weight then
                    local okg, v = pcall(c.get_weight, c)
                    if okg then gw = v end
                end
                weights[k] = { w = num(c.weight), gw = num(gw), vanilla = c.vanilla and true or false }
                any = true
            end
        end
    end
    if not any then return nil end
    return { pool = list, weights = weights }
end

-- 类型选取与稀有度选取都依赖**列表顺序**，这个绝不能从源码猜，运行时抓下来。
--   obj_buffer : create_card_for_shop 用它算 total_rate 并往 rates 表追加类型
--   rarities   : SMODS.poll_rarity 按 ipairs 顺序累加权重比较
local function snap_poll_config()
    local out = {}

    local ob = SMODS.ConsumableType and SMODS.ConsumableType.obj_buffer
    if type(ob) == "table" then
        local t = {}
        for i, v in ipairs(ob) do t[i] = v end
        out.obj_buffer = t
    end

    local ot = SMODS.ObjectTypes and SMODS.ObjectTypes.Joker
    if ot and type(ot.rarities) == "table" then
        local t = {}
        for i, v in ipairs(ot.rarities) do
            t[i] = { key = tostring(v.key), weight = num(v.weight) }
        end
        out.joker_rarities = t
    end

    return next(out) and out or nil
end

-- key -> 图集坐标 字典，只收 pools 里出现的 key（所有可能被预测到的卡）。
local function build_sprites(pools)
    if not pools then return nil end
    local sp, any = {}, false
    local function add(grp)
        for _, p in pairs(grp) do
            for _, k in ipairs(p.pool or {}) do
                if k ~= "UNAVAILABLE" and not sp[k] then
                    local c = G.P_CENTERS[k]
                    local s = c and sprite_of(c)
                    if s then sp[k] = s; any = true end
                end
            end
        end
    end
    add(pools.joker or {}); add(pools.consumable or {})
    return any and sp or nil
end

-- 把游戏已加载到内存的图集 Image 导出成 PNG（canvas 方案）。
-- 用内存 Image 而非文件路径 —— 图集对象没存 path，且这样自动兼容 SMODS 注册的图集
-- （Planet/Spectral 就是 SMODS 注册的，vanilla 图集列表里没有）。
-- 只导出 pools 用到的图集，各一次；返回各图集的像素尺寸元信息供网页缩放。
local atlas_exported = false
local atlas_meta     = nil

local function export_atlases(pools)
    if atlas_exported then return atlas_meta end
    if not (pools and love and love.graphics and G.ASSET_ATLAS) then return nil end

    local names = {}
    local function collect(grp)
        for _, p in pairs(grp) do
            for _, k in ipairs(p.pool or {}) do
                if k ~= "UNAVAILABLE" then
                    local c = G.P_CENTERS[k]
                    if c then names[atlas_of(c)] = true end
                end
            end
        end
    end
    collect(pools.joker or {}); collect(pools.consumable or {})

    local dir = MOD_PATH .. "web/atlas/"
    pcall(function() NFS.createDirectory(dir) end)

    -- update 阶段没有活跃的渲染 transform（那是 draw 阶段的事），所以不必 push/pop，
    -- 只需保存/恢复 canvas。origin() 改动的 transform 会被下一帧 draw 重设。
    local prev = love.graphics.getCanvas()
    local meta, done = {}, {}
    for name in pairs(names) do
        local atlas = G.ASSET_ATLAS[name]
        if atlas and atlas.image then
            local ok, err = pcall(function()
                local pw, ph = atlas.image:getPixelDimensions()
                local canvas = love.graphics.newCanvas(pw, ph)
                love.graphics.setCanvas(canvas)
                love.graphics.origin()
                love.graphics.clear(0, 0, 0, 0)
                love.graphics.setColor(1, 1, 1, 1)
                love.graphics.draw(atlas.image, 0, 0)
                local idata = canvas:newImageData()
                love.graphics.setCanvas(prev)          -- 每次立即恢复
                local png = idata:encode("png")
                NFS.write(dir .. name .. ".png", png:getString())
                -- px/py 是每格「逻辑」尺寸(71×95)；pw/ph 是实际像素(受 texture_scaling 放大)
                meta[name] = { pw = pw, ph = ph, px = atlas.px or 71, py = atlas.py or 95 }
                done[#done + 1] = name
            end)
            if not ok then
                love.graphics.setCanvas(prev)          -- 出错也恢复
                sendDebugMessage("[MJS-ATLAS] 导出 " .. name .. " 失败: " .. tostring(err))
            end
        end
    end
    love.graphics.setCanvas(prev)   -- 兜底

    atlas_meta     = next(meta) and meta or nil
    atlas_exported = true
    sendDebugMessage("[MJS-ATLAS] 导出: " .. (table.concat(done, ", ") == "" and "(无)" or table.concat(done, ", ")))
    return atlas_meta
end

-- key -> 显示名 字典，只收 pools 里出现的 key（= 所有可能被预测到的卡）。
-- 网页用它把 j_xxx / c_xxx 显示成人类可读的名字。
local function build_loc(pools)
    if not pools then return nil end
    local loc, any = {}, false
    local function add(key)
        if key and key ~= "UNAVAILABLE" and not loc[key] then
            local c = G.P_CENTERS[key]
            if c then loc[key] = c.name or key; any = true end
        end
    end
    for _, grp in pairs({ pools.joker or {}, pools.consumable or {} }) do
        for _, p in pairs(grp) do
            for _, k in ipairs(p.pool or {}) do add(k) end
        end
    end
    return any and loc or nil
end

--------------------------------------------------
-- 主体
--------------------------------------------------
local function build()
    local GAME = G.GAME
    if not GAME then return nil end

    local pr = GAME.pseudorandom or {}

    -- 全量流状态。不做白名单：漏一个 key 就是整条队列偏移（主笔记 §8 已知难点），
    -- 而这张表本来就小，全带上比挑着带安全。
    local streams = {}
    local has_stream = false
    for k, v in pairs(pr) do
        if type(k) == "string" and k ~= "seed" and k ~= "hashed_seed" then
            streams[k] = f17(v)
            has_stream = true
        end
    end
    if not has_stream then streams = nil end

    local pools = {}
    if G.P_JOKER_RARITY_POOLS then
        for r = 1, 4 do
            local p = G.P_JOKER_RARITY_POOLS[r]
            pools[#pools + 1] = p and #p or 0
        end
    end

    local mods = GAME.modifiers or {}
    local showman = false
    if SMODS.find_card and next(SMODS.find_card("j_ring_master")) then showman = true end

    return {
        meta = {
            -- 2: owned.tags。网页据此区分「没有标签」和「旧版 dump 还没有这个字段」
            schema        = 2,
            -- dumped_at 故意不在这里填：它每秒变一次，会把 tick() 里
            -- 「内容没变就不写盘」的比对彻底架空（踩过：96 条记录里 92 条是噪音）。
            -- 只在确认要写盘时才盖时间戳。
            game_version  = tostring(VERSION),
            smods_version = SMODS and SMODS.version and tostring(SMODS.version) or nil,
            mod_version   = "1.0.0",
        },

        run = {
            seed        = tostring(pr.seed or "?"),
            hashed_seed = f17(pr.hashed_seed),
            ante        = num(GAME.round_resets and GAME.round_resets.ante),
            round       = num(GAME.round),
            dollars     = num(GAME.dollars),
            state       = num(G.STATE),
            back        = GAME.selected_back and GAME.selected_back.name or nil,
        },

        -- 流状态：字符串形式的全精度 double，见 f17 的注释
        rng = { streams = streams },

        shop = {
            joker_max    = num(GAME.shop and GAME.shop.joker_max),
            reroll_cost  = num(GAME.current_round and GAME.current_round.reroll_cost),
            free_rerolls = num(GAME.current_round and GAME.current_round.free_rerolls),
            jokers       = snap_area(G.shop_jokers),
            vouchers     = snap_area(G.shop_vouchers),
            boosters     = snap_area(G.shop_booster),
            -- 预测队列深度（加载期从 config 抓，见顶部 PREDICT_REROLLS），predict 读这个字段
            predict_rerolls = PREDICT_REROLLS,
        },

        -- cdt 那一发的权重（UI_definitions.lua:828，NOTES §2 的 #1）
        rates = {
            joker        = num(GAME.joker_rate),
            tarot        = num(GAME.tarot_rate),
            planet       = num(GAME.planet_rate),
            spectral     = num(GAME.spectral_rate),
            playing_card = num(GAME.playing_card_rate),
            edition      = num(GAME.edition_rate),
        },

        -- 稀有度：主池大小 == get_current_pool 返回长度 == pseudorandom_element 的 N
        -- （剔除靠填 UNAVAILABLE 占位，长度不变，见 NOTES §13）
        rarity = {
            pool_sizes   = #pools > 0 and pools or nil,
            common_mod   = num(GAME.common_mod),
            uncommon_mod = num(GAME.uncommon_mod),
            rare_mod     = num(GAME.rare_mod),
        },

        -- pools 不在这里算：build() 每秒跑 4 次，而 snap_pools() 要遍历 150 个
        -- center 并逐个调 SMODS.add_to_pool。改由 tick() 在确认内容真变了之后补上。

        -- 决定 etperpoll / ssjr 是否消耗（NOTES §2 的 #5 与 #6 行为不同）
        modifiers = {
            all_eternal                = mods.all_eternal and true or false,
            enable_eternals_in_shop    = mods.enable_eternals_in_shop and true or false,
            enable_perishables_in_shop = mods.enable_perishables_in_shop and true or false,
            enable_rentals_in_shop     = mods.enable_rentals_in_shop and true or false,
        },

        -- get_current_pool 的过滤输入（NOTES §0③ / §3）
        pool_state = {
            used_jokers   = keyset(GAME.used_jokers),
            used_vouchers = keyset(GAME.used_vouchers),
            banned_keys   = keyset(GAME.banned_keys),
            pool_flags    = map(GAME.pool_flags),
            showman       = showman,   -- SMODS.showman 就是查场上有没有 j_ring_master
        },

        owned = {
            jokers      = snap_area(G.jokers),
            consumables = snap_area(G.consumeables),
            tags        = snap_tags(),   -- 标签变化（跳盲注拿到 / 触发消耗）也会触发写盘
        },

        flags = {
            object_weights = SMODS.optional_features
                             and SMODS.optional_features.object_weights and true or false,
        },
    }
end

--------------------------------------------------
-- 挂载：Game:update_shop 每帧都跑，所以靠内容变了才写去抖
--------------------------------------------------
local last_json     = nil
local last_at       = 0
local prev_streams  = nil
local last_shop_sig = nil
local last_prediction = nil
-- 池子/坐标/版本池等重活的缓存：只在商店里重算，其余状态复用（见 tick）
local cache = {}

-- 按消息内容去重，每种错误各记一次。
-- 不能全局只记一次：那样第一个错误会永久掩盖后续所有错误，
-- tick 可能一直在抛而完全无声（网页静默停更，踩过这个坑）。
local logged = {}
local function log_once(msg)
    if not logged[msg] then
        logged[msg] = true
        sendDebugMessage("[MJS-DUMP] " .. msg)
    end
end

-- 历史记录：只记「这一次变化里，哪些流动了、从什么值变到什么值」。
-- 有了 from/to 就能离线反推每条流走了几步 —— 从 from 迭代 pseudoseed 的推进公式，
-- 数几步撞上 to。这是验证消耗顺序（NOTES §2）唯一不靠读源码的办法。
local function history_record(t)
    local cur = t.rng.streams or {}

    -- 带上 set：c_mercury 是 Planet、c_world 是 Tarot，都是 c_ 前缀，
    -- 光看 key 分不出类型，而消耗顺序校验正需要按类型计数
    local shop = {}
    for _, c in ipairs(t.shop.jokers or {}) do
        shop[#shop + 1] = { k = c.key, s = c.set, r = c.rarity, e = c.edition }
    end

    local rec = {
        t     = t.meta.dumped_at,
        ante  = t.run.ante,
        money = t.run.dollars,
        rr    = t.shop.reroll_cost,
        shop  = shop,
    }

    if not prev_streams then
        rec.baseline = true   -- 第一帧没有可比对的前值
    else
        local ch, n = {}, 0
        for k, v in pairs(cur) do
            local p = prev_streams[k]
            if p ~= v then
                -- 用 {from=,to=} 而不是 {p, v}：新出现的 key 前值是 nil，
                -- 数组形式会变成稀疏表，JSON.encode 直接报 sparse array
                ch[k] = { from = p or "NEW", to = v }
                n = n + 1
            end
        end
        if n > 0 then rec.changed = ch end
    end

    prev_streams = cur

    -- 带上**上一帧对"下次 reroll"的预测**。这条记录里的 shop 就是实际结果，
    -- 两者放在同一行 -> 验证完全自动化，不需要人工对照。
    -- 只存 set/rarity/key，完整 trace 留在 state.json 里（否则历史会膨胀）。
    -- 对账用「下一次 reroll」的预测 = rerolls[1]（多 reroll 结构的第一轮）
    local pnext = last_prediction and last_prediction.rerolls and last_prediction.rerolls[1]
    if pnext and pnext.cards then
        local slim = {}
        for _, c in ipairs(pnext.cards) do
            slim[#slim + 1] = { slot = c.slot, set = c.set, rarity = c.rarity,
                                key = c.key, e = c.edition }
        end
        rec.prev_pred = slim
    end
    last_prediction = t.prediction

    -- 护栏：流没动、商店也没变的记录一点信息都没有，不写。
    -- 踩过：dumped_at 那个 bug 让 78661 条记录里 78653 条是这种空记录（8.4MB）。
    -- 上游去抖已经修好了，这里是第二道防线 —— 空记录本身就不该进历史。
    local sig = table.concat((function()
        local t2 = {}
        for _, c in ipairs(shop) do t2[#t2 + 1] = c.k end
        return t2
    end)(), ",")
    if not rec.changed and not rec.baseline and sig == last_shop_sig then return end
    last_shop_sig = sig

    -- 大小上限：历史曾无限增长到 17MB（全状态 hook 后每秒一行）。到上限就停写。
    local info = NFS.getInfo(HIST)
    if info and info.size and info.size >= HIST_MAX_BYTES then
        log_once("history.log 已达 " .. HIST_MAX_BYTES .. " 字节上限，停止记录")
        return
    end

    local ok, line = pcall(JSON.encode, rec)
    if not ok then
        log_once("history JSON.encode 失败: " .. tostring(line))
        return
    end
    local wrote, werr = NFS.append(HIST, line .. "\n")
    if not wrote then log_once("NFS.append 失败: " .. tostring(werr)) end
end

-- 廉价指纹（修复 #4）：只做数字累加 + 一次格式化，不把快照整份字符串化。
-- 过去每 0.25s 都要 build 整份快照、再整份 JSON.encode（ante 26 时约 67KB），
-- 只为和上一次比较 —— 绝大多数 tick 内容根本没变，全是白做，而且流状态
-- 每过一个 ante 多约 45 条（旧 ante 的流永不删除），越打越重。
-- 现在先比指纹，变了才走完整路径。另外每 SAFETY_SEC 秒兜底完整比较一次，
-- 防止某种没进指纹的变化被漏掉（兜底时内容没变照样不写盘）。
local SAFETY_SEC = 5
local last_fp, last_full = nil, -math.huge
local was_in_shop = false

local function area_n(a) return (a and a.cards) and #a.cards or -1 end

local function fingerprint()
    local GAME = G.GAME
    -- 流状态：数量 + 值之和 + 平方和。任何一条流推进都会改变它们（流的跳变都很大，
    -- 两处变化恰好抵消的概率可以忽略）；新出现的流改变数量。
    local n, s1, s2 = 0, 0, 0
    for _, v in pairs(GAME.pseudorandom or {}) do
        if type(v) == "number" then n = n + 1; s1 = s1 + v; s2 = s2 + v * v end
    end
    local used = 0
    for _ in pairs(GAME.used_jokers or {}) do used = used + 1 end   -- 影响卡池剔除
    local rr = GAME.round_resets or {}
    local rates = (GAME.joker_rate or 0) + (GAME.tarot_rate or 0) + (GAME.planet_rate or 0)
                + (GAME.spectral_rate or 0) + (GAME.playing_card_rate or 0) + (GAME.edition_rate or 0)
    return fmt("%d|%.17g|%.17g|%s|%s|%s|%s|%d|%d|%d|%d|%d|%d|%d|%.17g",
        n, s1, s2,
        tostring(G.STATE), tostring(GAME.dollars), tostring(rr.ante), tostring(GAME.round),
        area_n(G.jokers), area_n(G.consumeables),
        area_n(G.shop_jokers), area_n(G.shop_vouchers), area_n(G.shop_booster),
        #(GAME.tags or {}), used, rates)
end

--------------------------------------------------
-- 小丑目录：全部小丑的 key / 英文名 / 游戏内本地化名 / 稀有度 / 图集坐标 / 是否解锁。
-- 网页「高亮关注」用它做搜索（中英文都能搜）和显示缩略图。
-- 覆盖**全部**小丑，包括当前被剔除出池子的（比如已拥有的），这样也能提前关注。
-- 目录是静态数据：单独写一个文件，每个会话（每种语言）只写一次。
-- 塞进 state.dat 的话，每次写快照都要多 encode ~15KB。
--------------------------------------------------
local CATALOG      = MOD_PATH .. "catalog.dat"
local catalog_lang = nil

local function write_catalog()
    local lang = (G.SETTINGS and G.SETTINGS.language) or ""
    if catalog_lang == lang then return end
    local pool = G.P_CENTER_POOLS and G.P_CENTER_POOLS.Joker
    if type(pool) ~= "table" or #pool == 0 then return end

    local list = {}
    for _, c in ipairs(pool) do
        if c.key then
            local ok, lname = pcall(localize, { type = "name_text", set = "Joker", key = c.key })
            if not ok or type(lname) ~= "string" or lname == "" or lname == "ERROR" then lname = nil end
            local r = c.rarity
            if type(r) == "number" then r = num(r) end
            list[#list + 1] = {
                key = c.key, name = c.name, lname = lname, rarity = r,
                sprite = sprite_of(c), unlocked = (c.unlocked ~= false),
            }
        end
    end

    local ok, out = pcall(JSON.encode, { lang = lang, jokers = list })
    if not ok then log_once("catalog JSON.encode 失败: " .. tostring(out)); return end
    local wrote, werr = NFS.write(CATALOG, out)
    if wrote then catalog_lang = lang else log_once("catalog.dat 写入失败: " .. tostring(werr)) end
end

local function tick(now)
    -- 修复 #1：只在局内导出。主菜单里的 G.GAME 是个空的默认局，导出它会覆盖掉
    -- 真实快照（网页随之变空），回到局内时还会把所有流都当成「新出现」。
    -- G.STAGE 在 start_run 里被设为 RUN（game.lua:2057）。
    if not (G.STAGES and G.STAGE == G.STAGES.RUN and G.GAME) then return end

    -- 目录每会话只真正写一次（语言没变时这里只是一次比较）
    local okc, ce = pcall(write_catalog)
    if not okc then log_once("write_catalog 抛异常: " .. tostring(ce)) end

    local fp = fingerprint()
    if fp == last_fp and (now - last_full) < SAFETY_SEC then return end
    last_fp, last_full = fp, now

    local t = build()
    if not t then return end

    -- 不含时间戳的 encode 用来判断「内容到底变了没有」（兜底轮询时通常没变 → 不写盘）
    local ok, cmp = pcall(JSON.encode, t)
    if not ok then
        log_once("JSON.encode 失败: " .. tostring(cmp))
        return
    end
    if cmp == last_json then return end
    last_json = cmp

    -- 确认要写盘了，才盖时间戳、才去算剔除后的卡池，再 encode 一次真正写出去的内容
    t.meta.dumped_at = num(os.time())

    -- pools 故意不参与上面的变化检测：它是 used_jokers / banned_keys / pool_flags
    -- 的纯函数，那些都在 payload 里，所以池子变了必然伴随 payload 变化。
    -- 唯一漏网情形是牌组附魔或 hands.played 变化（enhancement_gate / Planet softlock），
    -- 那种会等到下一次真实变化才被带上，可以接受。
    -- 重活（遍历 150+ center 建池、坐标表、版本池）只在商店里做。
    -- 打牌阶段这些不会用到，但流状态必须照常 dump —— 否则用掉消耗牌
    -- （比如光环推进 aura 流）时网页看到的还是旧快照。
    -- 非商店时复用上次的缓存，保证 payload 结构完整、网页端预测不退化。
    local in_shop = (G.STATE == (G.STATES and G.STATES.SHOP))
    if in_shop or not cache.pools then
        local okp, pools = pcall(snap_pools)
        if okp then cache.pools = pools else log_once("snap_pools 抛异常: " .. tostring(pools)) end

        local okc, pcfg = pcall(snap_poll_config)
        if okc then cache.poll_config = pcfg else log_once("snap_poll_config 抛异常: " .. tostring(pcfg)) end

        local okl, loc = pcall(build_loc, cache.pools)
        if okl then cache.loc = loc else log_once("build_loc 抛异常: " .. tostring(loc)) end

        local oke, eds = pcall(snap_editions)
        if oke then cache.editions = eds else log_once("snap_editions 抛异常: " .. tostring(eds)) end

        local oks, sprites = pcall(build_sprites, cache.pools)
        if oks then cache.sprites = sprites else log_once("build_sprites 抛异常: " .. tostring(sprites)) end
    end
    t.pools       = cache.pools
    t.poll_config = cache.poll_config
    t.loc         = cache.loc
    t.editions    = cache.editions
    t.sprites     = cache.sprites
    t.meta.pools_fresh = in_shop and true or false

    -- 图集图片不在这里导出：直接从 Balatro.exe 提取了原版 2x 图集到 web/atlas/
    -- （见 NOTES §22），版本绝对匹配、不用重启、不碰 update 阶段的渲染状态。
    -- export_atlases（canvas 方案）保留但不调用，仅当 SMODS 注册的图集与原版坐标
    -- 对不上时才启用。

    -- mod 端预测（修复 #6）：默认关闭。网页端 tools/predict.js 已经自己算，且已对这份
    -- mod 端结果验证过 160/160（类型/牌面/版本）。保留它只为日后回归验证：
    -- config.lua 里打开 mod_predict，就能再拿游戏内真实 RNG 的结果对照网页端。
    if MOD_PREDICT and in_shop and MJS and MJS.predict then
        local t0 = os.clock()
        local okpr, pred = pcall(MJS.predict, t)
        local ms = (os.clock() - t0) * 1000
        if okpr then
            -- 剥掉 trace：多页队列里 trace 会把 state.json 撑大好几倍，网页也用不上。
            -- （trace 只在单页调试时看，走 history.jsonl 的对账，不依赖 state.json）
            if pred and pred.rerolls then
                for _, rr in ipairs(pred.rerolls) do
                    for _, c in ipairs(rr.cards) do c.trace = nil end
                end
            end
            t.prediction = pred
            t.meta.predict_ms    = num(ms)              -- 量化性能，网页 footer 显示
            t.meta.predict_count = pred and pred.count or nil
        else
            log_once("MJS.predict 抛异常: " .. tostring(pred))
        end
    end

    local ok2, out = pcall(JSON.encode, t)
    if not ok2 then
        log_once("JSON.encode(带时间戳) 失败: " .. tostring(out))
        return
    end

    local wrote, werr = NFS.write(OUT, out)
    if not wrote then
        log_once("NFS.write 失败: " .. tostring(werr))
    end

    -- 修复 #2：历史默认关闭；打开时也只在商店里记 —— 它只用于验证 reroll 的消耗顺序。
    -- 每次进店重置对比基线：否则第一条会把整个回合里推进过的流全记成「变化」。
    if RECORD_HISTORY and in_shop then
        if not was_in_shop then prev_streams = nil end
        history_record(t)
    end
    was_in_shop = in_shop
end

-- 挂主循环而不是 Game:update_shop —— 后者只在商店界面跑，
-- 导致打牌阶段用掉消耗牌（比如光环推进 aura 流）时快照不更新，网页看到的是旧数据。
local ref_update = Game.update
function Game:update(dt)
    local r = ref_update(self, dt)

    -- 节流：0.25s 看一次指纹；指纹没变的 tick 只花一次流状态累加
    local now = love.timer.getTime()
    if now - last_at >= 0.25 then
        last_at = now
        -- dump 出岔子绝不能影响游戏主循环
        local ok, e = pcall(tick, now)
        if not ok then log_once("tick 抛异常: " .. tostring(e)) end
    end

    return r
end

sendDebugMessage("[MJS-DUMP] 已挂载 Game:update（仅局内） -> " .. OUT
    .. " | history=" .. tostring(RECORD_HISTORY) .. " mod_predict=" .. tostring(MOD_PREDICT))
