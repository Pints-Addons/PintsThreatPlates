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
	showName = true, showLevel = true, healthText = "both", showThreat = true, showArrows = true, showMarks = true, targetEdge = true, targetScale = 1.25, showQuest = true, showDebuffs = true, showCast = true, friendly = false, firstName = false,
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
	-- what WoW Forever keeps apart when stacking: the whole plate - name and bar, with a little gap - not just the
	-- bar (with only the bar, the next plate's name and bar landed on this one). It grows with your target's plate.
	if not f.bounds then f.bounds = CreateFrame("Frame", nil, f) end
	f.bounds:ClearAllPoints(); f.bounds:SetPoint("BOTTOM", f, "BOTTOM", 0, -2)
	f.bounds:SetSize(db.width + 4, db.height + nameH + 6)
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
	local ma, my = PP.MarkSpot(f); f.mark:SetPoint("BOTTOM", ma, "TOP", 0, my)
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
	-- a bold red edge: a mob tagged by someone else (grey) that you're on the threat list of
	f.tapEdge = CreateFrame("Frame", nil, f, "BackdropTemplate")
	f.tapEdge:SetPoint("TOPLEFT", f.hp, "TOPLEFT", -3, 3); f.tapEdge:SetPoint("BOTTOMRIGHT", f.hp, "BOTTOMRIGHT", 3, -3)
	f.tapEdge:SetFrameLevel(f.hp:GetFrameLevel() + 3)
	f.tapEdge:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 3 })
	f.tapEdge:SetBackdropBorderColor(1, 0.1, 0.1, 1); f.tapEdge:Hide()
	-- your target: a bright edge round the bar (on top of the others)
	f.tgtEdge = CreateFrame("Frame", nil, f, "BackdropTemplate")
	f.tgtEdge:SetPoint("TOPLEFT", f.hp, "TOPLEFT", -2, 2); f.tgtEdge:SetPoint("BOTTOMRIGHT", f.hp, "BOTTOMRIGHT", 2, -2)
	f.tgtEdge:SetFrameLevel(f.hp:GetFrameLevel() + 4)
	f.tgtEdge:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
	f.tgtEdge:SetBackdropBorderColor(1, 1, 1, 1); f.tgtEdge:Hide()
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
	f.mark:SetSize(56, 56)
	f.mark:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons"); f.mark:Hide()
	-- quest mob: something you still need to kill or loot for a quest
	f.quest = f:CreateTexture(nil, "OVERLAY")
	f.quest:SetSize(14, 14)
	f.quest:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon"); f.quest:Hide()
	plate.PintsThreatPlate = f       -- (its own name: an old copy of this add-on used "PintsPlate" and the two mixed up)
	built[#built + 1] = f
	Layout(f)
	return f
end

---------------------------------------------------------------- quest mobs
-- a mob counts when its tooltip lists a quest objective that isn't finished (kill or collect), or its name is in
-- an unfinished "... slain: x/y" line of your quest log.
-- In a group the tooltip also lists your group's objectives under each member's name: "me" means you still need it
-- (yellow !), "group" means only someone else in your group does (grey !).
local scanTip
local function Unfinished(text)
	if type(text) ~= "string" or IsSecret(text) then return false end
	local a, b = text:match("(%d+)%s*/%s*(%d+)")
	return a and tonumber(a) < tonumber(b)
end
local function Short(n) return type(n) == "string" and (n:match("^([^%-]+)") or n) or nil end
-- the other people in your group, by name
local function GroupNames()
	local t, n = {}, 0
	local raid = IsInRaid and IsInRaid()
	local count = raid and (GetNumGroupMembers and GetNumGroupMembers() or 0) or 4
	for i = 1, count do
		local u = raid and ("raid" .. i) or ("party" .. i)
		if UnitExists(u) and not UnitIsUnit(u, "player") then
			local name = Known(UnitName(u))
			if name then t[name] = true; n = n + 1 end
			-- (and the full name WoW Forever shows in tooltips)
			if GetUnitName then local ok, full = pcall(GetUnitName, u, false); full = ok and Known(full); if full then t[full] = true end end
		end
	end
	return n > 0 and t or nil
end
-- "who" is the owner of the objective lines that follow: nil (you) until a group member's name line appears
local function Who(text, group, me)
	text = Known(text); if type(text) ~= "string" then return nil end
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	-- (WoW Forever lists you by your full name, "Rain Mon"; me holds every form of your name)
	if me[text] or me[Short(text) or ""] then return "me" end
	if group and (group[text] or group[Short(text) or ""]) then return "group" end
end
local function Merge(best, who) if best == "me" or who == "me" then return "me" end return who or best end
local function FromTooltipInfo(u, group, me)
	-- not in a group: every objective listed is yours
	if not group then me = setmetatable({}, { __index = function() return true end }) end
	if not (C_TooltipInfo and C_TooltipInfo.GetUnit and Enum and Enum.TooltipDataLineType) then return nil end
	local T = Enum.TooltipDataLineType
	local OBJ, TITLE, PLAYER = T.QuestObjective, T.QuestTitle, T.QuestPlayer
	local ok, data = pcall(C_TooltipInfo.GetUnit, u)
	if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
	local owner, best = "me", false
	for _, l in ipairs(data.lines) do
		local ty = Known(l.type)
		if TITLE and ty == TITLE then owner = "me"
		elseif PLAYER and ty == PLAYER then owner = Who(l.leftText, group, me) or "group"
		elseif OBJ and ty == OBJ then
			if Known(l.completed) ~= true then best = Merge(best, owner) end
		elseif group then
			owner = Who(l.leftText, group, me) or owner
		end
	end
	return best
end
local function FromTooltip(u, group, me)
	if not group then me = setmetatable({}, { __index = function() return true end }) end
	if not scanTip then
		scanTip = CreateFrame("GameTooltip", "PintsPlatesScanTip", nil, "GameTooltipTemplate")
		scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
	end
	scanTip:ClearLines()
	if not pcall(scanTip.SetUnit, scanTip, u) then return false end
	local owner, best = "me", false
	for i = 2, scanTip:NumLines() do
		local fs = _G["PintsPlatesScanTipTextLeft" .. i]
		local text = fs and fs:GetText()
		if Unfinished(text) then best = Merge(best, owner)
		elseif group then owner = Who(text, group, me) or owner end
	end
	return best
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
-- "me", "group" or false
local function IsQuestMob(u)
	if UnitIsPlayer(u) or Known(UnitIsDead(u)) then return false end
	local group, me = GroupNames(), {}
	-- every form of your name: first name, full name ("Rain Mon"), and with the realm
	local first = Known(UnitName("player"))
	if first then me[first] = true end
	if GetUnitName then
		local ok, full = pcall(GetUnitName, "player", false); full = ok and Known(full)
		if full then me[full] = true end
		local ok2, withRealm = pcall(GetUnitName, "player", true); withRealm = ok2 and Known(withRealm)
		if withRealm then me[withRealm] = true end
	end
	local r = FromTooltipInfo(u, group, me)
	if r == nil then r = FromTooltip(u, group, me) end
	if r == "me" then return "me" end
	local name = Known(UnitName(u))
	if name and FromLog(name) then return "me" end
	return r or false
end
local function QuestIcon(f)
	if not f.quest then return end      -- (a plate frame another add-on made)
	if not db.showQuest or not f.unit then f.quest:Hide(); return end
	local ok, q = pcall(IsQuestMob, f.unit)
	if not ok or not q then f.quest:Hide(); return end
	local grey = q == "group"
	f.quest:SetDesaturated(grey)
	if grey then f.quest:SetVertexColor(0.75, 0.75, 0.75) else f.quest:SetVertexColor(1, 1, 1) end
	f.quest:Show()
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

-- WoW Forever hides which raid marker a mob has, so our own icon can't be picked. Blizzard's plate has its own marker
-- icon, which the game keeps right: that one is kept visible (the rest of Blizzard's plate stays see-through) and moved
-- to where ours goes. Returns true when it's doing the job.
local function BlizzMark(plate)
	local uf = plate and plate.UnitFrame
	if not uf then return end
	return uf.RaidTargetFrame or uf.raidTargetIcon or uf.RaidTargetIcon
end
-- the raid marker: big, centred above the plate (above the name, and above the debuff row when that's on)
function PP.MarkSpot(f)
	local a = (db.showName and f.name) or f
	return a, (db.showDebuffs and 26 or 2)
end
local function ModernMark(f)
	local plate = f.unit and C_NamePlate.GetNamePlateForUnit(f.unit)
	local rt = plate and BlizzMark(plate)
	if not rt or (rt.IsForbidden and rt:IsForbidden()) then return false end
	local ok = pcall(function()
		if db.showMarks then
			rt.ppHide, rt.ppKeep = nil, true
			if rt.SetIgnoreParentAlpha then rt:SetIgnoreParentAlpha(true) end
			rt.ppBusy = true; rt:SetAlpha(1); rt.ppBusy = nil
			if rt.SetParent and rt:GetParent() ~= f then rt.ppOldParent = rt.ppOldParent or rt:GetParent() end
			rt:ClearAllPoints()
			local ma, my = PP.MarkSpot(f); rt:SetPoint("BOTTOM", ma, "TOP", 0, my)
			if rt.SetSize then rt:SetSize(56, 56) end
			if rt.RaidTargetIcon and rt.RaidTargetIcon.SetAllPoints then rt.RaidTargetIcon:SetAllPoints(rt) end
			if rt.SetFrameLevel then rt:SetFrameLevel(f:GetFrameLevel() + 5) end
		else
			rt.ppKeep = nil
			if rt.SetIgnoreParentAlpha then rt:SetIgnoreParentAlpha(false) end
		end
	end)
	return ok
end
PP.ModernMark = ModernMark

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
	-- tagged by someone else (no loot or experience for you): grey, whatever the threat says
	local denied = UnitIsTapDenied and Known(UnitIsTapDenied(u))
	if denied then r, g, b = unpack(C("tapped")) end
	-- tagged by someone else but you've got threat on it (it's after you, or you've hit it): bold red edge
	local onList
	if denied and UnitDetailedThreatSituation then
		local _, status = Threat("player", u)
		onList = status ~= nil or Known(UnitIsUnit(u .. "target", "player")) or false
	end
	if f.tapEdge then f.tapEdge:SetShown(onList and true or false) end
	f.score = ThreatScore(u)
	local tp = db.showThreat and ThreatPct(u)
	if tp then
		f.rank:SetText(math.floor(tp + 0.5) .. "%")
		if r then f.rank:SetTextColor(r, g, b) else f.rank:SetTextColor(1, 1, 1) end
	elseif db.showThreat then
		f.rank:SetText("")
	end
	-- WoW Forever can hide the threat numbers in a fight: the game will still colour the bar from them
	local hidden
	if not r and not denied and SECRET and not f.friendly and UnitDetailedThreatSituation then
		local tanking, status, scaled = UnitDetailedThreatSituation("player", u)
		if IsSecret(tanking) or IsSecret(scaled) then hidden = { tanking, scaled } end
	end
	if f.friendly then r, g, b = 0.2, 0.8, 0.2                 -- friendly: always green
	elseif not r then r, g, b = ReactionColor(u) end
	f.hp:SetStatusBarColor(r, g, b)
	if hidden then
		local tex = f.hp:GetStatusBarTexture()
		if IsSecret(hidden[1]) and tex and tex.SetVertexColorFromBoolean and CreateColor then
			-- it's on you / it isn't: the two ends of your threat colours (a tank's are "safe" and "lost")
			local on, off
			if IsTank() then on, off = C("safe"), C("lost") else on, off = C("high"), C("low") end
			pcall(tex.SetVertexColorFromBoolean, tex, hidden[1], CreateColor(on[1], on[2], on[3]), CreateColor(off[1], off[2], off[3]))
		end
		if db.showThreat and IsSecret(hidden[2]) then pcall(f.rank.SetFormattedText, f.rank, "%d%%", hidden[2]); f.rank:SetTextColor(1, 1, 1) end
	end
	-- WoW Forever may hide whether it's tagged by someone else: the game can still pick grey from that itself
	if not denied and not hidden and not f.friendly and UnitIsTapDenied then
		local td = UnitIsTapDenied(u)
		local tex = f.hp:GetStatusBarTexture()
		if IsSecret(td) and tex and tex.SetVertexColorFromBoolean and CreateColor then
			local t = C("tapped")
			pcall(tex.SetVertexColorFromBoolean, tex, td, CreateColor(t[1], t[2], t[3]), CreateColor(r, g, b))
		end
	end
	-- your target: bigger, with a white edge
	local isT = Known(UnitIsUnit(u, "target")) and true or false
	if db.targetEdge and isT then f.hp:SetBackdropBorderColor(1, 1, 1, 1) else f.hp:SetBackdropBorderColor(0, 0, 0, 1) end
	if f.tgtEdge then f.tgtEdge:SetShown(db.targetEdge and isT) end
	-- (where the game can size the target's plate itself, it does - then stacking makes room for the bigger plate.
	-- Only on clients without that is our part of the plate scaled, and there it can overlap its neighbours.)
	local sc = (isT and not PP.gameScale) and (db.targetScale or 1.25) or 1
	if f.tgtScale ~= sc then f:SetScale(sc); f.tgtScale = sc end
	-- raid marker
	local idx = db.showMarks and GetRaidTargetIndex(u)
	if SECRET and ModernMark(f) then
		f.mark:Hide()                     -- (Blizzard's own marker icon is showing in its place)
	elseif IsSecret(idx) then
		-- WoW Forever hides which marker it is: the game can still draw the matching icon from it
		f.mark:SetTexCoord(0, 1, 0, 1)
		if pcall(function() f.mark:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. idx) end) then f.mark:Show() else f.mark:Hide() end
	elseif idx then
		f.mark:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons"); SetRaidTargetIconTexture(f.mark, idx); f.mark:Show()
	else f.mark:Hide() end
end

-- Mob level colours by the Classic rules (WoW Forever's modern client greys mobs out far too early: at level 22 it
-- showed level 16 mobs grey though they still give experience). Grey = no experience, as Classic works it out.
local function ClassicGrey(me)
	if me <= 5 then return 0 end
	if me <= 39 then return me - math.floor(me / 10) - 5 end
	return me - math.floor(me / 5) - 1
end
local function MobLevelColor(lv)
	if not (type(issecretvalue) == "function") and GetQuestDifficultyColor then
		local c = GetQuestDifficultyColor(lv); if c then return c.r, c.g, c.b end   -- Classic Era: the game's own colours
	end
	local me = UnitLevel("player") or 1
	local d = lv - me
	if d >= 5 then return 1, 0.1, 0.1 end
	if d >= 3 then return 1, 0.5, 0.25 end
	if d >= -2 then return 1, 0.82, 0 end
	if lv > ClassicGrey(me) then return 0.25, 0.75, 0.25 end
	return 0.5, 0.5, 0.5
end
-- the mob's name; the game says "Unknown" until it has loaded the name, so look again shortly when it does
local function SetName(f)
	local u = f.unit
	if not u then return end
	-- WoW Forever names have a second name ("Pint Sunders"), which UnitName leaves off
	local ok, full = false, nil
	if GetUnitName and not db.firstName then ok, full = pcall(GetUnitName, u, false) end    -- ("First names only" leaves it off)
	local name = (ok and full) or UnitName(u) or ""
	f.name:SetText(name)
	local unknown = not IsSecret(name) and (name == "" or name == (UNKNOWNOBJECT or "Unknown") or name == "Unknown")
	if unknown then
		f.nameTries = (f.nameTries or 0) + 1
		if f.nameTries <= 10 then
			local unit = u
			C_Timer.After(0.5, function() if f.unit == unit then SetName(f) end end)
		end
	else f.nameTries = nil end
end
PP.SetName = SetName
local function Setup(f)
	local u = f.unit
	f.nameTries = nil
	SetName(f)
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
		f.level:SetTextColor(MobLevelColor(lv))
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
		if c.IsIgnoringParentAlpha and Known(c:IsIgnoringParentAlpha()) and not (c.ppMine and db.showDebuffs) and not (c.ppKeep and db.showMarks) then Fade(c, hide) end
		Sweep(c, hide, depth + 1)
	end
end
local function HideBlizzard(plate, hide)
	for _, child in ipairs({ plate:GetChildren() }) do
		if child ~= plate.PintsThreatPlate and not (child.IsForbidden and child:IsForbidden()) then Fade(child, hide); Sweep(child, hide, 1) end
	end
	for _, r in ipairs({ plate:GetRegions() }) do r:SetAlpha(hide and 0 or 1) end
end

---------------------------------------------------------------- your debuffs, in a row above the name
-- Classic Era: our own icons, read from the mob's debuffs (yours only), with the time left as a sweep.
-- WoW Forever: add-ons can't read a mob's auras in combat there, so instead Blizzard's own debuff row on the plate
-- (which the game keeps up to date, in combat too) is kept visible and moved above our name.
local MAXD, DSIZE = 6, 26
local DSCALE = 1.35       -- (WoW Forever: Blizzard's debuff row, drawn this much bigger)
local function DebuffAnchor(f) if db.showName then return f.name, "TOP", 3 end return f, "TOP", 4 end
local function ClassicDebuffs(f)
	f.debuffs = f.debuffs or {}
	local n = 0
	if db.showDebuffs and UnitAura then
		for i = 1, 40 do
			local name, icon, count, _, duration, expires = UnitAura(f.unit, i, "HARMFUL|PLAYER")
			if not name then break end
			n = n + 1
			if n > MAXD then n = MAXD; break end
			local d = f.debuffs[n]
			if not d then
				d = CreateFrame("Frame", nil, f); d:SetSize(DSIZE, DSIZE)
				d.icon = d:CreateTexture(nil, "ARTWORK"); d.icon:SetAllPoints(); d.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
				d.edge = d:CreateTexture(nil, "BACKGROUND"); d.edge:SetPoint("TOPLEFT", -1, 1); d.edge:SetPoint("BOTTOMRIGHT", 1, -1); d.edge:SetColorTexture(0, 0, 0, 1)
				d.cd = CreateFrame("Cooldown", nil, d, "CooldownFrameTemplate"); d.cd:SetAllPoints(); d.cd:SetReverse(true); d.cd:SetHideCountdownNumbers(false)
				d.count = d:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall"); d.count:SetPoint("BOTTOMRIGHT", 2, -2)
				f.debuffs[n] = d
			end
			d.icon:SetTexture(icon)
			d.count:SetText((count and count > 1) and count or "")
			if duration and duration > 0 and expires then d.cd:SetCooldown(expires - duration, duration); d.cd:Show() else d.cd:Hide() end
			d:Show()
		end
	end
	for i = n + 1, #f.debuffs do f.debuffs[i]:Hide() end
	-- a centred row above the name
	local a, p, y = DebuffAnchor(f)
	local w = n * (DSIZE + 2) - 2
	for i = 1, n do
		local d = f.debuffs[i]
		d:ClearAllPoints(); d:SetPoint("BOTTOMLEFT", a, p, -w / 2 + (i - 1) * (DSIZE + 2), y)
	end
end
-- Blizzard's aura row on the plate (the name differs between game versions)
local function BlizzAuras(plate)
	local uf = plate.UnitFrame
	if not uf then return end
	return uf.AurasFrame or uf.BuffFrame or uf.DebuffFrame
end
local function ModernDebuffs(f, plate)
	local af = plate and BlizzAuras(plate)
	if not af or (af.IsForbidden and af:IsForbidden()) then return end
	pcall(function()
		if db.showDebuffs then
			-- shown even though the rest of Blizzard's plate is see-through, and placed above our name
			af.ppHide = nil
			if af.SetIgnoreParentAlpha then af:SetIgnoreParentAlpha(true) end
			af.ppBusy = true; af:SetAlpha(1); af.ppBusy = nil
			if af.SetScale and af.ppScale ~= DSCALE then af.ppBase = af.ppBase or af:GetScale(); af:SetScale(af.ppBase * DSCALE); af.ppScale = DSCALE end
			local a, p, y = DebuffAnchor(f)
			af:ClearAllPoints(); af:SetPoint("BOTTOM", a, p, 0, y)
			af.ppMine = true
		elseif af.ppMine then
			af.ppMine = nil
			if af.SetIgnoreParentAlpha then af:SetIgnoreParentAlpha(false) end
			if af.ppBase then af:SetScale(af.ppBase); af.ppBase, af.ppScale = nil, nil end
		end
	end)
end
local function Debuffs(f)
	if not f.unit then return end
	if SECRET then ModernDebuffs(f, C_NamePlate.GetNamePlateForUnit(f.unit)) else pcall(ClassicDebuffs, f) end
end
PP.Debuffs = Debuffs

---------------------------------------------------------------- the mob's cast bar, under its health bar
-- icon, spell name, a filling bar and the seconds left; grey when it can't be interrupted. On WoW Forever the game may
-- hide a mob's cast times: the bar still fills (the game works that out itself), only the seconds are left off.
local function Has(v) return IsSecret(v) or v ~= nil end     -- a hidden value counts, without testing it
local function MakeCast(f)
	local c = CreateFrame("StatusBar", nil, f, "BackdropTemplate")
	c:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -3); c:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", 0, -3)
	c:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	c:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
	c:SetBackdropColor(0, 0, 0, 0.6); c:SetBackdropBorderColor(0, 0, 0, 1)
	c.icon = c:CreateTexture(nil, "ARTWORK"); c.icon:SetPoint("RIGHT", c, "LEFT", -2, 0); c.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	c.name = c:CreateFontString(nil, "OVERLAY", "PintsPlatesBar"); c.name:SetPoint("LEFT", 3, 0); c.name:SetPoint("RIGHT", -26, 0)
	c.name:SetJustifyH("LEFT"); c.name:SetWordWrap(false)
	c.time = c:CreateFontString(nil, "OVERLAY", "PintsPlatesBar"); c.time:SetPoint("RIGHT", -2, 0)
	c:Hide()
	c:SetScript("OnUpdate", function(self)
		if not self.timed then self:SetValue(GetTime() * 1000) end
		if self.endMS then local left = self.endMS / 1000 - GetTime(); self.time:SetText(left > 0 and ("%.1f"):format(left) or "") end
	end)
	f.cast = c
end
local function Cast(f)
	local c, u = f.cast, f.unit
	if not c then return end
	if not (db.showCast and u and UnitExists(u)) then c:Hide(); return end
	local h = math.max(8, math.floor(db.height * 0.7 + 0.5))
	c:SetHeight(h); c.icon:SetSize(h + 2, h + 2)
	local channel = false
	local name, _, tex, s, e, _, _, noInt = UnitCastingInfo(u)
	if not Has(name) then name, _, tex, s, e, _, noInt = UnitChannelInfo(u); channel = Has(name) end
	if not (Has(name) and Has(s) and Has(e)) then c:Hide(); return end
	-- WoW Forever: the game runs the bar itself from the cast's own timer - smooth, and right even when it hides the
	-- times from add-ons. (Elsewhere: filled each frame from the start and end times.)
	c.timed = nil
	local durFn = channel and UnitChannelDuration or UnitCastingDuration
	if c.SetTimerDuration and durFn then
		local okD, dur = pcall(durFn, u)
		if okD and dur then
			local I = Enum and Enum.StatusBarInterpolation
			local D = Enum and Enum.StatusBarTimerDirection
			local okT = pcall(c.SetTimerDuration, c, dur, I and I.Immediate or 0, D and (channel and D.RemainingTime or D.ElapsedTime) or (channel and 1 or 0))
			if okT then c.timed = true end
		end
	end
	if not c.timed then c:SetMinMaxValues(s, e) end   -- the game accepts these even when it keeps them hidden from add-ons
	c.name:SetText(name); c.icon:SetTexture(tex)
	local shut = (not IsSecret(noInt)) and noInt
	if shut then c:SetStatusBarColor(0.6, 0.6, 0.6)
	elseif channel then c:SetStatusBarColor(0.3, 0.75, 1)
	else c:SetStatusBarColor(1, 0.7, 0) end
	c.endMS = (not IsSecret(e)) and e or nil
	c.time:SetText("")
	c:Show()
end
PP.Cast = Cast

local function Added(unit)
	local plate = C_NamePlate.GetNamePlateForUnit(unit)
	if not plate or (plate.IsForbidden and plate:IsForbidden()) then return end
	local friendly = not UnitCanAttack("player", unit)
	if friendly and not db.friendly then
		HideBlizzard(plate, false)
		if plate.PintsThreatPlate then plate.PintsThreatPlate:Hide() end
		active[unit] = nil
		return
	end
	local f = plate.PintsThreatPlate or Build(plate)
	f.friendly = friendly
	-- WoW Forever: plates keep apart by the size of a frame on each plate - the game's own health bar unless told
	-- otherwise, and that's hidden here, so they piled on top of each other. Ours is the one to keep apart.
	if not f.bounds then Layout(f) end
	local box = f.bounds or f
	if plate.SetStackingBoundsFrame and plate.pintsBounds ~= box then
		if pcall(plate.SetStackingBoundsFrame, plate, box) then plate.pintsBounds = box end
	end
	if not f.cast then MakeCast(f) end
	f.unit = unit
	HideBlizzard(plate, true)
	C_Timer.After(0, function() if plate.PintsThreatPlate == f and f.unit == unit then HideBlizzard(plate, true) end end)
	f:Show()
	active[unit] = f
	Setup(f)
	Debuffs(f)
	pcall(Cast, f)
	if SECRET then C_Timer.After(0.1, function() if f.unit == unit then Debuffs(f) end end) end
end

PP.Added = Added
local function Removed(unit)
	local f = active[unit]
	if f then f:Hide(); if f.cast then f.cast:Hide() end; f.unit = nil; active[unit] = nil end
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
	-- your target's plate: sized by the game ("selected scale"), so stacking keeps the others clear of it
	PP.gameScale = GetCVar("nameplateSelectedScale") ~= nil and pcall(SetCVar, "nameplateSelectedScale", db.targetScale or 1.25) or false
	for _, f in pairs(active) do f.tgtScale = nil end
	local h = db.height + (db.showName and (db.nameSize + 4) or 2) + 4
	if C_NamePlate and C_NamePlate.SetNamePlateEnemySize then pcall(C_NamePlate.SetNamePlateEnemySize, db.width + 16, h) end
	-- (the newer clients have one size for all plates)
	if C_NamePlate and C_NamePlate.SetNamePlateSize then pcall(C_NamePlate.SetNamePlateSize, db.width + 16, h) end
end

function PP.ApplyAll()
	MakeFont("PintsPlatesName", db.nameSize)
	MakeFont("PintsPlatesBar", db.textSize)
	MakeFont("PintsPlatesLevel", math.max(db.nameSize + 4, db.height - 2))   -- level beside the bar: sized to the bar
	for _, f in ipairs(built) do Layout(f) end
	for _, f in pairs(active) do Setup(f); if PP.Debuffs then PP.Debuffs(f) end end
	-- every plate on screen looked at again (a setting may have changed which ones are ours, e.g. friendly plates)
	if C_NamePlate and C_NamePlate.GetNamePlates and PP.Added then
		for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
			local u = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
			if u then pcall(PP.Added, u) end
		end
	end
	PP.Stacking()
end

---------------------------------------------------------------- events and refresh
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED"); ev:RegisterEvent("PLAYER_LOGIN"); ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("NAME_PLATE_UNIT_ADDED"); ev:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
ev:RegisterEvent("UNIT_FACTION"); ev:RegisterEvent("RAID_TARGET_UPDATE"); ev:RegisterEvent("PLAYER_TARGET_CHANGED")
ev:RegisterEvent("QUEST_LOG_UPDATE")
pcall(ev.RegisterEvent, ev, "UNIT_NAME_UPDATE")
-- a group member's quest progress, or who is in the group, changes the grey ! too
for _, e in ipairs({ "GROUP_ROSTER_UPDATE", "UNIT_QUEST_LOG_CHANGED" }) do pcall(ev.RegisterEvent, ev, e) end
if not SECRET then ev:RegisterEvent("UNIT_AURA") end
local CASTEV = {}
for _, e in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_DELAYED",
	"UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_CHANNEL_UPDATE", "UNIT_SPELLCAST_INTERRUPTIBLE",
	"UNIT_SPELLCAST_NOT_INTERRUPTIBLE" }) do
	if pcall(ev.RegisterEvent, ev, e) then CASTEV[e] = true end
end
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
	elseif e == "UNIT_NAME_UPDATE" then
		local f = a1 and active[a1]
		if f then SetName(f) end
	elseif CASTEV[e] then
		local f = a1 and active[a1]
		if f then pcall(Cast, f) end
	elseif e == "UNIT_AURA" then
		local f = a1 and active[a1]
		if f then Debuffs(f) end
	elseif e == "UNIT_FACTION" then if a1 and a1:find("^nameplate") then Removed(a1); Added(a1) end
	elseif e == "QUEST_LOG_UPDATE" or e == "GROUP_ROSTER_UPDATE" or e == "UNIT_QUEST_LOG_CHANGED" then
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
		opt:SetSize(600, 496); opt:SetPoint("CENTER"); opt:SetFrameStrata("DIALOG"); opt:SetClampedToScreen(true)
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
		Stepper(opt, 318, -398, "Target plate size", "targetScale", 1, 2, 0.05, function(v) return ("%d%%"):format(math.floor(v * 100 + 0.5)) end)
		Check(opt, L, -422, "Your debuffs above the name", "showDebuffs", "Icons for your own debuffs on each mob, in a row above its name.")
		Check(opt, L + 200, -422, "Cast bar", "showCast", "The mob's cast bar, under its health bar.")
		Check(opt, L, -444, "Friendly plates (green)", "friendly", "Players and others on your side get these plates too, with a green health bar, instead of the game's own. Turn on friendly nameplates in game (Shift-V) to see them.")
		Check(opt, L + 200, -444, "First names only", "firstName", "Leave off WoW Forever's second names (\"Pint\" instead of \"Pint Sunders\").")
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
		Check(opt, L, -400, "Quest icon on quest mobs", "showQuest", "A yellow ! beside the level on mobs you still need to kill or loot for a quest. A grey ! when only someone else in your group needs it.")

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
	if msg == "mark" then
		-- what the game tells add-ons about your target's raid marker (for checking the marker icons)
		local idx = GetRaidTargetIndex("target")
		local secret = IsSecret(idx)
		local ok, err = pcall(function() PP.testTex = PP.testTex or UIParent:CreateTexture(); PP.testTex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. idx) end)
		Print(("target marker: %s, icon from it %s"):format(secret and "hidden" or tostring(idx), ok and "works" or ("fails - " .. tostring(err))))
		local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit("target")
		local rt = plate and BlizzMark(plate)
		Print("Blizzard's marker on the target's plate: " .. (rt and ((rt.GetName and rt:GetName()) or "found") or (plate and "not found" or "no plate (is it on screen?)")))
		return
	elseif msg == "threat" then
		-- what the game tells add-ons about your target's threat (for checking the colours)
		local a, b, c, d, e = UnitDetailedThreatSituation("player", "target")
		local function S(v) return (IsSecret(v) and "hidden") or tostring(v) end
		PP.testTex = PP.testTex or UIParent:CreateTexture()
		Print(("target threat - tanking %s, status %s, %% %s, value %s; in combat %s; colour by boolean %s"):format(S(a), S(b), S(c), S(e),
			S(UnitAffectingCombat("target")), tostring(PP.testTex.SetVertexColorFromBoolean ~= nil)))
		return
	elseif msg == "hitbox" then
		-- (saved for reading outside the game: every nameplate / stacking setting this game version has, and its value)
		local probe = { when = date(), cvars = {}, methods = {} }
		local all = C_Console and C_Console.GetAllCommands and C_Console.GetAllCommands() or {}
		for _, c in ipairs(all) do
			local n = c.command
			if type(n) == "string" and (n:lower():find("nameplate") or n:lower():find("stack")) then probe.cvars[n] = tostring(GetCVar(n)) end
		end
		local tp = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit("target")
		local pmt = tp and getmetatable(tp)
		if pmt and type(pmt.__index) == "table" then for k in pairs(pmt.__index) do if type(k) == "string" then probe.methods[#probe.methods + 1] = k end end end
		for k, v in pairs(C_NamePlate or {}) do probe.methods[#probe.methods + 1] = "C_NamePlate." .. k end
		table.sort(probe.methods)
		probe.bounds = tp and tostring(tp.pintsBounds ~= nil) or "no target plate"
		PintsPlatesDB.probe = probe
		Print("saved the nameplate settings for Claude - /reload to write them out.")
		-- what decides where a plate can be clicked on this game version (for making the click area cover the bar)
		local names = {}
		for k, v in pairs(C_NamePlate or {}) do if type(v) == "function" then names[#names + 1] = k end end
		table.sort(names)
		Print("C_NamePlate: " .. table.concat(names, ", "))
		local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit("target")
		if not plate then Print("target a mob whose plate is on screen, then /pn hitbox again."); return end
		local function N(v) return IsSecret(v) and "hidden" or (type(v) == "number" and ("%.0f"):format(v)) or tostring(v) end
		local f = plate.PintsThreatPlate
		local pw, ph = plate:GetSize()
		Print(("plate %s x %s (scale %s)   ours %s x %s"):format(N(pw), N(ph), N(plate:GetEffectiveScale() * 100), f and N(f:GetWidth()) or "-", f and N(f:GetHeight()) or "-"))
		local mt, found = getmetatable(plate), {}
		local idx = mt and mt.__index
		if type(idx) == "table" then
			for k in pairs(idx) do if type(k) == "string" and (k:find("Bound") or k:find("Hit") or k:find("Click") or k:find("Stack")) then found[#found + 1] = k end end
		end
		table.sort(found)
		Print("plate methods: " .. (#found > 0 and table.concat(found, ", ") or "none found"))
		local uf = plate.UnitFrame
		if uf then local w, h = uf:GetSize(); Print(("Blizzard's plate frame %s x %s, mouse %s"):format(N(w), N(h), tostring(uf:IsMouseEnabled()))) end
		for _, cv in ipairs({ "nameplateHorizontalScale", "NamePlateHorizontalScale", "nameplateVerticalScale", "NamePlateVerticalScale", "nameplateSelectedScale", "nameplateMotion", "nameplateGlobalScale" }) do
			local v = GetCVar(cv); if v then Print(cv .. " = " .. v) end
		end
		return
	elseif msg == "tank" then
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
