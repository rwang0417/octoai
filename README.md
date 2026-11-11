# OctoAI

Ask an AI about **your own** OctoWoW character. Type `/octoai`, press **Copy**, paste into any AI chat, ask your question.

For OctoWoW (Turtle WoW 1.18.1 content on the 1.12 client). The one-click Copy button needs ClassicAPI.dll; everything else works on a plain 1.12 client.

## Install

**Launcher:** if your launcher lists OctoAI, install it there.

**Manual:** download the repository as a zip, extract it into `Interface\AddOns\` and rename the extracted folder (for example `OctoAI-main` or `octoai`) to exactly `OctoAI`. You should end up with:

```
Interface\AddOns\OctoAI\OctoAI.toc
```

Restart the game completely (a new addon is not loaded by /reload) and make sure OctoAI is ticked in the AddOns list on the character screen.

## Use

```
/octoai               Summary: character, picked talents, gear (with stats), quest log, bag items
/octoai gear          character + equipped and bagged gear + bag items
/octoai quests        character + quest log with quest IDs, objectives, progress + bag items
/octoai talents       character + full talent trees with every talent's effect and your points
/octoai spells        character + weapon skills + every spell/ability with its tooltip + pet abilities
/octoai professions   character + profession levels + recipes with reagents + bag items
/octoai all           everything above + trainer offers you have not learned + reputation + buffs
```
Bag items include item IDs, and the bank when you have opened it.

The window has the same choices as tabs at the top (Summary, Gear, Quests, Talents, Spells, Professions, All). Talents, spells and recipes come straight from your game client, so Turtle/Octo changes are included. **Copy** puts the text on the clipboard (needs ClassicAPI.dll; otherwise it is greyed out, use **Select all** and Ctrl+C). Paste it into the AI chat and write your question after `My question:`.

Example questions:
- "Which items in my bags can I sell?"
- "Is the gear in my bags better than what I wear?"
- "Where do I go for the quests in my log, in what order?"
- "How should I spend my next talent points?"

The text starts with a short note telling the AI that this is OctoWoW, not retail or Classic, and to look things up on https://octowow.st/db/ by the IDs given. AIs still make mistakes about private server content, so double check anything important in game.

### Some data only appears after you open a window once
- Bank: open the bank.
- Profession recipes: open the profession window.
- Trainer offers and costs: open the trainer window.

## Item tooltip cache

Every item you hover in game (auction house, vendors, chat links, loot rolls, bags, quest rewards, trade window) is remembered with its full tooltip, account wide (newest 4000 items). An AI that can read your WoW folder can then answer "is this worth buying?" with the exact stats, without you typing them. Stored in `WTF\Account\<account>\SavedVariables\OctoAI.lua` on logout or /reload.

## Full snapshot

`/octo` writes a complete JSON snapshot (everything above plus spells, buffs, reputation, full talent trees and tooltips). It is also saved automatically when things change, out of combat.

- With VanillaHelpers.dll: `<WoW>\VanillaHelpersData\octo_<Name>.json`
- Otherwise: `WTF\Account\<account>\<realm>\<character>\SavedVariables\OctoAI.lua` (written on logout or /reload)

Other commands: `/octo auto on|off`, `/octo verbose`, `/octo status`.

## AI tools (optional, advanced)

`tools/` is not used by the game. It is for people whose AI assistant can read their WoW folder (for example the Claude desktop app with the WoW folder connected):

- `tools/octo_query.py`: command line lookup (Python 3.8+, standard library only) for quests, NPCs, items, zones and your snapshots, plus `seen <item>` for tooltips from the item cache. Run `python tools/octo_query.py -h`.
- `tools/skill/SKILL.md`: instructions for the AI on how to use the tool and which rules to follow. Add it as a skill (or paste it into a project's instructions).
- `tools/data/`: the quest database from [OctoQuestDatabase](https://github.com/FrancisEgan/OctoQuestDatabase) (MIT, attribution in `data/NOTICE.md` after download). It is not stored in this repository; download it once with:

  ```
  python tools/update_data.py           # latest version
  python tools/update_data.py --check   # compare installed and latest
  ```

  Run the same command again later to update. Character snapshot commands work without the database.

## Privacy

Nothing leaves your computer unless you paste it somewhere yourself. The addon has no network access. The text contains your character name, realm, location and gold.

---

## 中文说明

让 AI 根据你自己角色的真实数据回答 OctoWoW 的问题。

1. 安装：启动器里有就直接装；手动安装就把压缩包解压到 `Interface\AddOns\`，文件夹名改成 `OctoAI`（不是 `OctoAI-main` 或 `octoai`），然后**完全重启游戏**。
2. 游戏里输入 `/octoai`，上面一排按钮选内容（Summary、Gear、Quests、Talents、Spells、Professions、All）。天赋树效果、技能说明、专业配方都直接从游戏里读取，包含 Turtle/Octo 的改动。
3. 点 **Copy**（需要 ClassicAPI.dll；没有的话按钮是灰的，点 **Select all** 再按 Ctrl+C）。
4. 粘贴到任何 AI 聊天里，在最后的 `My question:` 后面写问题，可以用中文问。

银行、专业配方、训练师列表要先在游戏里打开对应窗口一次才会记录。你在游戏里鼠标指过的物品（拍卖行、商人、聊天链接、掉落等）会自动记下完整属性，方便 AI 判断值不值得买。`tools` 文件夹是给能直接读取 WoW 目录的 AI（比如连接了文件夹的 Claude 桌面版）用的，普通玩家不需要。要用的话先运行一次 `python tools/update_data.py` 下载任务数据库（以后再运行一次就是更新）。

## License

MIT, see [LICENSE](LICENSE). The quest database downloaded into `tools/data/` comes from OctoQuestDatabase and keeps its own license and notices.
