return {
    extra_slots = 4,
    soul_count  = 35,
    -- 预测算多少次 reroll 的队列（仅 mod 端预测用；网页端深度在网页上选）。
    predict_rerolls = 40,

    -- 以下两个是诊断功能，默认关闭 —— 它们要验证的东西都已验完。
    -- 注意：这个文件里的只是默认值。存过设置之后（比如在游戏内调过滑块），
    -- 以 %APPDATA%\Balatro\config\MoreJokerSlots.jkr 为准（smods ui.lua 的 SMODS.load_mod_config）。
    -- 要改就改那个文件（或删掉它恢复成这里的默认值），再重启游戏。

    -- 在商店里把每次 reroll 的流变化写进 history.log（配合 tools/steps.js 校验消耗顺序）。
    -- 上限 5MB，到了自动停写。
    record_history = false,

    -- 在游戏内也算一份商店队列写进 state.dat，用来和网页端结果逐格对照（回归验证用）。
    mod_predict = false,
}
