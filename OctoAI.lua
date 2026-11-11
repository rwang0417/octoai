-- OctoAI: writes a JSON snapshot of the current character for AI assistants.
-- Target: WoW 1.12 engine (Lua 5.0), OctoWoW / Turtle WoW 1.18.1 client.
-- Writing uses VanillaHelpers.dll WriteFile() -> <WoW>\VanillaHelpersData\octo_<Name>.json
-- Quest IDs use ClassicAPI.dll GetQuestIDForLogIndex() when available.
-- Without WriteFile, the last snapshot is kept in SavedVariables (saved on logout or /reload).

local VERSION = "1.2.0"
local SCHEMA = 3
local PREFIX = "|cff66ccffOctoAI|r: "

local db -- OctoAIDB, set on ADDON_LOADED

local function msg(s)
  DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. s)
end

local function nowMs()
  if type(debugprofilestop) == "function" then return debugprofilestop() end
  return GetTime() * 1000
end

local function round(x, mult)
  if not x then return nil end
  return math.floor(x * mult + 0.5) / mult
end

---------------------------------------------------------------------------
-- Text helpers
---------------------------------------------------------------------------
local function strip(s)
  if not s then return nil end
  s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", "")
  s = string.gsub(s, "|r", "")
  s = string.gsub(s, "|H.-|h(.-)|h", "%1")
  return s
end

-- Cut a UTF-8 string to at most n bytes without splitting a character.
local function utf8cut(s, n)
  if string.len(s) <= n then return s end
  local i = n
  while i > 0 do
    local b = string.byte(s, i + 1)
    if not b or b < 128 or b > 191 then break end
    i = i - 1
  end
  return string.sub(s, 1, i) .. "..."
end

local function parseLink(link)
  if not link then return nil end
  local _, _, id = string.find(link, "item:(%d+)")
  local _, _, istr = string.find(link, "(item:[%-%d:]+)")
  local _, _, name = string.find(link, "%[(.-)%]")
  return tonumber(id), istr, name
end

local function isOn(v)
  return v and v ~= 0
end

---------------------------------------------------------------------------
-- Hidden tooltip scanner
---------------------------------------------------------------------------
local tip = CreateFrame("GameTooltip", "OctoAITip", nil, "GameTooltipTemplate")

local function tipLines(method, a, b, c)
  local out = {}
  if not method then return out end
  tip:SetOwner(WorldFrame, "ANCHOR_NONE")
  tip:ClearLines()
  method(tip, a, b, c)
  local n = tip:NumLines() or 0
  for i = 1, n do
    local l = getglobal("OctoAITipTextLeft" .. i)
    local r = getglobal("OctoAITipTextRight" .. i)
    local lt = l and l:GetText()
    local rt = r and r:IsShown() and r:GetText()
    if lt and lt ~= "" then
      if rt and rt ~= "" then lt = lt .. "  |  " .. rt end
      table.insert(out, strip(lt))
    end
  end
  tip:Hide()
  return out
end

---------------------------------------------------------------------------
-- Minimal JSON encoder (Lua 5.0 safe)
---------------------------------------------------------------------------
local function esc(s)
  return (string.gsub(s, '[%c"\\]', function(ch)
    if ch == '"' then return '\\"'
    elseif ch == "\\" then return "\\\\"
    elseif ch == "\n" then return "\\n"
    elseif ch == "\t" then return "\\t"
    elseif ch == "\r" then return "\\r"
    end
    return string.format("\\u%04x", string.byte(ch))
  end))
end

local function isArray(t)
  local count = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    count = count + 1
  end
  return count == table.getn(t)
end

local INF = 1 / 0

local encode
encode = function(v, buf)
  local tv = type(v)
  if tv == "nil" then
    table.insert(buf, "null")
  elseif tv == "boolean" then
    table.insert(buf, v and "true" or "false")
  elseif tv == "number" then
    if v ~= v or v == INF or v == -INF then
      table.insert(buf, "null")
    elseif math.floor(v) == v then
      table.insert(buf, string.format("%.0f", v))
    else
      table.insert(buf, string.format("%.4f", v))
    end
  elseif tv == "string" then
    table.insert(buf, '"' .. esc(v) .. '"')
  elseif tv == "table" then
    if isArray(v) then
      table.insert(buf, "[")
      for i = 1, table.getn(v) do
        if i > 1 then table.insert(buf, ",") end
        encode(v[i], buf)
      end
      table.insert(buf, "]")
    else
      local keys = {}
      for k in pairs(v) do table.insert(keys, tostring(k)) end
      table.sort(keys)
      table.insert(buf, "{")
      for i = 1, table.getn(keys) do
        local k = keys[i]
        local val = v[k]
        if val == nil then val = v[tonumber(k)] end
        if i > 1 then table.insert(buf, ",") end
        table.insert(buf, '"' .. esc(k) .. '":')
        encode(val, buf)
      end
      table.insert(buf, "}")
    end
  else
    table.insert(buf, "null")
  end
end

local function toJSON(v)
  local buf = {}
  encode(v, buf)
  return table.concat(buf)
end

---------------------------------------------------------------------------
-- Event suppression: our own expand/collapse calls fire update events.
---------------------------------------------------------------------------
local suppressUntil = {}
local function suppress(ev)
  suppressUntil[ev] = GetTime() + 1.5
end

---------------------------------------------------------------------------
-- Section collectors (each runs inside pcall)
---------------------------------------------------------------------------
local lastCoords

local function getCharacter()
  local c = {}
  c.name = UnitName("player")
  c.realm = GetRealmName()
  local cls, clsToken = UnitClass("player")
  c.class = cls
  c.classToken = clsToken
  local race, raceToken = UnitRace("player")
  c.race = race
  c.raceToken = raceToken
  c.faction = UnitFactionGroup("player")
  c.level = UnitLevel("player")
  c.xp = UnitXP("player")
  c.xpMax = UnitXPMax("player")
  c.restedXP = GetXPExhaustion()
  local money = GetMoney() or 0
  c.moneyCopper = money
  c.money = string.format("%dg %ds %dc", math.floor(money / 10000), math.floor(money / 100) - math.floor(money / 10000) * 100, money - math.floor(money / 100) * 100)
  c.guild = GetGuildInfo("player")
  c.healthMax = UnitHealthMax("player")
  c.powerMax = UnitManaMax("player")
  c.resting = IsResting() and true or false
  c.zone = GetRealZoneText()
  c.subzone = GetSubZoneText()
  -- Never touch the map the player is looking at; reuse the last position instead.
  if not (WorldMapFrame and WorldMapFrame:IsVisible()) then
    SetMapToCurrentZone()
    local x, y = GetPlayerMapPosition("player")
    if x and (x > 0 or y > 0) then
      lastCoords = { x = round(x * 100, 10), y = round(y * 100, 10) }
    else
      lastCoords = nil
    end
  end
  c.coords = lastCoords
  if UnitExists("pet") then
    c.pet = { name = UnitName("pet"), level = UnitLevel("pet"), family = UnitCreatureFamily("pet") }
    pcall(function()
      if type(GetPetTrainingPoints) == "function" then
        local total, spent = GetPetTrainingPoints()
        c.pet.trainingPoints = { total = total, spent = spent }
      end
      if type(GetPetLoyalty) == "function" then c.pet.loyalty = GetPetLoyalty() end
      if type(GetPetHappiness) == "function" then c.pet.happiness = GetPetHappiness() end
      local spells, seen = {}, {}
      local i = 1
      while true do
        local sname, srank = GetSpellName(i, "pet")
        if not sname then break end
        local key = sname .. (srank or "")
        if not seen[key] then
          seen[key] = true
          if srank and srank ~= "" then table.insert(spells, sname .. " (" .. srank .. ")") else table.insert(spells, sname) end
        end
        i = i + 1
        if i > 60 then break end
      end
      c.pet.spells = spells
    end)
  end
  return c
end

local STAT_NAMES = { "Strength", "Agility", "Stamina", "Intellect", "Spirit" }
local RES_NAMES = { [1] = "Holy", [2] = "Fire", [3] = "Nature", [4] = "Frost", [5] = "Shadow", [6] = "Arcane" }

local function optional(fn, a)
  if type(fn) ~= "function" then return nil end
  local ok, v = pcall(fn, a)
  if ok then return v end
  return nil
end

local function getStats()
  local s = { primary = {}, resist = {} }
  for i = 1, 5 do
    local _, stat = UnitStat("player", i)
    s.primary[STAT_NAMES[i]] = stat
  end
  local _, armor = UnitArmor("player")
  s.armor = armor
  local apBase, apPos, apNeg = UnitAttackPower("player")
  if apBase then s.attackPower = apBase + (apPos or 0) + (apNeg or 0) end
  local rBase, rPos, rNeg = UnitRangedAttackPower("player")
  if rBase then s.rangedAttackPower = rBase + (rPos or 0) + (rNeg or 0) end
  for i = 1, 6 do
    local _, total = UnitResistance("player", i)
    s.resist[RES_NAMES[i]] = total
  end
  s.critChance = optional(GetCritChance)
  s.rangedCritChance = optional(GetRangedCritChance)
  s.spellCritChance = optional(GetSpellCritChance, 2)
  s.dodgeChance = optional(GetDodgeChance)
  s.parryChance = optional(GetParryChance)
  s.blockChance = optional(GetBlockChance)
  return s
end

local function getTalents()
  local T = { unspent = UnitCharacterPoints("player"), trees = {} }
  local spent = {}
  for tab = 1, GetNumTalentTabs() do
    local tname, _, tspent = GetTalentTabInfo(tab)
    local tree = { name = tname, spent = tspent, talents = {} }
    table.insert(spent, tspent or 0)
    for i = 1, GetNumTalents(tab) do
      local name, _, tier, col, rank, maxRank = GetTalentInfo(tab, i)
      local t = { name = name, tier = tier, col = col, rank = rank, max = maxRank }
      local pt, pc = GetTalentPrereqs(tab, i)
      if pt then t.requires = { tier = pt, col = pc } end
      t.tooltip = tipLines(tip.SetTalent, tab, i)
      table.insert(tree.talents, t)
    end
    table.insert(T.trees, tree)
  end
  T.build = table.concat(spent, "/")
  return T
end

local SLOT_NAMES = {
  [0] = "Ammo", [1] = "Head", [2] = "Neck", [3] = "Shoulder", [4] = "Shirt", [5] = "Chest",
  [6] = "Waist", [7] = "Legs", [8] = "Feet", [9] = "Wrist", [10] = "Hands", [11] = "Finger1",
  [12] = "Finger2", [13] = "Trinket1", [14] = "Trinket2", [15] = "Back", [16] = "MainHand",
  [17] = "OffHand", [18] = "Ranged", [19] = "Tabard",
}
local QUALITY = { [0] = "Poor", [1] = "Common", [2] = "Uncommon", [3] = "Rare", [4] = "Epic", [5] = "Legendary", [6] = "Artifact" }

local function itemBasics(link)
  local id, istr, linkName = parseLink(link)
  local it = { id = id, name = linkName, itemString = istr }
  if id then
    local iname, _, quality, minLevel, itype, isub, _, equipLoc = GetItemInfo(id)
    if iname then
      -- the link name keeps random suffixes ("of the Monkey"); GetItemInfo returns the base name
      it.name = linkName or iname
      it.quality = QUALITY[quality] or quality
      if minLevel and minLevel > 0 then it.reqLevel = minLevel end
      it.type = itype
      it.subtype = isub
      if equipLoc and equipLoc ~= "" then it.equipLoc = equipLoc end
    end
  end
  return it
end

local function getEquipment()
  local E = {}
  for slot = 0, 19 do
    local link = GetInventoryItemLink("player", slot)
    if link then
      local it = itemBasics(link)
      it.slot = SLOT_NAMES[slot]
      it.tooltip = tipLines(tip.SetInventoryItem, "player", slot)
      table.insert(E, it)
    end
  end
  return E
end

-- Scan containers. Equippable items get a full tooltip; other items are merged by item string.
local function scanContainers(bagList, withTooltips)
  local equippable, other, order = {}, {}, {}
  local bags = {}
  local free, total = 0, 0
  for _, bag in ipairs(bagList) do
    local n = GetContainerNumSlots(bag) or 0
    if n > 0 then
      local bname = (bag == 0 and "Backpack") or (bag == -1 and "Bank") or GetBagName(bag)
      table.insert(bags, { id = bag, name = bname, slots = n })
      total = total + n
      for slot = 1, n do
        local link = GetContainerItemLink(bag, slot)
        if not link then
          free = free + 1
        else
          local _, count = GetContainerItemInfo(bag, slot)
          local it = itemBasics(link)
          if not count or count < 1 then count = 1 end
          if it.equipLoc and withTooltips then
            it.count = count
            it.tooltip = tipLines(tip.SetBagItem, bag, slot)
            table.insert(equippable, it)
          else
            local key = it.itemString or it.name or link
            if other[key] then
              other[key].count = other[key].count + count
            else
              it.count = count
              other[key] = it
              table.insert(order, key)
            end
          end
        end
      end
    end
  end
  local items = {}
  for _, k in ipairs(order) do table.insert(items, other[k]) end
  return { bags = bags, freeSlots = free, totalSlots = total, equippable = equippable, items = items }
end

local function getBags()
  return scanContainers({ 0, 1, 2, 3, 4 }, true)
end

local function snapshotBank()
  local list = { -1 }
  for b = 5, 10 do table.insert(list, b) end
  local ok, res = pcall(scanContainers, list, false)
  if ok and db then
    res.scannedAt = date("%Y-%m-%d %H:%M:%S")
    db.bank = res
  end
end

local function questIDForIndex(i)
  if type(GetQuestIDForLogIndex) == "function" then
    local ok, id = pcall(GetQuestIDForLogIndex, i)
    if ok and type(id) == "number" and id > 0 then return id end
  end
  if C_QuestLog and type(C_QuestLog.GetQuestIDForLogIndex) == "function" then
    local ok, id = pcall(C_QuestLog.GetQuestIDForLogIndex, i)
    if ok and type(id) == "number" and id > 0 then return id end
  end
  return nil
end

local function hasQuestIDs()
  return (type(GetQuestIDForLogIndex) == "function")
    or (C_QuestLog and type(C_QuestLog.GetQuestIDForLogIndex) == "function") and true or false
end

local function getQuests()
  local Q = {}
  local selected = GetQuestLogSelection()
  local collapsed, hadCollapsed = {}, false
  local n = GetNumQuestLogEntries()
  for i = 1, n do
    local title, _, _, isHeader, isCollapsed = GetQuestLogTitle(i)
    if isOn(isHeader) and isOn(isCollapsed) then collapsed[title] = true; hadCollapsed = true end
  end
  suppress("QUEST_LOG_UPDATE")
  if hadCollapsed then ExpandQuestHeader(0) end

  local header
  n = GetNumQuestLogEntries()
  for i = 1, n do
    local title, level, tag, isHeader, _, isComplete = GetQuestLogTitle(i)
    if isOn(isHeader) then
      header = title
    elseif title then
      local q = { title = title, level = level, header = header }
      if tag and tag ~= "" then q.tag = tag end
      if isComplete == 1 then q.status = "complete"
      elseif isComplete == -1 then q.status = "failed"
      else q.status = "in progress" end
      q.id = questIDForIndex(i)
      SelectQuestLogEntry(i)
      local desc, obj = GetQuestLogQuestText()
      q.objective = obj
      if desc then q.description = utf8cut(desc, 700) end
      local nb = GetNumQuestLeaderBoards(i) or 0
      if nb > 0 then
        q.progress = {}
        for j = 1, nb do
          local text, otype, finished = GetQuestLogLeaderBoard(j, i)
          table.insert(q.progress, { text = text, type = otype, done = isOn(finished) and true or false })
        end
      end
      table.insert(Q, q)
    end
  end

  if hadCollapsed then
    for i = GetNumQuestLogEntries(), 1, -1 do
      local title, _, _, isHeader = GetQuestLogTitle(i)
      if isOn(isHeader) and collapsed[title] then CollapseQuestHeader(i) end
    end
  end
  SelectQuestLogEntry(selected or 0)
  if QuestLogFrame and QuestLogFrame:IsVisible() and type(QuestLog_Update) == "function" then
    QuestLog_Update()
  end
  return Q
end

-- Expand collapsed headers bottom-up (indices above stay valid), read, then re-collapse by name.
local function withExpanded(count, info, expand, collapse, event, reader)
  local collapsed = {}
  suppress(event)
  for i = count(), 1, -1 do
    local name, isHeader, isCollapsed = info(i)
    if isOn(isHeader) and isOn(isCollapsed) then
      collapsed[name] = true
      expand(i)
    end
  end
  local ok, res = pcall(reader)
  for i = count(), 1, -1 do
    local name, isHeader = info(i)
    if isOn(isHeader) and collapsed[name] then collapse(i) end
  end
  if not ok then error(res) end
  return res
end


---------------------------------------------------------------------------
-- Professions: recipes are only readable while the trade skill / craft
-- window is open, so they are scanned then and kept in SavedVariables.
---------------------------------------------------------------------------
local function linkId(link)
  if not link then return nil end
  local _, _, id = string.find(link, "item:(%d+)")
  if id then return tonumber(id) end
  local _, _, eid = string.find(link, "enchant:(%d+)")
  if eid then return "enchant:" .. eid end
  return nil
end

local function readyAt(cd)
  if not cd or cd <= 0 then return nil end
  local ok, v = pcall(function() return date("%Y-%m-%d %H:%M", time() + cd) end)
  if ok then return v end
  return nil
end

local function readTradeSkill()
  local pname, rank, maxRank = GetTradeSkillLine()
  if not pname or pname == "UNKNOWN" then return nil end
  local P = { name = pname, rank = rank, max = maxRank, kind = "tradeskill", recipes = {} }
  local header
  for i = 1, GetNumTradeSkills() do
    local sname, stype, numAvail = GetTradeSkillInfo(i)
    if stype == "header" then
      header = sname
    elseif sname then
      local r = { name = sname, difficulty = stype, header = header }
      if numAvail and numAvail > 0 then r.canMake = numAvail end
      r.itemId = linkId(GetTradeSkillItemLink(i))
      local mn, mx = GetTradeSkillNumMade(i)
      if mn and mx and (mn ~= 1 or mx ~= 1) then
        if mn == mx then r.made = mn else r.made = mn .. "-" .. mx end
      end
      local cd = GetTradeSkillCooldown(i)
      if cd and cd > 0 then r.cooldownSec = math.floor(cd); r.readyAt = readyAt(cd) end
      r.reagents = {}
      for j = 1, (GetTradeSkillNumReagents(i) or 0) do
        local rn, _, rc, have = GetTradeSkillReagentInfo(i, j)
        local rg = { name = rn, count = rc, have = have }
        if type(GetTradeSkillReagentItemLink) == "function" then rg.id = linkId(GetTradeSkillReagentItemLink(i, j)) end
        table.insert(r.reagents, rg)
      end
      table.insert(P.recipes, r)
    end
  end
  return P
end

local function readCraft()
  local pname, rank, maxRank
  if type(GetCraftDisplaySkillLine) == "function" then pname, rank, maxRank = GetCraftDisplaySkillLine() end
  if not pname and type(GetCraftName) == "function" then pname = GetCraftName() end
  if not pname or pname == "UNKNOWN" then return nil end
  local P = { name = pname, rank = rank, max = maxRank, kind = "craft", recipes = {} }
  local header
  for i = 1, GetNumCrafts() do
    local cname, csub, ctype, numAvail, _, tpCost, reqLevel = GetCraftInfo(i)
    if ctype == "header" then
      header = cname
    elseif cname then
      local r = { name = cname, difficulty = ctype, header = header }
      if csub and csub ~= "" then r.rank = csub end
      if numAvail and numAvail > 0 then r.canMake = numAvail end
      if tpCost and tpCost > 0 then r.trainingPoints = tpCost end
      if reqLevel and reqLevel > 0 then r.reqLevel = reqLevel end
      if type(GetCraftItemLink) == "function" then r.itemId = linkId(GetCraftItemLink(i)) end
      r.reagents = {}
      for j = 1, (GetCraftNumReagents(i) or 0) do
        local rn, _, rc, have = GetCraftReagentInfo(i, j)
        local rg = { name = rn, count = rc, have = have }
        if type(GetCraftReagentItemLink) == "function" then rg.id = linkId(GetCraftReagentItemLink(i, j)) end
        table.insert(r.reagents, rg)
      end
      table.insert(P.recipes, r)
    end
  end
  return P
end

local function scanTradeSkill()
  return withExpanded(GetNumTradeSkills,
    function(i) local n, t, _, e = GetTradeSkillInfo(i); return n, t == "header", not isOn(e) end,
    ExpandTradeSkillSubClass, CollapseTradeSkillSubClass, "TRADE_SKILL_UPDATE", readTradeSkill)
end

local function scanCraft()
  return withExpanded(GetNumCrafts,
    function(i) local n, _, t, _, e = GetCraftInfo(i); return n, t == "header", not isOn(e) end,
    ExpandCraftSkillLine, CollapseCraftSkillLine, "CRAFT_UPDATE", readCraft)
end


---------------------------------------------------------------------------
-- Trainer window: what the open trainer teaches (all filters), with cost
---------------------------------------------------------------------------
local function scanTrainer()
  if type(GetNumTrainerServices) ~= "function" then return nil end
  local saved = {}
  local types = { "available", "unavailable", "used" }
  if type(GetTrainerServiceTypeFilter) == "function" and type(SetTrainerServiceTypeFilter) == "function" then
    suppress("TRAINER_UPDATE")
    for _, t in ipairs(types) do
      if not isOn(GetTrainerServiceTypeFilter(t)) then saved[t] = true; SetTrainerServiceTypeFilter(t, 1) end
    end
  end
  if type(ExpandTrainerSkillLine) == "function" then ExpandTrainerSkillLine(0) end
  local T = { trainer = UnitName("npc"), services = {} }
  local header
  local ok, err = pcall(function()
    for i = 1, GetNumTrainerServices() do
      local name, sub, stype = GetTrainerServiceInfo(i)
      if stype == "header" then
        header = name
      elseif name then
        local sv = { name = name, status = stype, header = header }
        if sub and sub ~= "" then sv.rank = sub end
        local money = GetTrainerServiceCost(i)
        if money and money > 0 then sv.costCopper = money end
        if type(GetTrainerServiceSkillReq) == "function" then
          local skill, rank, has = GetTrainerServiceSkillReq(i)
          if skill then sv.requires = skill .. " " .. tostring(rank); sv.meetsSkill = isOn(has) and true or false end
        end
        if type(GetTrainerServiceLevelReq) == "function" then
          local lvl = GetTrainerServiceLevelReq(i)
          if lvl and lvl > 0 then sv.reqLevel = lvl end
        end
        table.insert(T.services, sv)
      end
    end
  end)
  for _, t in ipairs(types) do
    if saved[t] then SetTrainerServiceTypeFilter(t, 0) end
  end
  if not ok then error(err) end
  return T
end

local function getSkills()
  return withExpanded(GetNumSkillLines,
    function(i) local name, isHeader, isExpanded = GetSkillLineInfo(i); return name, isHeader, not isOn(isExpanded) end,
    ExpandSkillHeader, CollapseSkillHeader, "SKILL_LINES_CHANGED",
    function()
      local S, header = {}, nil
      for i = 1, GetNumSkillLines() do
        local name, isHeader, _, rank, _, modifier, maxRank = GetSkillLineInfo(i)
        if isOn(isHeader) then
          header = name
        elseif name then
          local s = { name = name, category = header, rank = rank, max = maxRank }
          if modifier and modifier ~= 0 then s.bonus = modifier end
          table.insert(S, s)
        end
      end
      return S
    end)
end

local function getReputation()
  return withExpanded(GetNumFactions,
    function(i) local name, _, _, _, _, _, _, _, isHeader, isCollapsed = GetFactionInfo(i); return name, isHeader, isCollapsed end,
    ExpandFactionHeader, CollapseFactionHeader, "UPDATE_FACTION",
    function()
      local R, header = {}, nil
      for i = 1, GetNumFactions() do
        local name, _, standingID, barMin, barMax, barValue, atWar, _, isHeader = GetFactionInfo(i)
        if isOn(isHeader) then
          header = name
        elseif name then
          local r = { name = name, group = header, standing = getglobal("FACTION_STANDING_LABEL" .. (standingID or 0)) }
          if barMax and barMin and barValue then
            r.progress = (barValue - barMin) .. "/" .. (barMax - barMin)
          end
          if isOn(atWar) then r.atWar = true end
          table.insert(R, r)
        end
      end
      return R
    end)
end

local function getSpells()
  local tabs = {}
  for t = 1, GetNumSpellTabs() do
    local tname, _, offset, num = GetSpellTabInfo(t)
    local ranks, order = {}, {}
    for i = offset + 1, offset + num do
      local sname, srank = GetSpellName(i, BOOKTYPE_SPELL)
      if sname then
        if ranks[sname] == nil then table.insert(order, sname) end
        ranks[sname] = srank or ""
      end
    end
    local list = {}
    for _, sname in ipairs(order) do
      local r = ranks[sname]
      if r and r ~= "" then table.insert(list, sname .. " (" .. r .. ")") else table.insert(list, sname) end
    end
    local entry = { tab = tname, spells = list }
    -- full tooltip of the highest rank of every spell (ranks are listed low to high)
    local lastIdx = {}
    for i = offset + 1, offset + num do
      local sname = GetSpellName(i, BOOKTYPE_SPELL)
      if sname then lastIdx[sname] = i end
    end
    entry.details = {}
    for sname, i in pairs(lastIdx) do
      entry.details[sname] = tipLines(tip.SetSpell, i, BOOKTYPE_SPELL)
    end
    table.insert(tabs, entry)
  end
  return tabs
end

local function getBuffs()
  local B = {}
  for i = 0, 31 do
    local idx = GetPlayerBuff(i, "HELPFUL")
    if not idx or idx < 0 then break end
    local lines = tipLines(tip.SetPlayerBuff, idx)
    if lines[1] then table.insert(B, lines[1]) end
  end
  return B
end

---------------------------------------------------------------------------
-- Snapshot with per-section caching
---------------------------------------------------------------------------
local SECTIONS = {
  { "character", getCharacter, true },   -- third field: refresh on every export (cheap)
  { "stats", getStats, true },
  { "buffs", getBuffs, true },
  { "talents", getTalents },
  { "equipment", getEquipment },
  { "bags", getBags },
  { "quests", getQuests },
  { "skills", getSkills },
  { "reputation", getReputation },
  { "spells", getSpells },
}
local cache, stale = {}, {}

local function buildSnapshot(reason, full)
  local snap = {
    schema = SCHEMA,
    addonVersion = VERSION,
    server = "OctoWoW",
    client = "Turtle WoW 1.18.1 based client (WoW 1.12 engine)",
    exportedAt = date("%Y-%m-%d %H:%M:%S"),
    trigger = reason,
  }
  local errs = {}
  for _, sec in ipairs(SECTIONS) do
    local key, fn, always = sec[1], sec[2], sec[3]
    if full or always or stale[key] or cache[key] == nil then
      local ok, res = pcall(fn)
      if ok then
        cache[key] = res
        stale[key] = nil
      else
        table.insert(errs, key .. ": " .. tostring(res))
      end
    end
    snap[key] = cache[key]
  end
  if db and db.bank then snap.bank = db.bank end
  if db and db.professions then snap.professions = db.professions end
  if db and db.trainers then snap.trainers = db.trainers end
  snap.questIdSource = hasQuestIDs() and "ClassicAPI" or "none"
  snap.errors = errs
  return snap, errs
end

local function safeName(name)
  -- WriteFile rejects < > : " / \ | ? * ; keep the file name plain ASCII
  return (string.gsub(name or "unknown", "[^%w%-_]", "_"))
end

local function writeFile(name, content)
  if type(WriteFile) ~= "function" then return false, "WriteFile() not available (VanillaHelpers.dll not loaded)" end
  local ok, r1, r2 = pcall(WriteFile, name, "w", content)
  if not ok then return false, tostring(r1) end
  if r1 == false or (r1 == nil and r2) then return false, tostring(r2) end
  return true
end

local busy = false
local warnedWrite, warnedErr = false, false

local function doExport(reason, quiet, full)
  if busy then return end
  busy = true
  local t0 = nowMs()
  local ok, snap, errs = pcall(buildSnapshot, reason, full)
  local json
  if ok then
    ok, json = pcall(toJSON, snap)
  else
    json = snap
  end
  if not ok then
    busy = false
    msg("|cffff5555export failed:|r " .. tostring(json))
    return
  end
  local fname = "octo_" .. safeName(UnitName("player")) .. ".json"
  local written, werr = writeFile(fname, json)
  local dt = nowMs() - t0
  if db then
    db.last = json
    db.lastExport = snap.exportedAt
    db.lastMs = dt
  end
  busy = false
  local kb = string.format("%.1f KB", string.len(json) / 1024)
  if written then
    if not quiet or (db and db.verbose) then
      msg(string.format("exported %s in %d ms -> VanillaHelpersData\\%s", kb, dt, fname))
    end
  elseif not quiet or not warnedWrite then
    warnedWrite = true
    msg("|cffffaa00file write unavailable|r (" .. tostring(werr) .. "). Snapshot kept in SavedVariables; it is saved on logout or /reload.")
  end
  if errs and table.getn(errs) > 0 and (not quiet or not warnedErr) then
    warnedErr = true
    msg("|cffffaa00" .. table.getn(errs) .. " section(s) failed:|r " .. errs[1])
  end
end

---------------------------------------------------------------------------
-- Auto export: event driven, debounced, never in combat
---------------------------------------------------------------------------
local FAST_DEBOUNCE, FAST_MAXWAIT, SLOW_DELAY = 3, 15, 30
local fastDue, fastFirst, slowDue, lastReason = nil, nil, nil, nil

local function markDirty(reason, sections, slow, delay)
  if sections then
    for _, s in ipairs(sections) do stale[s] = true end
  end
  if not db or not db.auto then return end
  local now = GetTime()
  lastReason = reason
  if slow then
    if not slowDue then slowDue = now + SLOW_DELAY end
  else
    if not fastDue then fastFirst = now end
    local due = now + (delay or FAST_DEBOUNCE)
    if fastDue and fastDue > due then due = fastDue end
    if due > fastFirst + FAST_MAXWAIT and not delay then due = fastFirst + FAST_MAXWAIT end
    fastDue = due
  end
end


local profDue, profKind = nil, nil
local warnedProf = false

local function scanProfession(kind)
  local ok, P
  if kind == "craft" then ok, P = pcall(scanCraft) else ok, P = pcall(scanTradeSkill) end
  if not ok then
    if not warnedProf then warnedProf = true; msg("|cffffaa00profession scan failed:|r " .. tostring(P)) end
    return
  end
  if not P or not db then return end
  P.scannedAt = date("%Y-%m-%d %H:%M:%S")
  db.professions = db.professions or {}
  local old = db.professions[P.name]
  db.professions[P.name] = P
  if not old and (not db.verbose) then
    msg("saved " .. table.getn(P.recipes) .. " " .. P.name .. " recipes")
  end
  markDirty("profession:" .. P.name, nil)
end

local function saveTrainer()
  local ok, T = pcall(scanTrainer)
  if not ok then msg("|cffffaa00trainer scan failed:|r " .. tostring(T)); return end
  if not T or not T.trainer or not db then return end
  T.scannedAt = date("%Y-%m-%d %H:%M:%S")
  db.trainers = db.trainers or {}
  db.trainers[T.trainer] = T
  markDirty("trainer", nil)
end

local function scheduleProfession(kind)
  profKind = kind
  profDue = GetTime() + 0.7
end

local frame = CreateFrame("Frame", "OctoAIEventFrame")
local elapsedAcc = 0
frame:SetScript("OnUpdate", function()
  elapsedAcc = elapsedAcc + (arg1 or 0)
  if elapsedAcc < 0.5 then return end
  elapsedAcc = 0
  local now = GetTime()
  if profDue and now >= profDue and not UnitAffectingCombat("player") then
    local k = profKind
    profDue, profKind = nil, nil
    scanProfession(k)
  end
  if ((fastDue and now >= fastDue) or (slowDue and now >= slowDue)) and not UnitAffectingCombat("player") then
    fastDue, slowDue = nil, nil
    doExport("auto:" .. (lastReason or "?"), true)
  end
end)

local ALL_SECTIONS = { "talents", "equipment", "bags", "quests", "skills", "reputation", "spells" }
local EVENTS = {
  CHARACTER_POINTS_CHANGED = { "talents", { "talents" } },
  PLAYER_LEVEL_UP = { "level", ALL_SECTIONS },
  ZONE_CHANGED_NEW_AREA = { "zone", nil },
  SKILL_LINES_CHANGED = { "skills", { "skills" } },
  SPELLS_CHANGED = { "spells", { "spells", "talents" } },
  UPDATE_FACTION = { "reputation", { "reputation" } },
  QUEST_LOG_UPDATE = { "quests", { "quests" } },
  BAG_UPDATE = { "bags", { "bags" }, true },
  PLAYER_MONEY = { "money", nil, true },
}

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("UNIT_INVENTORY_CHANGED")
frame:RegisterEvent("BANKFRAME_OPENED")
frame:RegisterEvent("BANKFRAME_CLOSED")
frame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
frame:RegisterEvent("TRADE_SKILL_SHOW")
frame:RegisterEvent("TRADE_SKILL_UPDATE")
frame:RegisterEvent("CRAFT_SHOW")
frame:RegisterEvent("CRAFT_UPDATE")
frame:RegisterEvent("TRADE_SKILL_CLOSE")
frame:RegisterEvent("CRAFT_CLOSE")
frame:RegisterEvent("TRAINER_SHOW")
for ev in pairs(EVENTS) do frame:RegisterEvent(ev) end

local loggedIn, bankOpen = false, false

frame:SetScript("OnEvent", function()
  if event == "ADDON_LOADED" then
    if arg1 == "OctoAI" then
      OctoAIDB = OctoAIDB or {}
      db = OctoAIDB
      if db.auto == nil then db.auto = true end
    end
    return
  end
  if suppressUntil[event] and GetTime() < suppressUntil[event] then return end
  if event == "PLAYER_ENTERING_WORLD" then
    if not loggedIn then
      loggedIn = true
      markDirty("login", ALL_SECTIONS, false, 8)
    end
  elseif not loggedIn then
    return
  elseif event == "UNIT_INVENTORY_CHANGED" then
    if arg1 == "player" then markDirty("equipment", { "equipment", "bags" }) end
  elseif event == "BANKFRAME_OPENED" then
    bankOpen = true
    snapshotBank()
    markDirty("bank", { "bags" })
  elseif event == "BANKFRAME_CLOSED" then
    bankOpen = false
  elseif event == "TRADE_SKILL_SHOW" then
    -- read right away: the window may be closed again before a delayed scan runs
    scanProfession("tradeskill")
  elseif event == "CRAFT_SHOW" then
    scanProfession("craft")
  elseif event == "TRADE_SKILL_UPDATE" then
    scheduleProfession("tradeskill")
  elseif event == "CRAFT_UPDATE" then
    scheduleProfession("craft")
  elseif event == "TRAINER_SHOW" then
    saveTrainer()
  elseif event == "TRADE_SKILL_CLOSE" or event == "CRAFT_CLOSE" then
    profDue, profKind = nil, nil
  elseif event == "PLAYERBANKSLOTS_CHANGED" then
    if bankOpen then snapshotBank(); markDirty("bank", { "bags" }, true) end
  else
    local e = EVENTS[event]
    if e then
      if event == "BAG_UPDATE" and bankOpen then snapshotBank() end
      markDirty(e[1], e[2], e[3])
    end
  end
end)

---------------------------------------------------------------------------
-- Item tooltip cache: every item the player looks at is remembered (account wide,
-- SavedVariables OctoAIItems). Lets an AI read exact stats of items you hovered
-- in the auction house, at vendors, in chat links, loot rolls and so on.
-- Entry format (one string, easy to parse): "<time>\n<itemId>\n<name>\n<tooltip line>\n..."
---------------------------------------------------------------------------
local ITEM_CAP, ITEM_PRUNE = 4000, 600
local itemCount

local function itemCache()
  if type(OctoAIItems) ~= "table" then OctoAIItems = {} end
  if type(OctoAIItems.items) ~= "table" then OctoAIItems.items = {} end
  return OctoAIItems.items
end

local function pruneItems(items)
  local list = {}
  for k, v in pairs(items) do
    local _, _, t = string.find(v, "^(%d+)")
    table.insert(list, { k, tonumber(t) or 0 })
  end
  table.sort(list, function(a, b) return a[2] < b[2] end)
  for i = 1, ITEM_PRUNE do
    if list[i] then items[list[i][1]] = nil end
  end
  itemCount = table.getn(list) - ITEM_PRUNE
end

local function rememberTooltip(tt, link)
  if not link or not tt or not tt.GetName then return end
  local id, istr, lname = parseLink(link)
  if not id then return end
  local tname = tt:GetName()
  if not tname then return end
  local lines = {}
  for i = 1, (tt:NumLines() or 0) do
    local l = getglobal(tname .. "TextLeft" .. i)
    local r = getglobal(tname .. "TextRight" .. i)
    local lt = l and l:GetText()
    local rt = r and r:IsShown() and r:GetText()
    if lt and lt ~= "" then
      if rt and rt ~= "" then lt = lt .. "  |  " .. rt end
      table.insert(lines, strip(lt))
    end
  end
  if table.getn(lines) == 0 then return end
  local items = itemCache()
  local key = istr or ("item:" .. id)
  if not items[key] then
    if not itemCount then
      itemCount = 0
      for _ in pairs(items) do itemCount = itemCount + 1 end
    end
    itemCount = itemCount + 1
    if itemCount > ITEM_CAP then pruneItems(items) end
  end
  items[key] = time() .. "\n" .. id .. "\n" .. (lname or lines[1]) .. "\n" .. table.concat(lines, "\n")
end

local function hookTip(tt, method, linkFn)
  if not tt then return end
  local orig = tt[method]
  if type(orig) ~= "function" then return end
  tt[method] = function(self, a, b, c, d)
    local r1, r2, r3 = orig(self, a, b, c, d)
    local ok, link = pcall(linkFn, a, b, c, d)
    if ok and link then pcall(rememberTooltip, self, link) end
    return r1, r2, r3
  end
end

local TIP_LINKS = {
  SetHyperlink = function(a) return a end,
  SetBagItem = function(a, b) return GetContainerItemLink(a, b) end,
  SetInventoryItem = function(a, b) return GetInventoryItemLink(a, b) end,
  SetAuctionItem = function(a, b) return GetAuctionItemLink(a, b) end,
  SetMerchantItem = function(a) return GetMerchantItemLink(a) end,
  SetLootItem = function(a) return GetLootSlotLink(a) end,
  SetLootRollItem = function(a) return GetLootRollItemLink(a) end,
  SetQuestItem = function(a, b) return GetQuestItemLink(a, b) end,
  SetQuestLogItem = function(a, b) return GetQuestLogItemLink(a, b) end,
  SetTradeSkillItem = function(a, b) if b then return GetTradeSkillReagentItemLink(a, b) end return GetTradeSkillItemLink(a) end,
  SetCraftItem = function(a, b) if b then return GetCraftReagentItemLink(a, b) end return GetCraftItemLink(a) end,
  SetTradePlayerItem = function(a) return GetTradePlayerItemLink(a) end,
  SetTradeTargetItem = function(a) return GetTradeTargetItemLink(a) end,
}
for method, fn in pairs(TIP_LINKS) do hookTip(GameTooltip, method, fn) end
hookTip(ItemRefTooltip, "SetHyperlink", TIP_LINKS.SetHyperlink)

local function itemCacheCount()
  local n = 0
  for _ in pairs(itemCache()) do n = n + 1 end
  return n
end

---------------------------------------------------------------------------
-- /octoai: copyable plain-text summary for pasting into any AI chat
---------------------------------------------------------------------------
local AI_HEADER = "[OctoAI export. Server: OctoWoW = Turtle WoW 1.18.1 content on the 1.12 engine, with custom zones, quests, items and talents, so do not assume retail/Classic. "
  .. "Treat this data as fact. Look up other things at octowow.st/db/?item=ID (or quest=, npc=) using the [IDs]. Say when you guess. Keep game names in English. Coords are zone map %.]"

local SKIP_TIP = { "^Soulbound", "^Binds when", "^Binds to", "^Durability", "^Unique", "^Quest Item", "^<Right Click" }

local function tipText(lines, skipFirst)
  local out = {}
  if not lines then return "" end
  for i, l in ipairs(lines) do
    if not (skipFirst and i == 1) then
      local skip = false
      for _, p in ipairs(SKIP_TIP) do if string.find(l, p) then skip = true; break end end
      if not skip then table.insert(out, l) end
    end
  end
  return (string.gsub(table.concat(out, "; "), "%s+", " "))
end

local function idTag(id) if id then return " [" .. id .. "]" end return "" end

local function aiCharacter(s, out)
  local c, st, t = s.character or {}, s.stats or {}, s.talents or {}
  table.insert(out, "== CHARACTER ==")
  table.insert(out, string.format("%s, level %s %s %s (%s), realm %s", tostring(c.name), tostring(c.level), tostring(c.race), tostring(c.class), tostring(c.faction), tostring(c.realm)))
  local where = tostring(c.zone)
  if c.subzone and c.subzone ~= "" then where = where .. " / " .. c.subzone end
  if c.coords then where = where .. string.format(" at (%.1f, %.1f)", c.coords.x, c.coords.y) end
  table.insert(out, "Location: " .. where)
  table.insert(out, string.format("XP %s/%s, rested %s, money %s", tostring(c.xp), tostring(c.xpMax), tostring(c.restedXP or 0), tostring(c.money)))
  if t.build then table.insert(out, "Talents: " .. t.build .. (t.unspent and t.unspent > 0 and (" (" .. t.unspent .. " unspent)") or "")) end
  local p = st.primary or {}
  local stats = string.format("Stats: Str %s Agi %s Sta %s Int %s Spi %s, Armor %s, AP %s, Ranged AP %s",
    tostring(p.Strength), tostring(p.Agility), tostring(p.Stamina), tostring(p.Intellect), tostring(p.Spirit), tostring(st.armor),
    tostring(st.attackPower), tostring(st.rangedAttackPower))
  if st.critChance and st.critChance > 0 then stats = stats .. ", Crit " .. round(st.critChance, 100) .. "%" end
  if st.rangedCritChance and st.rangedCritChance > 0 then stats = stats .. ", Ranged crit " .. round(st.rangedCritChance, 100) .. "%" end
  table.insert(out, stats)
  if c.pet then
    table.insert(out, string.format("Pet: %s, level %s %s; %s", tostring(c.pet.name), tostring(c.pet.level), tostring(c.pet.family), table.concat(c.pet.spells or {}, ", ")))
  end
end

local function aiGear(s, out)
  table.insert(out, "== EQUIPPED ==")
  for _, it in ipairs(s.equipment or {}) do
    if it.slot ~= "Shirt" and it.slot ~= "Tabard" then
      table.insert(out, string.format("%s: %s%s (%s) %s", tostring(it.slot), tostring(it.name), idTag(it.id), tostring(it.quality), tipText(it.tooltip, true)))
    end
  end
  local eq = s.bags and s.bags.equippable or {}
  if table.getn(eq) > 0 then
    table.insert(out, "== GEAR IN BAGS ==")
    for _, it in ipairs(eq) do
      table.insert(out, string.format("%s%s (%s) %s", tostring(it.name), idTag(it.id), tostring(it.quality), tipText(it.tooltip, true)))
    end
  end
end

local function aiQuests(s, out)
  table.insert(out, "== QUEST LOG ==")
  for _, q in ipairs(s.quests or {}) do
    local line = string.format("%s%s, level %s, %s", tostring(q.title), idTag(q.id), tostring(q.level), tostring(q.status))
    if q.tag then line = line .. " (" .. q.tag .. ")" end
    if q.header then line = line .. ", zone group: " .. q.header end
    table.insert(out, line)
    if q.objective and q.objective ~= "" then table.insert(out, "  Objective: " .. utf8cut(q.objective, 300)) end
    for _, pr in ipairs(q.progress or {}) do
      table.insert(out, "  - " .. tostring(pr.text) .. (pr.done and " (done)" or ""))
    end
  end
end

local function aiBags(s, out)
  local b = s.bags or {}
  table.insert(out, string.format("== BAG ITEMS (%s/%s slots free) ==", tostring(b.freeSlots), tostring(b.totalSlots)))
  local parts = {}
  for _, it in ipairs(b.items or {}) do
    table.insert(parts, tostring(it.name) .. idTag(it.id) .. (it.count and it.count > 1 and (" x" .. it.count) or ""))
  end
  for _, it in ipairs(b.equippable or {}) do table.insert(parts, tostring(it.name) .. idTag(it.id)) end
  table.insert(out, table.concat(parts, ", "))
  if s.bank and s.bank.items then
    local bp = {}
    for _, it in ipairs(s.bank.items) do table.insert(bp, tostring(it.name) .. idTag(it.id) .. (it.count and it.count > 1 and (" x" .. it.count) or "")) end
    table.insert(out, "== BANK (as of " .. tostring(s.bank.scannedAt) .. ") ==")
    table.insert(out, table.concat(bp, ", "))
  end
end

local function aiTalents(s, out)
  local t = s.talents
  if not t or not t.trees then return end
  table.insert(out, "== TALENTS (picked) ==")
  for _, tree in ipairs(t.trees) do
    local picked = {}
    for _, tal in ipairs(tree.talents or {}) do
      if tal.rank and tal.rank > 0 then table.insert(picked, tal.name .. " " .. tal.rank .. "/" .. tal.max) end
    end
    table.insert(out, string.format("%s (%s): %s", tostring(tree.name), tostring(tree.spent or 0), table.getn(picked) > 0 and table.concat(picked, ", ") or "-"))
  end
end

-- talent tooltip: drop name, rank line, tier-point requirement, "click to learn" and the next-rank block
local function talentDesc(lines)
  local out = {}
  for i = 2, table.getn(lines or {}) do
    local l = lines[i]
    if string.find(l, "^Next [Rr]ank") then break end
    if not (string.find(l, "^Rank %d") or string.find(l, "^Requires %d+ points") or string.find(l, "^Click to")) then
      table.insert(out, l)
    end
  end
  return (string.gsub(table.concat(out, " "), "%s+", " "))
end

local function aiTalentsFull(s, out)
  local t = s.talents
  if not t or not t.trees then return end
  table.insert(out, "== TALENT TREES (tier: name rank/max: effect) ==")
  for _, tree in ipairs(t.trees) do
    table.insert(out, string.format("-- %s (%s points)", tostring(tree.name), tostring(tree.spent or 0)))
    local byPos = {}
    for _, tal in ipairs(tree.talents or {}) do byPos[(tal.tier or 0) .. ":" .. (tal.col or 0)] = tal.name end
    for _, tal in ipairs(tree.talents or {}) do
      local req = ""
      if tal.requires then req = " [needs " .. tostring(byPos[tal.requires.tier .. ":" .. tal.requires.col]) .. "]" end
      table.insert(out, string.format("T%s %s %s/%s%s: %s", tostring(tal.tier), tostring(tal.name), tostring(tal.rank), tostring(tal.max), req, talentDesc(tal.tooltip)))
    end
  end
end

local function skillLevels(s, cats)
  local parts = {}
  for _, sk in ipairs(s.skills or {}) do
    if cats[sk.category or ""] and sk.max and sk.max > 1 then
      table.insert(parts, sk.name .. " " .. tostring(sk.rank) .. "/" .. tostring(sk.max))
    end
  end
  return table.concat(parts, ", ")
end

local function aiSpells(s, out)
  table.insert(out, "== SPELLS AND ABILITIES ==")
  table.insert(out, "Weapon/armor skills: " .. skillLevels(s, { ["Weapon Skills"] = true, ["Armor Proficiencies"] = true, ["Class Skills"] = true }))
  for _, tab in ipairs(s.spells or {}) do
    table.insert(out, "-- " .. tostring(tab.tab))
    local d = tab.details or {}
    for _, entry in ipairs(tab.spells or {}) do
      local _, _, base = string.find(entry, "^(.-) %(")
      local lines = d[base or entry] or d[entry]
      table.insert(out, entry .. ": " .. (lines and tipText(lines, true) or ""))
    end
  end
  local c = s.character or {}
  if c.pet and c.pet.spells then table.insert(out, "Pet abilities: " .. table.concat(c.pet.spells, ", ")) end
  local bt = s.professions and s.professions["Beast Training"]
  if bt and bt.recipes then
    local names = {}
    local seen = {}
    for _, r in ipairs(bt.recipes) do
      local n = tostring(r.name) .. (r.rank and (" (" .. r.rank .. ")") or "")
      if not seen[n] then seen[n] = true; table.insert(names, n) end
    end
    table.insert(out, "Beast Training (pet abilities the hunter can teach): " .. table.concat(names, ", "))
  end
end

local function aiProfessions(s, out)
  table.insert(out, "== PROFESSIONS ==")
  table.insert(out, "Levels: " .. skillLevels(s, { ["Professions"] = true, ["Secondary Skills"] = true }))
  table.insert(out, "Recipe difficulty: optimal=orange, medium=yellow, easy=green (skill-ups); grey recipes listed by name only.")
  for pname, P in pairs(s.professions or {}) do
   if pname ~= "Beast Training" then
    table.insert(out, string.format("-- %s %s/%s (recipes as of %s)", tostring(pname), tostring(P.rank), tostring(P.max), tostring(P.scannedAt)))
    local grey = {}
    for _, r in ipairs(P.recipes or {}) do
      if r.difficulty == "trivial" then
        table.insert(grey, tostring(r.name))
      else
        local rg = {}
        for _, g in ipairs(r.reagents or {}) do table.insert(rg, tostring(g.name) .. " x" .. tostring(g.count)) end
        local extra = ""
        if r.made then extra = extra .. ", makes " .. r.made end
        if r.readyAt then extra = extra .. ", cooldown until " .. r.readyAt end
        table.insert(out, string.format("%s%s (%s): %s%s", tostring(r.name), idTag(r.itemId), tostring(r.difficulty), table.concat(rg, ", "), extra))
      end
    end
    if table.getn(grey) > 0 then table.insert(out, "Grey: " .. table.concat(grey, ", ")) end
   end
  end
end

local function aiTrainers(s, out)
  if not s.trainers then return end
  table.insert(out, "== TRAINERS: NOT YET LEARNED ==")
  for tname, T in pairs(s.trainers) do
    local parts = {}
    for _, sv in ipairs(T.services or {}) do
      if sv.status ~= "used" then
        local p = tostring(sv.name) .. (sv.rank and (" (" .. sv.rank .. ")") or "")
        local req = {}
        if sv.reqLevel then table.insert(req, "lvl " .. sv.reqLevel) end
        if sv.requires then table.insert(req, sv.requires) end
        if sv.costCopper then table.insert(req, string.format("%.2fg", sv.costCopper / 10000)) end
        if table.getn(req) > 0 then p = p .. " [" .. table.concat(req, ", ") .. "]" end
        table.insert(parts, p)
      end
    end
    if table.getn(parts) > 0 then table.insert(out, tostring(tname) .. ": " .. table.concat(parts, "; ")) end
  end
end

local function aiReputation(s, out)
  local parts = {}
  for _, r in ipairs(s.reputation or {}) do
    table.insert(parts, tostring(r.name) .. " " .. tostring(r.standing) .. (r.progress and (" " .. r.progress) or ""))
  end
  if table.getn(parts) > 0 then
    table.insert(out, "== REPUTATION ==")
    table.insert(out, table.concat(parts, ", "))
  end
  if s.buffs and table.getn(s.buffs) > 0 then table.insert(out, "Buffs: " .. table.concat(s.buffs, ", ")) end
end

local AI_PARTS = {
  default = { aiCharacter, aiTalents, aiGear, aiQuests, aiBags },
  gear = { aiCharacter, aiGear, aiBags },
  quests = { aiCharacter, aiQuests, aiBags },
  talents = { aiCharacter, aiTalentsFull },
  spells = { aiCharacter, aiSpells },
  professions = { aiCharacter, aiProfessions, aiBags },
  all = { aiCharacter, aiTalentsFull, aiSpells, aiGear, aiQuests, aiBags, aiProfessions, aiTrainers, aiReputation },
}

local aiFrame, aiEdit, aiText, aiCurrent
local openAI
local AI_TABS = {
  { "default", "Summary" }, { "gear", "Gear" }, { "quests", "Quests" },
  { "talents", "Talents" }, { "spells", "Spells" }, { "professions", "Professions" }, { "all", "All" },
}
local aiTabButtons = {}
local function showAIText(text)
  if not aiFrame then
    aiFrame = CreateFrame("Frame", "OctoAIFrame", UIParent)
    aiFrame:SetWidth(670); aiFrame:SetHeight(500)
    aiFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    aiFrame:SetFrameStrata("DIALOG")
    aiFrame:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32,
      insets = { left = 11, right = 12, top = 12, bottom = 11 } })
    aiFrame:EnableMouse(true); aiFrame:SetMovable(true)
    aiFrame:RegisterForDrag("LeftButton")
    aiFrame:SetScript("OnDragStart", function() this:StartMoving() end)
    aiFrame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    table.insert(UISpecialFrames, "OctoAIFrame")

    local title = aiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", aiFrame, "TOP", 0, -16)
    title:SetText("OctoAI: copy, then paste into your AI chat")

    local prev
    for i, tab in ipairs(AI_TABS) do
      local key = tab[1]
      local b = CreateFrame("Button", "OctoAITab" .. i, aiFrame, "UIPanelButtonTemplate")
      b:SetWidth(86); b:SetHeight(22)
      if prev then b:SetPoint("LEFT", prev, "RIGHT", 2, 0) else b:SetPoint("TOPLEFT", aiFrame, "TOPLEFT", 22, -36) end
      b:SetText(tab[2])
      b:SetScript("OnClick", function() openAI(key) end)
      aiTabButtons[key] = b
      prev = b
    end

    local scroll = CreateFrame("ScrollFrame", "OctoAIScroll", aiFrame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", aiFrame, "TOPLEFT", 20, -66)
    scroll:SetPoint("BOTTOMRIGHT", aiFrame, "BOTTOMRIGHT", -40, 48)

    aiEdit = CreateFrame("EditBox", "OctoAIEdit", scroll)
    aiEdit:SetMultiLine(true)
    aiEdit:SetMaxLetters(0)
    aiEdit:SetAutoFocus(false)
    aiEdit:SetFontObject(ChatFontNormal)
    aiEdit:SetWidth(600); aiEdit:SetHeight(375)
    aiEdit:SetScript("OnEscapePressed", function() aiFrame:Hide() end)
    -- read-only: undo any typing, keep the text selected
    aiEdit:SetScript("OnTextChanged", function()
      if aiText and this:GetText() ~= aiText then this:SetText(aiText); this:HighlightText() end
      scroll:UpdateScrollChildRect()
    end)
    aiEdit:SetScript("OnCursorChanged", function()
      if ScrollingEdit_OnCursorChanged then ScrollingEdit_OnCursorChanged(arg1, arg2, arg3, arg4) end
    end)
    aiEdit:SetScript("OnUpdate", function() if ScrollingEdit_OnUpdate then ScrollingEdit_OnUpdate() end end)
    scroll:SetScrollChild(aiEdit)

    local copy = CreateFrame("Button", "OctoAICopyButton", aiFrame, "UIPanelButtonTemplate")
    copy:SetWidth(110); copy:SetHeight(22)
    copy:SetPoint("BOTTOMLEFT", aiFrame, "BOTTOMLEFT", 20, 16)
    copy:SetScript("OnClick", function()
      -- CopyToClipboard comes from ClassicAPI.dll; without it, select the text for Ctrl+C
      if type(CopyToClipboard) == "function" and aiText then
        local ok, err = pcall(CopyToClipboard, aiText)
        if ok then
          msg("copied " .. string.len(aiText) .. " characters, paste it into your AI chat")
          aiFrame:Hide()
          return
        end
        msg("|cffffaa00copy failed:|r " .. tostring(err) .. ", use Ctrl+C instead")
      end
      aiEdit:SetFocus(); aiEdit:HighlightText()
    end)

    local sel = CreateFrame("Button", nil, aiFrame, "UIPanelButtonTemplate")
    sel:SetWidth(110); sel:SetHeight(22)
    sel:SetPoint("LEFT", copy, "RIGHT", 8, 0)
    sel:SetText("Select all")
    sel:SetScript("OnClick", function() aiEdit:SetFocus(); aiEdit:HighlightText() end)

    local close = CreateFrame("Button", nil, aiFrame, "UIPanelButtonTemplate")
    close:SetWidth(90); close:SetHeight(22)
    close:SetPoint("BOTTOMRIGHT", aiFrame, "BOTTOMRIGHT", -20, 16)
    close:SetText("Close")
    close:SetScript("OnClick", function() aiFrame:Hide() end)

    local size = aiFrame:CreateFontString("OctoAISize", "OVERLAY", "GameFontHighlightSmall")
    size:SetPoint("BOTTOM", aiFrame, "BOTTOM", 0, 22)
  end
  aiText = text
  aiEdit:SetText(text)
  for k, b in pairs(aiTabButtons) do
    if k == aiCurrent then b:LockHighlight() else b:UnlockHighlight() end
  end
  getglobal("OctoAICopyButton"):SetText("Copy")
  if type(CopyToClipboard) == "function" then
    getglobal("OctoAICopyButton"):Enable()
  else
    getglobal("OctoAICopyButton"):Disable() -- needs ClassicAPI.dll; use Select all + Ctrl+C
  end
  getglobal("OctoAISize"):SetText(string.format("%d characters", string.len(text)))
  aiFrame:Show()
  aiEdit:SetFocus()
  aiEdit:HighlightText()
end

openAI = function(arg)
  arg = string.lower(arg or "")
  if arg == "" then arg = "default" end
  if arg == "skills" then arg = "professions" end
  if arg == "bags" then arg = "default" end
  local parts = AI_PARTS[arg]
  if not parts then
    msg("/octoai [gear|quests|talents|spells|professions|all]  (no argument = summary)")
    return
  end
  if UnitAffectingCombat("player") then msg("not in combat, please"); return end
  aiCurrent = arg
  local ok, snap = pcall(buildSnapshot, "octoai", false)
  if not ok then msg("|cffff5555failed:|r " .. tostring(snap)); return end
  local out = { AI_HEADER, "Exported " .. tostring(snap.exportedAt), "" }
  for _, fn in ipairs(parts) do
    local ok2, err = pcall(fn, snap, out)
    if not ok2 then table.insert(out, "(section failed: " .. tostring(err) .. ")") end
    table.insert(out, "")
  end
  table.insert(out, "My question:")
  local text = table.concat(out, "\n")
  text = string.gsub(text, "|", "/")
  showAIText(text)
end

SLASH_OCTOAI1 = "/octoai"
SlashCmdList["OCTOAI"] = function(input)
  local a = string.gsub(input or "", "^%s+", "")
  a = string.gsub(a, "%s+$", "")
  openAI(a)
end

---------------------------------------------------------------------------
-- Slash command
---------------------------------------------------------------------------
SLASH_OCTOEXPORT1 = "/octo"
SlashCmdList["OCTOEXPORT"] = function(input)
  local cmd = string.lower(input or "")
  cmd = string.gsub(cmd, "^%s+", "")
  cmd = string.gsub(cmd, "%s+$", "")
  if cmd == "" or cmd == "export" then
    if UnitAffectingCombat("player") then
      msg("in combat, will export when combat ends.")
      for _, s in ipairs(ALL_SECTIONS) do stale[s] = true end
      fastDue = GetTime(); fastFirst = GetTime(); lastReason = "manual"
      return
    end
    doExport("manual", false, true)
  elseif cmd == "auto on" then
    db.auto = true; msg("auto export ON")
  elseif cmd == "auto off" then
    db.auto = false; fastDue, slowDue = nil, nil; msg("auto export OFF")
  elseif cmd == "verbose" then
    db.verbose = not db.verbose; msg("verbose " .. (db.verbose and "ON" or "OFF"))
  elseif cmd == "status" then
    msg("v" .. VERSION .. ", auto " .. (db.auto and "ON" or "OFF")
      .. ", WriteFile " .. (type(WriteFile) == "function" and "available" or "MISSING")
      .. ", quest IDs " .. (hasQuestIDs() and "ClassicAPI" or "none")
      .. ", professions " .. (function() local n = 0; for _ in pairs(db.professions or {}) do n = n + 1 end; return n end)()
      .. ", items cached " .. itemCacheCount()
      .. ", last export " .. tostring(db.lastExport) .. (db.lastMs and string.format(" (%d ms)", db.lastMs) or ""))
  else
    msg("/octo  - export now")
    msg("/octo auto on|off  - auto export on changes (default on)")
    msg("/octo verbose  - show a chat line on every auto export")
    msg("/octo status")
    msg("/octoai [gear|quests|talents|spells|professions|all]  - copyable text for any AI chat")
    msg("professions: open a profession window once; recipes are saved and exported automatically")
  end
end
