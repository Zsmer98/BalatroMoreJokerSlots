# More Joker Slots

**English** | [简体中文](README.zh-CN.md)

A Steamodded mod for Balatro with two parts:

1. **Starting bonus** (`main.lua`): every deck starts with extra Joker slots and a number of The Soul cards.
   Each Soul card also adds one consumable slot, so they all fit. Both amounts can be changed in the mod's in-game settings.
2. **Shop prediction panel** (`dump_state.lua` + `web/`):
   - During a run, the mod exports the game state to `state.dat`.
   - A local web page reproduces LuaJIT's random number generator bit for bit and predicts the next N shop rerolls: card type, rarity, which exact Joker, and edition.
   - More features:
     - Aura forecast: which edition the next Aura gives, and how many until Polychrome
     - A summary of the tags you own
     - Watchlist: search Jokers by English or Chinese name, pick several, and they get an animated rainbow border in the queue
     - Negative coverage: marks which upcoming shop Jokers your Negative Tags (including Double Tag copies) will turn Negative
     - Skip tag forecast: from the seed, the skip tags of every Small and Big Blind for antes 1–39, listing where the remaining Negative Tags are
     - Booster pack preview: what each pack in the shop will contain
       - All five pack kinds are supported, taking into account held cards, Showman, Telescope and Omen Globe
       - Standard packs show rank, suit, enhancement, edition and seal; if a pack contains The Soul, the panel shows which Legendary Joker it would create
       - After you open a pack, the panel checks it card by card against the prediction made before opening

## Languages

- **Web panel**: switch any time with the "中文 / EN" buttons in the top-right corner; your choice is remembered.
  - Until you pick one, the panel follows the game's language.
  - Card, tag and pack names use the game's own official English and Chinese names.
- **In game**: the mod's settings screen and its name and description in the Mods menu follow the game's language setting.
  - Translations are in `localization/en-us.lua` and `localization/zh_CN.lua`.
  - Other languages show English.

## Requirements

- Tested on Windows with Balatro 1.0.1o-FULL, Steamodded 1.0.0~BETA-1814a and Lovely 0.9.0
- The web panel needs [Node.js](https://nodejs.org/); there are no third-party dependencies

## Installation

Put this repository at `%APPDATA%\Balatro\Mods\MoreJokerSlots`. Either:

- clone it directly into that folder, or
- clone it somewhere else and point a directory junction at it (cmd):

```bat
mklink /J "%APPDATA%\Balatro\Mods\MoreJokerSlots" "C:\path\to\BalatroMoreJokerSlots"
```

## Card art (one-time setup)

The panel uses the game's original sprite sheets. They are copyrighted by the game's developer and publisher, so they are not in this repository; extract them from your own `Balatro.exe`.
Run these two commands in the repository folder (this uses the `tar` that ships with Windows; adjust the exe path if Steam is installed elsewhere):

```bat
mkdir web\atlas
tar -xf "C:\Program Files (x86)\Steam\steamapps\common\Balatro\Balatro.exe" -C web\atlas --strip-components 3 resources/textures/2x/Jokers.png resources/textures/2x/Tarots.png resources/textures/2x/Enhancers.png
```

## Usage

1. Start the game and enter a run (the mod only exports state during a run).
2. In the repository folder, run `node tools/serve.js`, then open <http://localhost:8666/> in a browser.
3. The page reads `state.dat` every second, so it refreshes on its own after you reroll, buy or sell cards, or use an Aura.

Predictions assume you keep rerolling from the current state. After anything that changes the pools or the state (buying a card, using a consumable, and so on), the page recomputes from the new state.

## Configuration (`config.lua`)

| Key | Default | Description |
|---|---|---|
| `extra_slots` | 4 | Extra Joker slots (adjustable in the in-game settings, 0–10) |
| `soul_count` | 35 | Number of Soul cards given at the start (adjustable in the in-game settings, 0–35) |
| `predict_rerolls` | 40 | Depth of the mod-side prediction. Only used when `mod_predict` is on; the web panel has its own depth selector |
| `record_history` | false | Diagnostics: in the shop, log how the random streams change on every reroll to `history.log` (capped at 5 MB) |
| `mod_predict` | false | Diagnostics: also compute the queue in game and write it to `state.dat`, to compare against the web panel |

The values in `config.lua` are only **defaults**. Steamodded saves your settings to `%APPDATA%\Balatro\config\MoreJokerSlots.jkr` and uses that file from then on (`SMODS.load_mod_config` in `smods/src/ui.lua`).
To change a diagnostic switch, edit that `.jkr` file (or delete it to go back to the `config.lua` defaults), then restart the game.

## Files

| File | Purpose |
|---|---|
| `main.lua` | Entry point: the starting bonus, and loads the two files below |
| `dump_state.lua` | Exports the game state at runtime (`state.dat`, `catalog.dat`) |
| `predict.lua` | Mod-side prediction (Lua version, off by default) |
| `localization/` | English and Chinese text for the in-game parts (mod settings, Mods menu description) |
| `tools/luajit_rng.js` | Bit-exact reimplementation of LuaJIT 2.0.5 `math.random` (self-test: `node tools/luajit_rng.js`) |
| `tools/predict.js` | Web-side prediction for the shop queue and booster packs; a JS port and extension of `predict.lua` |
| `tools/serve.js` | Zero-dependency local web server |
| `tools/aura.js` | Command-line tool: reads the save file and prints upcoming Aura editions (`node tools/aura.js`) |
| `tools/steps.js` | Diagnostic tool: analyzes `history.log` |
| `probe_rng.lua` | RNG probe used for regression checks; not loaded by default |
| `web/index.html` | The prediction panel |

## Notes

- Runtime data files deliberately use the `.dat` and `.log` extensions.
  Steamodded's loader reads and parses **any file whose name contains `.json`** in a mod folder as a mod manifest:
  `loader.lua` matches `'%.json'` without anchoring it to the end of the name.
  So don't put other `.json` files in this folder, such as `.vscode/settings.json`.
- This is an unofficial mod, not affiliated with the game's developer or publisher. Card art and other game assets belong to their respective owners.
