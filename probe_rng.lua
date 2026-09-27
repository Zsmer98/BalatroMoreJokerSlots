--------------------------------------------------
-- 一次性 RNG 探针
--
-- 要回答的问题：pseudorandom_element 最后一步是
--     math.randomseed(seed); local i = math.random(#keys)
-- 那么 seed → i 的真实映射是什么？
--
-- H1（主笔记 §5.3 的模型）：i == floor(u * N) + 1        u = 传入的 seed
-- H2（待验证的替代模型）：  i == floor(d * N) + 1        d = randomseed(u) 后的第一次 math.random()
--
-- H2 若成立，则每个 seed 只需算出一个 d，就能对任意 N 直接算下标，
-- 且游戏内 Lua 可以直接复用真实 math.random 做到逐位精确。
--
-- 副产物：顺带验证 NFS.write 这条文件写出路径（JSON 管道要用同一条）。
--
-- 验完删除：删本文件 + main.lua 末尾的探针段。
--------------------------------------------------

local L = {}
local function log(s)
    s = tostring(s)
    L[#L + 1] = s
    sendDebugMessage("[MJS-PROBE] " .. s)
end

local floor, fmt = math.floor, string.format
local function g17(x) return fmt("%.17g", x) end

log("================ RNG PROBE ================")

--------------------------------------------------
-- 0. 环境：math.random 到底是谁的实现
--------------------------------------------------
log("_VERSION          = " .. tostring(_VERSION))
log("jit.version       = " .. tostring(jit and jit.version))
log("math.random       = " .. tostring(math.random))
log("love.math.random  = " .. tostring(love and love.math and love.math.random))
log("是否同一个对象     = " .. tostring(love and love.math and (math.random == love.math.random)))

--------------------------------------------------
-- 1. 真实卡池大小（能取到就记下来，N 的实际取值范围）
--------------------------------------------------
if G and G.P_JOKER_RARITY_POOLS then
    for r = 1, 4 do
        local p = G.P_JOKER_RARITY_POOLS[r]
        log(fmt("P_JOKER_RARITY_POOLS[%d] 大小 = %s", r, p and #p or "nil"))
    end
else
    log("P_JOKER_RARITY_POOLS 此刻不存在（mod 加载期太早，属正常）")
end

--------------------------------------------------
-- 2. 核心对比
--------------------------------------------------
-- seed 取 pseudoseed 的真实值域 [0,1)，含边界与典型值
local seeds = {
    0.0,
    1e-12,
    0.1,
    0.123456789012345,
    1/3,
    0.5,
    0.6999999999,
    0.7,
    0.85,
    0.9999999999,
}
-- N 覆盖真实卡池规模（传奇 5 / 稀有 ~20 / 普通 ~61 / 罕见 ~64）与小值边界
local Ns = { 1, 2, 3, 5, 20, 61, 64, 150 }

local h1_ok, h2_ok, total = 0, 0, 0

log("-------------------------------------------")
log("列含义: N | math.random(N) | H1=floor(u*N)+1 | H2=floor(d*N)+1")

for _, u in ipairs(seeds) do
    -- d = 用 u 播种后的第一次浮点抽取
    math.randomseed(u)
    local d = math.random()

    -- 同一个 u 重复播种，d 必须可复现
    math.randomseed(u)
    local d2 = math.random()
    local d_stable = (d == d2)

    log("")
    log(fmt("u = %s   ->   d = %s   (d 可复现=%s)", g17(u), g17(d), tostring(d_stable)))

    local row = {}
    for _, N in ipairs(Ns) do
        math.randomseed(u)
        local r = math.random(N)

        local h1 = floor(u * N) + 1
        local h2 = floor(d * N) + 1

        total = total + 1
        if r == h1 then h1_ok = h1_ok + 1 end
        if r == h2 then h2_ok = h2_ok + 1 end

        row[#row + 1] = fmt("%d|%d|%d%s|%d%s",
            N, r,
            h1, (r == h1) and "*" or " ",
            h2, (r == h2) and "*" or " ")
    end
    log("  " .. table.concat(row, "   "))
end

log("")
log("-------------------------------------------")
log(fmt("H1  floor(u*N)+1  命中 %d/%d", h1_ok, total))
log(fmt("H2  floor(d*N)+1  命中 %d/%d", h2_ok, total))
log("-------------------------------------------")
if h2_ok == total and h1_ok < total then
    log("结论: H2 成立, H1 不成立。")
    log("      -> 每个 seed 先取一次 d, 再 floor(d*N)+1 即可预测任意 N。")
elseif h1_ok == total then
    log("结论: H1 成立（主笔记 §5.3 的模型正确）。")
else
    log("结论: 两个模型都不完全成立, 需要进一步查 LuaJIT 的 math_random 实现。")
end

--------------------------------------------------
-- 3. 归还全局 PRNG 状态
--
-- 必须做：pseudoseed 在 key=='seed' 和暂停时会返回裸 math.random()，
-- 若把全局状态留在确定值上, 随机种子开局可能变成可复现的。
--------------------------------------------------
math.randomseed(os.time() + floor((os.clock() % 1) * 1e6))
log("已用 os.time()+os.clock() 重新播种全局 PRNG")
log("================ PROBE END ================")

--------------------------------------------------
-- 4. 写文件（同时验证 JSON 管道要用的写出路径）
--------------------------------------------------
local ok, err = pcall(function()
    local path = SMODS.current_mod.path .. "probe_result.txt"
    local wrote, werr = NFS.write(path, table.concat(L, "\n") .. "\n")
    if wrote then
        sendDebugMessage("[MJS-PROBE] 结果已写入 " .. path)
    else
        sendDebugMessage("[MJS-PROBE] NFS.write 失败: " .. tostring(werr))
    end
end)
if not ok then
    sendDebugMessage("[MJS-PROBE] 写文件抛异常: " .. tostring(err))
end
