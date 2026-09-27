-- English (also the fallback for every language without its own file).
-- SMODS loads en-us first, then the file for the current game language on top (smods utils.lua:222).
return {
    descriptions = {
        Mod = {
            MoreJokerSlots = {
                name = "More Joker Slots",
                text = {
                    "Extra {C:attention}Joker slots{} and starting {C:spectral}Soul{} cards for every deck.",
                    "Comes with a local web panel that predicts shop rerolls,",
                    "booster packs, skip tags and Aura results.",
                },
            },
        },
    },
    misc = {
        dictionary = {
            mjs_extra_slots = "Extra Joker Slots",
            mjs_soul_count  = "Starting Soul Cards",
        },
    },
}
