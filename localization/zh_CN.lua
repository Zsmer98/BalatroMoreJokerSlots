-- 简体中文。SMODS 先加载 en-us，再用当前游戏语言的文件覆盖（smods utils.lua:222）。
return {
    descriptions = {
        Mod = {
            MoreJokerSlots = {
                name = "更多小丑槽位",
                text = {
                    "每副牌开局多给{C:attention}小丑牌槽位{}，并赠送若干张{C:spectral}灵魂{}牌。",
                    "附带本地网页面板：预测商店刷新、补充包、",
                    "跳过标签和光环的结果。",
                },
            },
        },
    },
    misc = {
        dictionary = {
            mjs_extra_slots = "额外小丑牌槽位",
            mjs_soul_count  = "开局灵魂牌数量",
        },
    },
}
