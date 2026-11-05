-- Pint's Threat Plates: enemy nameplates in the Pint's Frames style.
--   Name above, health bar with "numbers | %" inside, level on the right, threat % (and arrows) on the left,
--   white edge on your target. Health bar colour follows threat:
--     not tanking: low colour (far below the top of the threat list) -> middle (about to pull) -> high (it's on you)
--     tanking:     safe colour (comfortable lead) -> warning (someone is catching up - taunt) ; lost colour = taunt now
--   Everything (what shows, colours, sizes, stacking) is set in the options window: /pn
--   Friendly units keep Blizzard's own plates.
local ADDON = ...
-- Compatibility: WoW Forever runs on the modern game client, where these older functions moved or were renamed.
local IsAddOnLoaded = IsAddOnLoaded or (C_AddOns and C_AddOns.IsAddOnLoaded)

local PP = {}
_G.PintsPlates = PP

local DEFAULT_COLORS = {
	low = { 0.10, 0.80, 0.10 }, mid = { 1.00, 0.85, 0.10 }, high = { 0.90, 0.10, 0.10 },
	safe = { 0.50, 0.03, 0.03 }, warn = { 1.00, 0.85, 0.10 }, lost = { 1.00, 0.50, 0.00 },
	hostile = { 0.70, 0.22, 0.22 }, neutral = { 0.85, 0.75, 0.15 }, tapped = { 0.50, 0.50, 0.50 },
}
local DEFAULTS = {
	tank = "auto", tankFlip = false, steps = 10,
	width = 150, height = 20, nameSize = 12, textSize = 10,
	showName = true, showLevel = true, healthText = "both", showThreat = true, showArrows = true, showMarks = true, targetEdge = true, showQuest = true,
	stack = true, onScreen = true, spacing = 1.1, range = 41,
	minimap = {},
}
local db

local function Print(msg) print("|cffd4a017Pint's|r Threat Plates: " .. msg) end

local function MakeFont(name, size)
	local f = _G[name] or CreateFont(name)
	local file = GameFontHighlightSmall:GetFont()
	f:SetFont(file, size, "OUTLINE"); f:SetShadowOffset(0, 0)
end
MakeFont("PintsPlatesName", 10)
MakeFont("PintsPlatesBar", 8)
MakeFont("PintsPlatesLevel", 14)

---------------------------------------------------------------- colours
local function C(key) return (db and db.colors and db.colors[key]) or DEFAULT_COLORS[key] end
local function Mix(a, b, t) return a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t end
local function Step(t)
	t = math.max(0, math.min(1, t))
	local n = db.steps or 10
	if n <= 0 then return t end                      -- smooth
	return math.floor(t * n + 0.0001) / n
end
-- not tanking: t from 0 to 1 -> low -> mid -> high
local function ThreatShade(t)
	t = Step(t)
	if t <= 0.5 then return Mix(C("low"), C("mid"), t / 0.5) end
	return Mix(C("mid"), C("high"), (t - 0.5) / 0.5)
end
-- tanking: how close the next person is (0..1) -> safe while comfortable, warning as they close in
local function TankShade(closeness)
	local t = Step((closeness - 0.5) / 0.5)          -- under half your threat counts as fully safe
	if db.tankFlip then
		-- flipped: the not-tanking colours turned round - low (green) = solidly yours, high (red) = about to lose it
		if t <= 0.5 then return Mix(C("low"), C("mid"), t / 0.5) end
		return Mix(C("mid"), C("high"), (t - 0.5) / 0.5)
	end
	return Mix(C("safe"), C("warn"), t)
end
local function LostColor() if db.tankFlip then return unpack(C("high")) end return unpack(C("lost")) end

---------------------------------------------------------------- tank detection
local TANK_AURAS = {
	[71] = true,                                     -- Defensive Stance
	[5487] = true, [9634] = true,                    -- Bear Form, Dire Bear Form
	[25780] = true,                                  -- Righteous Fury
	[407627] = true,                                 -- Righteous Fury (Season of Discovery)
}
local TANK_FORMS = { [5] = true, [8] = true, [18] = true }   -- bear, dire bear, Defensive Stance (modern client's form ids)
local tankKnown = false
local function Hidden(v) return type(issecretvalue) == "function" and issecretvalue(v) end
-- true / false, or nil when the game won't say right now (buffs are hidden in combat on the modern client)
local function ReadTank()
	if UnitBuff then
		for i = 1, 40 do
			local name, _, _, _, _, _, _, _, _, id = UnitBuff("player", i)
			if not name then break end
			if TANK_AURAS[id] then return true end
		end
		return false
	end
	local form = GetShapeshiftFormID and GetShapeshiftFormID()
	if form and not Hidden(form) and TANK_FORMS[form] then return true end
	if not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then return nil end
	for id in pairs(TANK_AURAS) do
		local ok, a = pcall(C_UnitAuras.GetPlayerAuraBySpellID, id)
		if not ok or Hidden(a) then return nil end
		if a then return true end
	end
	if InCombatLockdown() then return nil end   -- "no aura" in combat may just mean hidden
	return false
end
local function IsTank()
	if db.tank == "on" then return true elseif db.tank == "off" then return false end
	local r = ReadTank()
	if r ~= nil then tankKnown = r end
	return tankKnown
end

-- everyone in your group (and their pets) who could hold threat
local function GroupUnits()
	local out = { "pet" }
	if IsInRaid() then
		for i = 1, 40 do out[#out + 1] = "raid" .. i; out[#out + 1] = "raidpet" .. i end
	else
		for i = 1, 4 do out[#out + 1] = "party" .. i; out[#out + 1] = "partypet" .. i end
	end
	return out
end
-- the modern game client (WoW Forever) keeps some numbers "secret": they can be drawn but not compared
local SECRET = type(issecretvalue) == "function"
local function IsSecret(v) return SECRET and issecretvalue(v) end
local function Known(v) if IsSecret(v) then return nil end return v end
-- UnitDetailedThreatSituation, with anything the game hides treated as "no information"
local function Threat(a, b)
	local tanking, status, scaled, raw, value = UnitDetailedThreatSituation(a, b)
	if IsSecret(tanking) or IsSecret(status) or IsSecret(scaled) or IsSecret(value) then return nil end
	return tanking, status, scaled, raw, value
end

local function TopOther(unit)
	local other = 0
	for _, u in ipairs(GroupUnits()) do
		if UnitExists(u) and not Known(UnitIsUnit(u, "player")) then
			local _, _, _, _, v = Threat(u, unit)
			if v and v > other then other = v end
		end
	end
	return other
end

-- returns r, g, b for a mob, or nil when nobody has threat on it yet
local function ThreatColor(unit)
	if not UnitDetailedThreatSituation then return nil end
	local tanking, status, scaled, _, mine = Threat("player", unit)
	if status == nil and not Known(UnitAffectingCombat(unit)) then return nil end
	if IsTank() then
		if tanking then
			local closeness = (mine and mine > 0) and (TopOther(unit) / mine) or 0
			return TankShade(closeness)
		end
		if status ~= nil then return LostColor() end
		return nil
	end
	if tanking then return unpack(C("high")) end
	if scaled then return ThreatShade(scaled / 100) end
	return nil
end

-- your threat as % of pulling it (100 = it's on you)
local function ThreatPct(unit)
	if not UnitDetailedThreatSituation then return nil end
	local _, status, scaled = Threat("player", unit)
	if status == nil then return nil end
	return scaled
end

-- one number per mob for comparing them: your threat as % of the top spot (0-100); when it's on you,
-- 100 plus how far ahead of the next person you are (up to 200)
local function ThreatScore(unit)
	if not UnitDetailedThreatSituation then return nil end
	local tanking, status, scaled, _, mine = Threat("player", unit)
	if status == nil then return nil end
	if tanking then
		local lead = (mine and mine > 0) and (1 - math.min(1, TopOther(unit) / mine)) or 1
		return 100 + lead * 100
	end
	return scaled or 0
end

local function ReactionColor(unit)
	if UnitIsTapDenied and UnitIsTapDenied(unit) then return unpack(C("tapped")) end
	if UnitIsPlayer(unit) then
		local _, cls = UnitClass(unit)
		local c = Known(cls) and RAID_CLASS_COLORS[cls]
		if c then return c.r, c.g, c.b end
	end
	local r = Known(UnitReaction(unit, "player")) or 2
	if r == 4 then return unpack(C("neutral")) end
	return unpack(C("hostile"))
end

---------------------------------------------------------------- the plate
local active, built = {}, {}   -- unit -> our frame ; every frame we made

local function Short(v) if v >= 10000 then return ("%.1fk"):format(v / 1000) end return tostring(v) end

-- sizes and what's shown; run on every plate whenever an option changes
local function Layout(f)
	f:SetSize(db.width, db.height)
	-- centre the whole plate (name + bar) on the plate box so neighbours stack cleanly
	local nameH = db.showName and (db.nameSize + 2) or 0
	f:ClearAllPoints(); f:SetPoint("CENTER", f:GetParent(), "CENTER", 0, -nameH / 2)
	f.name:SetWidth(db.width + 40)
	f.name:SetShown(db.showName); f.level:SetShown(db.showLevel); f.rank:SetShown(db.showThreat)
	f.text:SetShown(db.healthText ~= "none")
	if not db.showArrows then f.arrow:Hide() end
	if not db.showMarks then f.mark:Hide() end
	if not db.showQuest then f.quest:Hide() end
	local qs = math.max(22, db.height + 6); f.quest:SetSize(qs, qs)
	f.quest:ClearAllPoints()
	if db.showLevel then f.quest:SetPoint("LEFT", f.level, "RIGHT", 1, 0) else f.quest:SetPoint("LEFT", f, "RIGHT", 2, 0) end
	f.arrow:ClearAllPoints()
	if db.showThreat then f.arrow:SetPoint("RIGHT", f.rank, "LEFT", -1, 0) else f.arrow:SetPoint("RIGHT", f, "LEFT", -2, 0) end
	f.mark:ClearAllPoints()
	if db.showName then f.mark:SetPoint("RIGHT", f.name, "LEFT", -2, 0) else f.mark:SetPoint("BOTTOM", f, "TOP", 0, 2) end
end

local function Build(plate)
	local f = CreateFrame("Frame", nil, plate)
	f:SetFrameLevel(plate:GetFrameLevel() + 2)
	f.hp = CreateFrame("StatusBar", nil, f, "BackdropTemplate")
	f.hp:SetAllPoints()
	f.hp:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	f.hp:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
	f.hp:SetBackdropColor(0, 0, 0, 0.6)
	f.hp:SetBackdropBorderColor(0, 0, 0, 1)
	f.text = f.hp:CreateFontString(nil, "OVERLAY", "PintsPlatesBar"); f.text:SetPoint("CENTER", 0, 0)
	f.name = f:CreateFontString(nil, "OVERLAY", "PintsPlatesName")
	f.name:SetPoint("BOTTOM", f, "TOP", 0, 2); f.name:SetWordWrap(false)
	f.level = f:CreateFontString(nil, "OVERLAY", "PintsPlatesLevel")
	f.level:SetPoint("LEFT", f, "RIGHT", 3, 0)
	f.rank = f:CreateFontString(nil, "OVERLAY", "PintsPlatesName")
	f.rank:SetPoint("RIGHT", f, "LEFT", -3, 0)
	-- arrow beside the threat %: red up = your highest-threat mob, green down = your lowest
	f.arrow = f:CreateTexture(nil, "OVERLAY")
	f.arrow:SetSize(12, 12)
	f.arrow:SetTexture("Interface\\Buttons\\Arrow-Up-Up"); f.arrow:SetDesaturated(true); f.arrow:Hide()
	f.mark = f:CreateTexture(nil, "OVERLAY")
	f.mark:SetSize(14, 14)
	f.mark:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons"); f.mark:Hide()
	-- quest mob: something you still need to kill or loot for a quest
	f.quest = f:CreateTexture(nil, "OVERLAY")
	f.quest:SetSize(14, 14)
	f.quest:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon"); f.quest:Hide()
	plate.PintsPlate = f
	built[#built + 1] = f
	Layout(f)
	return f
end

---------------------------------------------------------------- quest mobs
-- a mob counts when its tooltip lists a quest objective you haven't finished (kill or collect), or its name is in
-- an unfinished "... slain: x/y" line of your quest log
local scanTip
local function Unfinished(text)
	if type(text) ~= "string" or IsSecret(text) then return false end
	local a, b = text:match("(%d+)%s*/%s*(%d+)")
	return a and tonumber(a) < tonumber(b)
end
local function FromTooltipInfo(u)
	if not (C_TooltipInfo and C_TooltipInfo.GetUnit and Enum and Enum.TooltipDataLineType) then return nil end
	local OBJ = Enum.TooltipDataLineType.QuestObjective
	local ok, data = pcall(C_TooltipInfo.GetUnit, u)
	if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
	for _, l in ipairs(data.lines) do
		if OBJ and Known(l.type) == OBJ and Known(l.completed) ~= true then return true end
	end
	return false
end
local function FromTooltip(u)
	if not scanTip then
		scanTip = CreateFrame("GameTooltip", "PintsPlatesScanTip", nil, "GameTooltipTemplate")
		scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
	end
	scanTip:ClearLines()
	if not pcall(scanTip.SetUnit, scanTip, u) then return false end
	for i = 2, scanTip:NumLines() do
		local fs = _G["PintsPlatesScanTipTextLeft" .. i]
		if fs and Unfinished(fs:GetText()) then return true end
	end
	return false
end
local function FromLog(name)
	if not (GetNumQuestLogEntries and GetQuestLogTitle and GetQuestLogLeaderBoard) then return false end
	for i = 1, GetNumQuestLogEntries() or 0 do
		local _, _, _, header = GetQuestLogTitle(i)
		if not header then
			for j = 1, (GetNumQuestLeaderBoards and GetNumQuestLeaderBoards(i)) or 0 do
				local text, kind, done = GetQuestLogLeaderBoard(j, i)
				if not done and kind == "monster" and type(text) == "string" and text:find(name, 1, true) then return true end
			end
		end
	end
	return false
end
local function IsQuestMob(u)
	if UnitIsPlayer(u) or Known(UnitIsDead(u)) then return false end
	local r = FromTooltipInfo(u)
	if r == nil then r = FromTooltip(u) end
	if r then return true end
	local name = Known(UnitName(u))
	return name and FromLog(name) or false
end
local function QuestIcon(f)
	if not db.showQuest or not f.unit then f.quest:Hide(); return end
	local ok, q = pcall(IsQuestMob, f.unit)
	f.quest:SetShown(ok and q and true or false)
end
PP.QuestIcon = QuestIcon

local fmtOK = {}       -- which text formats the game accepts with secret numbers (learned once)
local function SecretText(fs, fmt, ...)
	if fmtOK[fmt] == false then return false end
	local ok = pcall(fs.SetFormattedText, fs, fmt, ...)
	fmtOK[fmt] = ok
	return ok
end
local function Abbrev(v) if AbbreviateNumbers then return AbbreviateNumbers(v) end return v end
-- secret health: the game draws the bar and the text, we don't touch the numbers
local function SecretHealth(f, u, hp, max)
	f.hp:SetMinMaxValues(0, max); f.hp:SetValue(hp)
	local mode = db.healthText
	if mode == "none" then return end
	if UnitIsDeadOrGhost(u) then f.text:SetText("Dead"); return end
	local pct = UnitHealthPercent and CurveConstants and CurveConstants.ScaleTo100 and UnitHealthPercent(u, true, CurveConstants.ScaleTo100)
	local a, b = Abbrev(hp), Abbrev(max)
	if mode == "percent" then
		if not (pct and SecretText(f.text, "%.0f%%", pct)) then SecretText(f.text, "%s", a) end
	elseif mode == "numbers" then SecretText(f.text, "%s/%s", a, b)
	elseif not (pct and SecretText(f.text, "%s/%s | %.0f%%", a, b, pct)) then SecretText(f.text, "%s/%s", a, b) end
end

local function Refresh(f)
	local u = f.unit
	if not u or not UnitExists(u) then return end
	-- health text
	local hp, max = UnitHealth(u), UnitHealthMax(u)
	if IsSecret(hp) or IsSecret(max) then SecretHealth(f, u, hp, max) else
	if max <= 0 then max = 1 end
	f.hp:SetMinMaxValues(0, max); f.hp:SetValue(hp)
	local pct = math.floor(hp / max * 100 + 0.5) .. "%"
	local mode = db.healthText
	if mode ~= "none" then
		if UnitIsDeadOrGhost(u) then f.text:SetText("Dead")
		elseif mode == "percent" or (max == 100 and not UnitPlayerControlled(u)) then f.text:SetText(pct)   -- the game only gives a % for some mobs
		elseif mode == "numbers" then f.text:SetText(Short(hp) .. "/" .. Short(max))
		else f.text:SetText(Short(hp) .. "/" .. Short(max) .. " | " .. pct) end
	end
	end
	-- colour: threat in a fight, otherwise reaction
	local r, g, b = ThreatColor(u)
	f.score = ThreatScore(u)
	local tp = db.showThreat and ThreatPct(u)
	if tp then
		f.rank:SetText(math.floor(tp + 0.5) .. "%")
		if r then f.rank:SetTextColor(r, g, b) else f.rank:SetTextColor(1, 1, 1) end
	elseif db.showThreat then
		f.rank:SetText("")
	end
	if not r then r, g, b = ReactionColor(u) end
	f.hp:SetStatusBarColor(r, g, b)
	-- your target gets a white edge
	if db.targetEdge and Known(UnitIsUnit(u, "target")) then f.hp:SetBackdropBorderColor(1, 1, 1, 1) else f.hp:SetBackdropBorderColor(0, 0, 0, 1) end
	-- raid marker
	local idx = db.showMarks and Known(GetRaidTargetIndex(u))
	if idx then SetRaidTargetIconTexture(f.mark, idx); f.mark:Show() else f.mark:Hide() end
end

local function Setup(f)
	local u = f.unit
	-- WoW Forever names have a second name ("Pint Sunders"), which UnitName leaves off
	local ok, full = false, nil
	if GetUnitName then ok, full = pcall(GetUnitName, u, false) end
	f.name:SetText((ok and full) or UnitName(u) or "")
	if UnitIsPlayer(u) then
		local _, cls = UnitClass(u)
		local c = Known(cls) and RAID_CLASS_COLORS[cls]
		if c then f.name:SetTextColor(c.r, c.g, c.b) else f.name:SetTextColor(1, 1, 1) end
	else
		f.name:SetTextColor(1, 1, 1)
	end
	local lv = Known(UnitLevel(u)) or 0
	local cl = UnitClassification and Known(UnitClassification(u))
	local elite = (cl == "elite" or cl == "rareelite" or cl == "worldboss") and "+" or ""
	if lv <= 0 then f.level:SetText("??"); f.level:SetTextColor(1, 0.1, 0.1)
	else
		f.level:SetText(lv .. elite)
		local c = GetQuestDifficultyColor and GetQuestDifficultyColor(lv)
		if c then f.level:SetTextColor(c.r, c.g, c.b) else f.level:SetTextColor(1, 0.82, 0) end
	end
	QuestIcon(f)
	Refresh(f)
end

-- Blizzard's plate stays alive underneath; on enemies everything it draws goes see-through. Rather than trust
-- one frame name, every child of the plate that isn't ours is faded, and kept faded if the game tries to show it.
local function Fade(child, hide)
	if not child.ppHooked then
		child.ppHooked = true
		hooksecurefunc(child, "SetAlpha", function(self, a)
			if self.ppHide and a and a > 0 and not self.ppBusy then self.ppBusy = true; self:SetAlpha(0); self.ppBusy = nil end
		end)
	end
	child.ppHide = hide
	child.ppBusy = true; child:SetAlpha(hide and 0 or 1); child.ppBusy = nil
end
-- a few of Blizzard's plate pieces (highlights, cast bar bits) are set to ignore their parent's transparency,
-- so fading the plate doesn't reach them; find those and fade them directly
local function Sweep(frame, hide, depth)
	if depth > 4 or (frame.IsForbidden and frame:IsForbidden()) then return end
	-- (on the modern client the answer can be "secret": then leave that piece alone)
	for _, r in ipairs({ frame:GetRegions() }) do
		if r.IsIgnoringParentAlpha and Known(r:IsIgnoringParentAlpha()) then r:SetAlpha(hide and 0 or 1) end
	end
	for _, c in ipairs({ frame:GetChildren() }) do
		if c.IsIgnoringParentAlpha and Known(c:IsIgnoringParentAlpha()) then Fade(c, hide) end
		Sweep(c, hide, depth + 1)
	end
end
local function HideBlizzard(plate, hide)
	for _, child in ipairs({ plate:GetChildren() }) do
		if child ~= plate.PintsPlate and not (child.IsForbidden and child:IsForbidden()) then Fade(child, hide); Sweep(child, hide, 1) end
	end
	for _, r in ipairs({ plate:GetRegions() }) do r:SetAlpha(hide and 0 or 1) end
end

local function Added(unit)
	local plate = C_NamePlate.GetNamePlateForUnit(unit)
	if not plate or (plate.IsForbidden and plate:IsForbidden()) then return end
	if not UnitCanAttack("player", unit) then
		HideBlizzard(plate, false)
		if plate.PintsPlate then plate.PintsPlate:Hide() end
		return
	end
	local f = plate.PintsPlate or Build(plate)
	f.unit = unit
	HideBlizzard(plate, true)
	C_Timer.After(0, function() if plate.PintsPlate == f and f.unit == unit then HideBlizzard(plate, true) end end)
	f:Show()
	active[unit] = f
	Setup(f)
end

local function Removed(unit)
	local f = active[unit]
	if f then f:Hide(); f.unit = nil; active[unit] = nil end
end

---------------------------------------------------------------- stacking, range, sizes
-- Blizzard's own "stacking" mode keeps plates from overlapping. Each plate's stacking box is sized to the whole of
-- our plate (name + bar), so neighbours sit just clear of each other.
function PP.Stacking()
	if InCombatLockdown() then PP.pending = true; return end
	pcall(SetCVar, "nameplateMotion", db.stack and 1 or 0)
	pcall(SetCVar, "nameplateOverlapV", db.spacing or 1.1)
	pcall(SetCVar, "nameplateMaxDistance", db.range or 41)
	if db.onScreen then
		pcall(SetCVar, "nameplateOtherTopInset", 0.08); pcall(SetCVar, "nameplateLargeTopInset", 0.1)
		pcall(SetCVar, "nameplateOtherBottomInset", 0.1); pcall(SetCVar, "nameplateLargeBottomInset", 0.15)
	else
		pcall(SetCVar, "nameplateOtherTopInset", -1); pcall(SetCVar, "nameplateLargeTopInset", -1)
		pcall(SetCVar, "nameplateOtherBottomInset", -1); pcall(SetCVar, "nameplateLargeBottomInset", -1)
	end
	local h = db.height + (db.showName and (db.nameSize + 4) or 2) + 4
	if C_NamePlate and C_NamePlate.SetNamePlateEnemySize then pcall(C_NamePlate.SetNamePlateEnemySize, db.width + 16, h) end
end

function PP.ApplyAll()
	MakeFont("PintsPlatesName", db.nameSize)
	MakeFont("PintsPlatesBar", db.textSize)
	MakeFont("PintsPlatesLevel", math.max(db.nameSize + 4, db.height - 2))   -- level beside the bar: sized to the bar
	for _, f in ipairs(built) do Layout(f) end
	for _, f in pairs(active) do Setup(f) end
	PP.Stacking()
end

---------------------------------------------------------------- events and refresh
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED"); ev:RegisterEvent("PLAYER_LOGIN"); ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("NAME_PLATE_UNIT_ADDED"); ev:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
ev:RegisterEvent("UNIT_FACTION"); ev:RegisterEvent("RAID_TARGET_UPDATE"); ev:RegisterEvent("PLAYER_TARGET_CHANGED")
ev:RegisterEvent("QUEST_LOG_UPDATE")
local questPending
ev:SetScript("OnEvent", function(_, e, a1)
	if e == "ADDON_LOADED" and a1 == ADDON then
		PintsPlatesDB = PintsPlatesDB or {}
		db = PintsPlatesDB
		for k, v in pairs(DEFAULTS) do if db[k] == nil then db[k] = (type(v) == "table") and {} or v end end
		db.colors = db.colors or {}
		if not db.v2 then db.v2 = true; if (db.spacing or 0) < 1.1 then db.spacing = 1.1 end end   -- stop plates overlapping
		if not db.v3 then          -- bigger plates: move anyone still on the old default sizes up to the new ones
			db.v3 = true
			if db.width == 112 then db.width = 150 end
			if db.height == 10 then db.height = 14 end
			if db.nameSize == 10 then db.nameSize = 12 end
			if db.textSize == 8 then db.textSize = 10 end
		end
		if not db.v4 then db.v4 = true; if db.height == 14 or db.height == 10 then db.height = 20 end end   -- taller bars
		PP.db = db
	elseif e == "PLAYER_LOGIN" then
		PP.ApplyAll()
		if PP.BuildMinimap then PP.BuildMinimap() end
		if PP.ThreatPlatesLoaded() then Print("Threat Plates is on too - /pn off-threatplates to switch it off, then /reload.") end
		if not db.rangeNoted then
			db.rangeNoted = true
			C_Timer.After(3, function() Print("nameplates reach " .. tostring(GetCVar("nameplateMaxDistance")) .. " yards (the most this game allows). /pn for options.") end)
		end
	elseif e == "PLAYER_REGEN_ENABLED" then if PP.pending then PP.pending = nil; PP.Stacking() end
	elseif e == "NAME_PLATE_UNIT_ADDED" then Added(a1)
	elseif e == "NAME_PLATE_UNIT_REMOVED" then Removed(a1)
	elseif e == "UNIT_FACTION" then if a1 and a1:find("^nameplate") then Removed(a1); Added(a1) end
	elseif e == "QUEST_LOG_UPDATE" then
		-- fires in bursts; look again once it settles
		if not questPending then
			questPending = true
			C_Timer.After(0.5, function() questPending = nil; for _, f in pairs(active) do QuestIcon(f) end end)
		end
	else for _, f in pairs(active) do Refresh(f) end end
end)

function PP.Arrows()
	local hi, lo, n = nil, nil, 0
	if db.showArrows then
		for _, f in pairs(active) do
			if f.score then
				n = n + 1
				if not hi or f.score > hi.score then hi = f end
				if not lo or f.score < lo.score then lo = f end
			end
		end
	end
	for _, f in pairs(active) do
		if n >= 2 and f == hi and hi.score ~= lo.score then
			f.arrow:SetTexture("Interface\\Buttons\\Arrow-Up-Up"); f.arrow:SetVertexColor(1, 0.15, 0.15); f.arrow:Show()
		elseif n >= 2 and f == lo and hi.score ~= lo.score then
			f.arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up"); f.arrow:SetVertexColor(0.2, 1, 0.2); f.arrow:Show()
		else
			f.arrow:Hide()
		end
	end
end

local tick = 0
ev:SetScript("OnUpdate", function(_, dt)
	tick = tick + dt
	if tick < 0.15 then return end
	tick = 0
	for _, f in pairs(active) do Refresh(f) end
	PP.Arrows()
end)

---------------------------------------------------------------- Threat Plates
local OTHERS = { "TidyPlates_ThreatPlates", "TidyPlates", "ThreatPlates" }
local function Loaded(a) if C_AddOns and C_AddOns.IsAddOnLoaded then return C_AddOns.IsAddOnLoaded(a) end return IsAddOnLoaded and IsAddOnLoaded(a) end
function PP.ThreatPlatesLoaded() for _, a in ipairs(OTHERS) do if Loaded(a) then return true end end return false end
function PP.OffThreatPlates()
	local off = (C_AddOns and C_AddOns.DisableAddOn) or DisableAddOn
	for _, a in ipairs(OTHERS) do pcall(off, a) end
	Print("TidyPlates Threat Plates switched off for every character - /reload to finish.")
end

---------------------------------------------------------------- options window
local opt
local refreshers = {}
local function Changed() PP.ApplyAll(); for _, fn in ipairs(refreshers) do fn() end end

local function Head(parent, x, y, text)
	local h = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal"); h:SetPoint("TOPLEFT", x, y); h:SetText(text)
	return h
end
local function Check(parent, x, y, label, key, tip)
	local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate"); c:SetSize(22, 22); c:SetPoint("TOPLEFT", x, y)
	local t = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); t:SetPoint("LEFT", c, "RIGHT", 2, 0); t:SetText(label)
	c:SetScript("OnClick", function(self) db[key] = self:GetChecked() and true or false; Changed() end)
	if tip then
		c:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:AddLine(label); GameTooltip:AddLine(tip, 1, 1, 1, true); GameTooltip:Show() end)
		c:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end
	refreshers[#refreshers + 1] = function() c:SetChecked(db[key] and true or false) end
	return c
end
-- a "< value >" chooser that cycles through choices
local function Choice(parent, x, y, label, key, choices)
	local t = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); t:SetPoint("TOPLEFT", x, y - 4); t:SetText(label)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate"); b:SetSize(150, 20); b:SetPoint("TOPLEFT", x + 110, y)
	local function label_() for _, c in ipairs(choices) do if c[1] == db[key] then return c[2] end end return tostring(db[key]) end
	b:SetScript("OnClick", function(_, button)
		local i = 1
		for k, c in ipairs(choices) do if c[1] == db[key] then i = k end end
		i = (button == "RightButton") and (i - 2) % #choices + 1 or i % #choices + 1
		db[key] = choices[i][1]; Changed()
	end)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	refreshers[#refreshers + 1] = function() b:SetText(label_()) end
	return b
end
local function Stepper(parent, x, y, label, key, lo, hi, inc, fmt)
	local t = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); t:SetPoint("TOPLEFT", x, y - 4); t:SetText(label)
	local v = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); v:SetPoint("TOPLEFT", x + 110, y - 4)
	local minus = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate"); minus:SetSize(22, 20); minus:SetPoint("TOPLEFT", x + 166, y); minus:SetText("-")
	local plus = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate"); plus:SetSize(22, 20); plus:SetPoint("LEFT", minus, "RIGHT", 2, 0); plus:SetText("+")
	local function change(d) db[key] = math.max(lo, math.min(hi, math.floor((db[key] + d) * 100 + 0.5) / 100)); Changed() end
	minus:SetScript("OnClick", function() change(-inc) end); plus:SetScript("OnClick", function() change(inc) end)
	refreshers[#refreshers + 1] = function() v:SetText(fmt and fmt(db[key]) or tostring(db[key])) end
end
-- colour swatch that opens the game's colour picker
local function OpenPicker(r, g, b, onChange)
	if ColorPickerFrame.SetupColorPickerAndShow then
		ColorPickerFrame:SetupColorPickerAndShow({ r = r, g = g, b = b, hasOpacity = false,
			swatchFunc = function() onChange(ColorPickerFrame:GetColorRGB()) end,
			cancelFunc = function() onChange(r, g, b) end })
	else
		ColorPickerFrame.hasOpacity = false
		ColorPickerFrame.previousValues = { r, g, b }
		ColorPickerFrame.func = function() onChange(ColorPickerFrame:GetColorRGB()) end
		ColorPickerFrame.cancelFunc = function() onChange(r, g, b) end
		ColorPickerFrame:SetColorRGB(r, g, b)
		ColorPickerFrame:Hide(); ColorPickerFrame:Show()
	end
end
local function Swatch(parent, x, y, label, key)
	local b = CreateFrame("Button", nil, parent, "BackdropTemplate"); b:SetSize(18, 18); b:SetPoint("TOPLEFT", x, y)
	b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
	b:SetBackdropBorderColor(0, 0, 0, 1)
	local t = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); t:SetPoint("LEFT", b, "RIGHT", 6, 0); t:SetText(label)
	b:SetScript("OnClick", function()
		local c = C(key)
		OpenPicker(c[1], c[2], c[3], function(r, g, bb) db.colors[key] = { r, g, bb }; Changed() end)
	end)
	refreshers[#refreshers + 1] = function() local c = C(key); b:SetBackdropColor(c[1], c[2], c[3], 1) end
end
-- a strip showing the threat ramp as it will look
local function Ramp(parent, x, y, w, tank)
	local cells = {}
	for i = 1, 20 do
		local t = parent:CreateTexture(nil, "ARTWORK"); t:SetSize(w / 20, 10); t:SetPoint("TOPLEFT", x + (i - 1) * w / 20, y)
		cells[i] = t
	end
	refreshers[#refreshers + 1] = function()
		for i, t in ipairs(cells) do
			local v = (i - 0.5) / 20
			local r, g, b
			if tank then r, g, b = TankShade(0.5 + v * 0.5) else r, g, b = ThreatShade(v) end
			t:SetColorTexture(r, g, b, 1)
		end
	end
end

function PP.ToggleOptions()
	if not opt then
		opt = CreateFrame("Frame", "PintsPlatesOptions", UIParent, "BasicFrameTemplateWithInset")
		opt:SetSize(600, 470); opt:SetPoint("CENTER"); opt:SetFrameStrata("DIALOG"); opt:SetClampedToScreen(true)
		opt:SetMovable(true); opt:EnableMouse(true); opt:RegisterForDrag("LeftButton")
		opt:SetScript("OnDragStart", opt.StartMoving); opt:SetScript("OnDragStop", opt.StopMovingOrSizing)
		tinsert(UISpecialFrames, "PintsPlatesOptions")
		local title = opt:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); title:SetPoint("TOP", 0, -5)
		title:SetText("|cffd4a017Pint's|r Threat Plates")

		-- left column: what shows, sizes, stacking
		local L = 18
		Head(opt, L, -34, "On the plate")
		Check(opt, L, -52, "Name", "showName")
		Check(opt, L + 140, -52, "Level", "showLevel")
		Check(opt, L, -74, "Threat % (left)", "showThreat", "How close you are to pulling the mob - 100% means it's on you.")
		Check(opt, L + 140, -74, "Threat arrows", "showArrows", "Red up arrow on your highest-threat mob, green down arrow on your lowest.")
		Check(opt, L, -96, "Raid markers", "showMarks")
		Check(opt, L + 140, -96, "White edge on target", "targetEdge")
		Choice(opt, L, -122, "Health text", "healthText", { { "both", "1234/1234 | 56%" }, { "numbers", "1234/1234" }, { "percent", "56%" }, { "none", "Nothing" } })

		Head(opt, L, -156, "Size")
		Stepper(opt, L, -176, "Bar width", "width", 60, 220, 4)
		Stepper(opt, L, -200, "Bar height", "height", 4, 24, 1)
		Stepper(opt, L, -224, "Name text", "nameSize", 7, 16, 1)
		Stepper(opt, L, -248, "Bar text", "textSize", 6, 14, 1)

		Head(opt, L, -282, "Stacking and distance")
		Check(opt, L, -300, "Stack plates (no overlapping)", "stack", "Plates move apart so each one can be read.")
		Check(opt, L, -322, "Keep plates on screen", "onScreen", "Stops plates of close or large mobs sliding off the top of the screen. In tight caves this can bunch a few plates at the screen edge - turn it off if that bothers you.")
		Stepper(opt, L, -348, "Gap between plates", "spacing", 0.8, 2, 0.1, function(v) return ("%.1f"):format(v) end)
		Stepper(opt, L, -372, "Distance (yards)", "range", 10, 41, 1, function(v) return tostring(math.floor(v)) .. "  (game max)" end)
		Check(opt, L, -400, "Quest icon on quest mobs", "showQuest", "A yellow ! beside the level on mobs you still need to kill or loot for a quest.")

		-- right column: threat colours
		local X = 318
		Head(opt, X, -34, "Threat colours")
		Choice(opt, X, -54, "Tank colours", "tank", { { "auto", "Automatic" }, { "on", "Always" }, { "off", "Never" } })
		local note = opt:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); note:SetPoint("TOPLEFT", X, -78); note:SetWidth(262); note:SetJustifyH("LEFT")
		note:SetText("Automatic: Defensive Stance, Bear Form or Righteous Fury.")
		Choice(opt, X, -96, "Shades", "steps", { { 5, "5 steps" }, { 10, "10 steps" }, { 20, "20 steps" }, { 0, "Smooth" } })

		local s1 = opt:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); s1:SetPoint("TOPLEFT", X, -128); s1:SetText("Not tanking (low threat -> it's on you)")
		Swatch(opt, X, -146, "Safe", "low"); Swatch(opt, X + 90, -146, "Close", "mid"); Swatch(opt, X + 180, -146, "Pulled", "high")
		Ramp(opt, X, -170, 262, false)

		local s2 = opt:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); s2:SetPoint("TOPLEFT", X, -192); s2:SetText("Tanking (holding it -> losing it)")
		Swatch(opt, X, -210, "Holding", "safe"); Swatch(opt, X + 90, -210, "Slipping", "warn"); Swatch(opt, X + 180, -210, "Lost", "lost")
		Ramp(opt, X, -234, 262, true)
		Check(opt, X, -252, "Flip tank colours", "tankFlip", "Tanks use the not-tanking colours turned round: green while you hold the mob, yellow as someone catches up, red when you've lost it.")

		local s3 = opt:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); s3:SetPoint("TOPLEFT", X, -284); s3:SetText("Before a fight")
		Swatch(opt, X, -302, "Hostile", "hostile"); Swatch(opt, X + 90, -302, "Neutral", "neutral"); Swatch(opt, X + 180, -302, "Tapped", "tapped")

		local reset = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate"); reset:SetSize(130, 22); reset:SetPoint("TOPLEFT", X, -336)
		reset:SetText("Default colours"); reset:SetScript("OnClick", function() db.colors = {}; Changed() end)
		local all = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate"); all:SetSize(130, 22); all:SetPoint("LEFT", reset, "RIGHT", 6, 0)
		all:SetText("Reset everything")
		all:SetScript("OnClick", function()
			for k, v in pairs(DEFAULTS) do if type(v) ~= "table" then db[k] = v end end
			db.colors = {}; Changed()
		end)
		opt.tp = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate"); opt.tp:SetSize(266, 22); opt.tp:SetPoint("TOPLEFT", X, -366)
		opt.tp:SetText("Switch off TidyPlates Threat Plates"); opt.tp:SetScript("OnClick", function() PP.OffThreatPlates() end)

		local foot = opt:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); foot:SetPoint("BOTTOM", 0, 14)
		foot:SetText("Changes apply straight away.  Right-click a choice button to go back one.")
		opt:SetScript("OnShow", function() for _, fn in ipairs(refreshers) do fn() end; opt.tp:SetShown(PP.ThreatPlatesLoaded()) end)
		opt:Hide()
	end
	opt:SetShown(not opt:IsShown())
end

---------------------------------------------------------------- /pn
SLASH_PINTSPLATES1 = "/pn"
SLASH_PINTSPLATES2 = "/pintsplates"
SLASH_PINTSPLATES3 = "/threatplates"
SlashCmdList.PINTSPLATES = function(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "tank" then
		db.tank = (db.tank == "auto" and "on") or (db.tank == "on" and "off") or "auto"
		Print("tank colours: " .. ({ auto = "automatic (Defensive Stance, Bear Form, Righteous Fury)", on = "always", off = "never" })[db.tank] .. ".")
	elseif msg == "off-threatplates" then PP.OffThreatPlates()
	elseif msg == "minimap" then if PP.ToggleMinimap then PP.ToggleMinimap() end
	elseif msg:match("^range") then
		local r = tonumber(msg:match("(%d+)"))
		if r and r >= 10 and r <= 100 then db.range = r; PP.Stacking(); Print("nameplate range set to " .. tostring(GetCVar("nameplateMaxDistance")) .. " yards.") end
	elseif msg:match("^width") then
		local w = tonumber(msg:match("(%d+)"))
		if w and w >= 60 and w <= 220 then db.width = w; PP.ApplyAll() end
	else
		PP.ToggleOptions()
	end
end

---------------------------------------------------------------- minimap button (LibDBIcon when present, otherwise a draggable button)
do
	local NAME, ICON, ANGLE = "PintsPlates", "Interface\\Icons\\Ability_Warrior_DefensiveStance", 180
	local btn
	local function Tip(tt)
		tt:AddLine("|cffd4a017Pint's|r Threat Plates")
		tt:AddLine("Click: options", 1, 1, 1)
		tt:AddLine("Drag to move  -  /pn minimap to hide", 0.5, 0.5, 0.5)
	end
	function PP.BuildMinimap()
		local store = db.minimap
		local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
		local Icon = LibStub and LibStub("LibDBIcon-1.0", true)
		if LDB and Icon then
			local obj = LDB:NewDataObject(NAME, { type = "launcher", text = "Pint's Threat Plates", icon = ICON,
				OnClick = function() PP.ToggleOptions() end, OnTooltipShow = Tip })
			Icon:Register(NAME, obj, store)
			btn = { lib = Icon }
			return
		end
		local b = CreateFrame("Button", NAME .. "MinimapButton", Minimap)
		b:SetSize(31, 31); b:SetFrameStrata("MEDIUM"); b:SetFrameLevel(8)
		b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
		local ic = b:CreateTexture(nil, "BACKGROUND"); ic:SetTexture(ICON); ic:SetSize(20, 20); ic:SetPoint("CENTER", 0, 1)
		ic:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		local border = b:CreateTexture(nil, "OVERLAY"); border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
		border:SetSize(53, 53); border:SetPoint("TOPLEFT")
		local function Place()
			local a = math.rad(store.angle or ANGLE)
			b:ClearAllPoints(); b:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(a), 80 * math.sin(a))
		end
		Place()
		b:RegisterForDrag("LeftButton")
		b:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter(); local px, py = GetCursorPosition(); local s = Minimap:GetEffectiveScale()
			store.angle = math.deg(math.atan2(py / s - my, px / s - mx)); Place() end) end)
		b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
		b:SetScript("OnClick", function() PP.ToggleOptions() end)
		b:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_LEFT"); Tip(GameTooltip); GameTooltip:Show() end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		b:SetShown(not store.hide)
		btn = b
	end
	function PP.ToggleMinimap()
		local store = db.minimap
		store.hide = not store.hide
		if btn and btn.lib then if store.hide then btn.lib:Hide(NAME) else btn.lib:Show(NAME) end
		elseif btn then btn:SetShown(not store.hide) end
		Print("minimap button " .. (store.hide and "hidden - /pn minimap to bring it back." or "shown."))
	end
end
