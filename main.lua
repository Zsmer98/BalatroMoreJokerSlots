sendDebugMessage("[MJS] main.lua loaded")

local mod = SMODS.current_mod

local function round(v, d)
    return math.floor((tonumber(v) or d) + 0.5)
end

--------------------------------------------------
-- 配置界面
--------------------------------------------------
-- 文字跟随游戏语言：localization/en-us.lua、zh_CN.lua（SMODS 自动加载，其他语言回落到英文）
local function L(key, fallback)
    local ok, s = pcall(localize, key)
    if ok and type(s) == "string" and s ~= "" and s ~= "ERROR" then return s end
    return fallback
end

mod.config_tab = function()
    -- create_slider 会立刻 string.format 这个值，nil 会直接崩
    mod.config.extra_slots = tonumber(mod.config.extra_slots) or 4
    mod.config.soul_count  = tonumber(mod.config.soul_count)  or 5

    return {
        n = G.UIT.ROOT,
        config = {
            r = 0.1, minw = 8, minh = 4, align = "cm",
            padding = 0.2, colour = G.C.BLACK,
        },
        nodes = {
            create_slider({
                label = L("mjs_extra_slots", "Extra Joker Slots"),
                label_scale = 0.5, text_scale = 0.5,
                min = 0, max = 10, decimal_places = 0,
                ref_table = mod.config, ref_value = "extra_slots",
                w = 4, h = 0.4, colour = G.C.BLUE,
            }),
            create_slider({
                label = L("mjs_soul_count", "Starting Soul Cards"),
                label_scale = 0.5, text_scale = 0.5,
                min = 0, max = 35, decimal_places = 0,
                ref_table = mod.config, ref_value = "soul_count",
                w = 4, h = 0.4, colour = G.C.PURPLE,
            }),
        },
    }
end

--------------------------------------------------
-- 实际效果
--------------------------------------------------
local ref_apply_to_run = Back.apply_to_run

function Back:apply_to_run(...)
    local extra = round(mod.config.extra_slots, 0)
    local souls = round(mod.config.soul_count, 0)
    mod.config.extra_slots = extra
    mod.config.soul_count  = souls

    -- config 是 copy_table 出来的拷贝，center.config 是原型
    -- 每次都以原型为基准赋值，保证幂等
    local cfg  = self.effect and self.effect.config
    local orig = self.effect and self.effect.center and self.effect.center.config

    if cfg and orig then
        cfg.joker_slot      = (orig.joker_slot or 0) + extra
        cfg.consumable_slot = (orig.consumable_slot or 0) + souls

        local list = {}
        for _, v in ipairs(orig.consumables or {}) do list[#list + 1] = v end
        for _ = 1, souls do list[#list + 1] = 'c_soul' end
        cfg.consumables = list

        sendDebugMessage("[MJS] " .. tostring(self.name)
            .. " joker_slot=" .. cfg.joker_slot
            .. " consumables=" .. #list)
    end

    return ref_apply_to_run(self, ...)
end

--------------------------------------------------
-- 兼容修复：使用消耗牌被打断后，读档崩溃 / 操作被锁住
--
-- G.FUNCS.use_card 开头设 G.TAROT_INTERRUPT 和「使用」锁（button_callbacks.lua:2199、2209），
-- 要等效果事件都跑完，最后一个事件才清掉（:2311-2312）。如果中途回了主菜单（比如画面卡住），
-- 「继续」会先清空事件队列（:3024），那个收尾事件就没了，两个标记一直留着：
--   · SMODS 的 CardArea:handle_card_limit 看到 TAROT_INTERRUPT 就跳过 extra_slots_used 的初始化，
--     读档时新建消耗牌区域直接崩溃：utils.lua:3662 attempt to perform arithmetic on field 'extra_slots_used'
--   · 就算不崩，「使用」锁也一直锁着
-- 开局 / 读档时不可能有正在使用的消耗牌，所以在 start_run 前把残留的标记清掉。
--------------------------------------------------
local ref_start_run = Game.start_run
function Game:start_run(...)
    if G.TAROT_INTERRUPT ~= nil then
        sendDebugMessage("[MJS] start_run: 清掉残留的 G.TAROT_INTERRUPT = " .. tostring(G.TAROT_INTERRUPT))
        G.TAROT_INTERRUPT = nil
    end
    if G.CONTROLLER and G.CONTROLLER.locks and G.CONTROLLER.locks.use then
        G.CONTROLLER.locks.use = false
    end
    return ref_start_run(self, ...)
end

--------------------------------------------------
-- RNG 探针已完成（结论见 NOTES-shop-rng.md §8）
--
-- probe_rng.lua 保留在盘上作为回归工具：SMODS 升级后想重验，
-- 把下面这段的注释去掉，重启游戏，看 probe_result.txt。
--------------------------------------------------
-- do
--     local chunk, err = SMODS.load_file('probe_rng.lua')
--     if not chunk then
--         sendDebugMessage("[MJS-PROBE] !!! 加载 probe_rng.lua 失败: " .. tostring(err))
--     else
--         local ok, rerr = pcall(chunk)
--         if not ok then
--             sendDebugMessage("[MJS-PROBE] !!! 探针运行时报错: " .. tostring(rerr))
--         end
--     end
-- end

--------------------------------------------------
-- 运行时状态导出（管道第 1 步）
--------------------------------------------------
do
    local chunk, err = SMODS.load_file('dump_state.lua')
    if not chunk then
        sendDebugMessage("[MJS-DUMP] !!! 加载 dump_state.lua 失败: " .. tostring(err))
    else
        local ok, rerr = pcall(chunk)
        if not ok then
            sendDebugMessage("[MJS-DUMP] !!! dump_state.lua 初始化报错: " .. tostring(rerr))
        end
    end
end

--------------------------------------------------
-- 商店预测器。
-- 与 dump_state.lua 的加载先后无关：后者只在运行时（进商店 tick）才调 MJS.predict，
-- 那时两个文件都早已加载完毕。
--------------------------------------------------
do
    local chunk, err = SMODS.load_file('predict.lua')
    if not chunk then
        sendDebugMessage("[MJS-PRED] !!! 加载 predict.lua 失败: " .. tostring(err))
    else
        local ok, rerr = pcall(chunk)
        if not ok then
            sendDebugMessage("[MJS-PRED] !!! predict.lua 初始化报错: " .. tostring(rerr))
        end
    end
end

