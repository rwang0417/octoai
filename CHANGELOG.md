# Changelog

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
