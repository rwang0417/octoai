# Changelog

## 1.2.0
- Tabs are now Summary, Gear, Quests, Talents, Spells, Professions, All. Bag items (and bank) are included in Summary, Gear, Quests and Professions instead of a separate tab.
- Talents: full talent trees with every talent's effect, your points and prerequisites.
- Spells: every spell and ability with its tooltip (cost, range, cooldown, effect), weapon skills, pet abilities and Beast Training list.
- Professions: profession levels and all recipes with reagents (grey recipes by name only).
- All: everything, plus trainer offers you have not learned yet, reputation and buffs.
- Shorter AI note at the top of the text.
- `octo_query.py`: character commands work without the quest database.

## 1.1.0
- Item tooltip cache: every item you hover (auction house, vendors, chat links, loot, bags, quest rewards, trade) is remembered with its full tooltip, account wide, newest 4000 items. Saved in `WTF\Account\<account>\SavedVariables\OctoAI.lua` on logout or /reload.
- `/octo status` shows how many items are cached.
- `tools/octo_query.py seen ID|NAME` prints the cached tooltip, so an AI can read exact stats of items you looked at.

## 1.0.0
- Renamed from OctoExport to OctoAI. Saved data now lives in `SavedVariables\OctoAI.lua` (variable `OctoAIDB`).
- `/octoai` window: a plain-text summary of your character to copy and paste into any AI chat.
- Tabs: Summary, Gear, Quests, Bags, Talents, Skills, All.
- Copy button (one click, needs ClassicAPI.dll), Select all, Close. Without ClassicAPI use Select all + Ctrl+C.
- The text starts with a short note telling the AI that this is OctoWoW (Turtle 1.18.1 content, 1.12 engine) and where to look things up.
- `tools/update_data.py`: downloads the quest database from OctoQuestDatabase into `tools/data/` (not stored in the repo).
- `tools/`: optional command line lookup tool and AI skill for people who connect their WoW folder to an AI assistant.

## 0.3.5 (as OctoExport)
- Full JSON snapshot via `/octo` and automatic export on changes (out of combat).
- Records bank (when opened), profession recipes (when the profession window is opened), trainer lists (when the trainer window is opened), pet info.
