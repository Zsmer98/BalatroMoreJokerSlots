# More Joker Slots

一个 Balatro 的 Steamodded mod，包含两部分：

1. **开局加成**（`main.lua`）：每副牌开局多给小丑牌槽位，并赠送若干张灵魂牌（The Soul）。
   赠送多少张灵魂牌，就同时加多少个消耗牌槽位。两项数量都能在游戏内的 mod 设置里调。
2. **商店预测面板**（`dump_state.lua` + `web/`）：
   - mod 在局内把运行状态导出到 `state.dat`。
   - 本地网页逐位复刻 LuaJIT 的随机数，预测接下来 N 次 reroll 的商店内容：卡牌类型、稀有度、具体是哪张小丑、版本。
   - 其他功能：
     - 光环（Aura）接下来会给什么版本，还差几张到多彩
     - 当前拥有的标签汇总
     - 高亮关注：按中文或英文名搜索小丑并多选，队列里用动态彩虹边框标出来
     - 负片覆盖：按手上的负片标签（含双倍标签的复制）标出后面哪些商店小丑会变成负片

## 环境

- 测试环境：Windows，Balatro 1.0.1o-FULL，Steamodded 1.0.0~BETA-1814a，Lovely 0.9.0
- 网页面板需要 [Node.js](https://nodejs.org/)，没有第三方依赖

## 安装

把本仓库放到 `%APPDATA%\Balatro\Mods\MoreJokerSlots`，有两种方式：

- 直接 clone 到那个位置；
- 或者 clone 到别处，再建一个目录联接指过去（cmd）：

```bat
mklink /J "%APPDATA%\Balatro\Mods\MoreJokerSlots" "C:\path\to\BalatroMoreJokerSlots"
```

## 卡图（首次使用前）

网页上的卡图用的是游戏原版图集。它的版权属于游戏方，所以没有放进仓库，需要从你自己的 `Balatro.exe` 里解出来。
在仓库根目录执行下面两条命令（用的是 Windows 自带的 `tar`；Steam 装在别的位置的话，改一下 exe 路径）：

```bat
mkdir web\atlas
tar -xf "C:\Program Files (x86)\Steam\steamapps\common\Balatro\Balatro.exe" -C web\atlas --strip-components 3 resources/textures/2x/Jokers.png resources/textures/2x/Tarots.png resources/textures/2x/Enhancers.png
```

## 使用

1. 启动游戏，进入一局（mod 只在局内导出状态）。
2. 在仓库目录运行 `node tools/serve.js`，然后用浏览器打开 <http://localhost:8666/>。
3. 页面每秒读取一次 `state.dat`。你在游戏里 reroll、买卖牌、用光环之后，页面都会自动刷新。

预测的前提是「从当前状态开始，一直 reroll」。买牌、用消耗牌等改变了卡池或状态之后，页面会按新状态重新计算。

## 配置（`config.lua`）

| 项 | 默认 | 说明 |
|---|---|---|
| `extra_slots` | 4 | 额外的小丑牌槽位（游戏内设置可调，0–10） |
| `soul_count` | 35 | 开局赠送的灵魂牌数量（游戏内设置可调，0–35） |
| `predict_rerolls` | 40 | mod 端预测的深度。只在打开 `mod_predict` 时用到；网页端的深度在页面上选 |
| `record_history` | false | 诊断用：在商店里把每次 reroll 的随机流变化写进 `history.log`（上限 5MB） |
| `mod_predict` | false | 诊断用：在游戏内也算一份队列写进 `state.dat`，用来和网页端的结果对照 |

`config.lua` 里的只是**默认值**。Steamodded 会把设置存到 `%APPDATA%\Balatro\config\MoreJokerSlots.jkr`，之后都以那个文件为准（`smods/src/ui.lua` 的 `SMODS.load_mod_config`）。
所以要改诊断开关，应该改那个 `.jkr` 文件（或者删掉它，恢复成 `config.lua` 的默认值），然后重启游戏。

## 文件

| 文件 | 作用 |
|---|---|
| `main.lua` | 入口：开局加成，并加载下面两个文件 |
| `dump_state.lua` | 运行时状态导出（`state.dat`、`catalog.dat`） |
| `predict.lua` | mod 端预测（Lua 版，默认不启用） |
| `tools/luajit_rng.js` | LuaJIT 2.0.5 `math.random` 的逐位复刻（自测：`node tools/luajit_rng.js`） |
| `tools/predict.js` | 网页端预测，是 `predict.lua` 的 JS 版 |
| `tools/serve.js` | 零依赖的本地服务器 |
| `tools/aura.js` | 命令行工具：直接读存档，算光环接下来给什么版本（`node tools/aura.js`） |
| `tools/steps.js` | 诊断工具：分析 `history.log` |
| `probe_rng.lua` | RNG 探针，做回归验证用，默认不加载 |
| `web/index.html` | 预测面板 |

## 注意

- 运行时生成的数据用的是 `.dat` / `.log` 扩展名，这是有意为之。
  Steamodded 的加载器会把 mod 文件夹里**文件名含 `.json`** 的文件都当成 mod 清单去读取和解析：
  `loader.lua` 里匹配的是 `'%.json'`，没有锚定到结尾。
  所以别往这个文件夹里放其他 `.json` 文件，比如 `.vscode/settings.json`。
- 这是非官方 mod，与游戏的开发方和发行方无关。卡图等游戏素材的版权归原作者所有。
