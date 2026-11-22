-- Lattice: the "5-second rule". Spirit stops restoring mana for 5 seconds after a player spends mana.
--
-- A thin strip above the mana bar drains over those 5 seconds, then glows (pulsing) while mana comes back, until it
-- is full. Spending is seen from UNIT_SPELLCAST_SUCCEEDED plus the spell's mana cost from the client's own spell
-- data, never by comparing mana values: those can be secret (in instances, in combat). No combat log.
--
-- Cost: nothing runs per frame while nobody is counting down. One shared driver frame (OnUpdate, throttled) is shown
-- only while at least one frame counts down; the pulse is a client-side animation. Everything lives on the button's
-- visual child frame (not protected), so nothing here taints the secure buttons.
local _, ns = ...
local S, U = ns.Secret, ns.Util
local FS = {}
ns.FiveSecond = FS

local DURATION = 5
local TICK = 0.04         -- driver refresh while counting (25 per second)
local HEIGHT = 2          -- strip height in pixels
FS.DURATION = DURATION

local issecret = S.IsSecret
local Plain = S.Plain

-- Never a mana spend even if the client says otherwise: Auto Shot, Shoot (wands), Attack.
FS.IGNORE = { [75] = true, [5019] = true, [6603] = true }

-- With no roles set, these classes count as healers (unless they are the tank).
FS.HEALER_CLASSES = { PRIEST = true, DRUID = true, SHAMAN = true, PALADIN = true }

FS.spent = {}   -- player GUID -> time of the last mana spend
FS.active = {}  -- buttons counting down (the driver refreshes only these)

local function Settings() return ns.db and ns.db.appearance.fiveSecond end

------------------------------------------------------------------------
-- Detection
------------------------------------------------------------------------
local function CostsMana(spellID)
	local get = (C_Spell and C_Spell.GetSpellPowerCost) or GetSpellPowerCost
	if not get then return false end
	local ok, costs = pcall(get, spellID)
	if not ok or issecret(costs) or type(costs) ~= "table" then return false end
	for i = 1, #costs do
		local c = costs[i]
		if type(c) == "table" and not issecret(c) then
			local kind, name = Plain(c.type, nil), Plain(c.name, nil)
			if kind == 0 or name == "MANA" then
				local cost, pct = Plain(c.cost, 0), Plain(c.costPercent, 0)
				if (type(cost) == "number" and cost > 0) or (type(pct) == "number" and pct > 0) then return true end
			end
		end
	end
	return false
end

-- true when the spell costs mana; false for free spells and anything unreadable (secret ID, odd cost data).
function FS.SpellCostsMana(spellID)
	if issecret(spellID) or type(spellID) ~= "number" or FS.IGNORE[spellID] then return false end
	local ok, mana = pcall(CostsMana, spellID)
	return ok and mana == true
end

local function GroupUnit(unit)
	return type(unit) == "string" and (unit == "player" or unit:match("^party%d+$") or unit:match("^raid%d+$")) and true or false
end

local function GUIDOf(unit)
	local guid = UnitGUID(unit)
	if issecret(guid) or type(guid) ~= "string" then return nil end
	return guid
end

local function IsMe(unit)
	return unit == "player" or Plain(UnitIsUnit(unit, "player"), false) == true
end

local function UsesMana(unit)
	local _, token = UnitPowerType(unit)
	return Plain(token, nil) == "MANA"
end
FS.UsesMana = UsesMana

-- Whether this player's frame shows the rule (settings + uses mana right now).
function FS:Wants(unit)
	local C = Settings()
	if not C or not C.enabled or not unit or not UsesMana(unit) then return false end
	if IsMe(unit) then return true end
	if C.who == "all" then return true end
	if C.who ~= "healers" then return false end
	local role = ns.Roles and ns.Roles:Role(unit) or "NONE"
	if role == "HEALER" then return true end
	if role ~= "NONE" then return false end
	local _, class = UnitClass(unit)
	return FS.HEALER_CLASSES[Plain(class, nil)] == true
end

local function ForGUID(guid, fn)
	for _, btn in ipairs(ns.Buttons.all) do
		if btn.fsrGUID == guid and btn.unit then fn(btn) end
	end
end

-- Your own spends also go to the 5-second rule ring (Modules/FiveSecondWidget.lua), which has its own on/off.
function FS:OnCast(unit, spellID)
	local C = Settings()
	if not C or not GroupUnit(unit) then return end
	local ring = FS.Widget and FS.Widget:Enabled() and IsMe(unit)
	if not C.enabled and not ring then return end
	if not FS.SpellCostsMana(spellID) then return end
	if ring then FS.Widget:OnSpend(GetTime()) end
	if not C.enabled then return end
	local guid = GUIDOf(unit)
	if not guid or not self:Wants(unit) then return end
	FS.spent[guid] = GetTime()
	ForGUID(guid, function(btn) FS:Update(btn) end)
end

------------------------------------------------------------------------
-- Visuals
------------------------------------------------------------------------
local function SetGlowColor(tex, r, g, b)
	local ok = tex.SetGradient and CreateColor and pcall(tex.SetGradient, tex, "VERTICAL", CreateColor(r, g, b, 0.45), CreateColor(r, g, b, 0))
	if not ok then tex:SetVertexColor(r, g, b, 0.22) end
end

local function Build(btn)
	local v = btn.visual
	if v.fsr then return v.fsr end
	local f = CreateFrame("Frame", nil, v)
	f:SetFrameLevel(v:GetFrameLevel() + 5) -- above the bars, below borders and text
	f:SetHeight(HEIGHT)

	f.track = U.Solid(f, "BACKGROUND", 0, 0, 0, 0.55)
	f.track:SetAllPoints()
	f.bar = CreateFrame("StatusBar", nil, f)
	f.bar:SetAllPoints()
	f.bar:SetStatusBarTexture(U.WHITE)
	f.bar:SetMinMaxValues(0, DURATION)

	-- regenerating: a full line with a soft glow above it, pulsing
	f.regen = CreateFrame("Frame", nil, f)
	f.regen:SetAllPoints()
	f.line = U.Solid(f.regen, "ARTWORK", 1, 1, 1, 0.9)
	f.line:SetAllPoints()
	f.glow = f.regen:CreateTexture(nil, "ARTWORK")
	f.glow:SetTexture(U.WHITE)
	f.glow:SetPoint("BOTTOMLEFT", f, "TOPLEFT")
	f.glow:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT")
	f.glow:SetHeight(5)
	f.pulse = f.regen:CreateAnimationGroup()
	f.pulse:SetLooping("BOUNCE")
	local a = f.pulse:CreateAnimation("Alpha")
	a:SetFromAlpha(1)
	a:SetToAlpha(0.35)
	a:SetDuration(0.9)
	a:SetSmoothing("IN_OUT")

	-- seconds left: with the name text, above the aura icons
	f.text = (v.text or v):CreateFontString(nil, "OVERLAY")
	U.SetFont(f.text, 9, "OUTLINE")
	f.text:Hide()

	f:Hide()
	v.fsr = f
	return f
end

local function Anchor(btn, f)
	local key = btn.powerShown and "power" or "health"
	local shift = btn.visual.missing and btn.visual.missing:IsShown() and -15 or -2
	if f.anchor ~= key then
		f.anchor = key
		local v = btn.visual
		f:ClearAllPoints()
		if key == "power" then
			f:SetPoint("BOTTOMLEFT", v.power, "TOPLEFT")
			f:SetPoint("BOTTOMRIGHT", v.power, "TOPRIGHT")
		else
			f:SetPoint("BOTTOMLEFT", v.health, "BOTTOMLEFT")
			f:SetPoint("BOTTOMRIGHT", v.health, "BOTTOMRIGHT")
		end
	end
	if f.shift ~= shift then
		f.shift = shift
		f.text:ClearAllPoints()
		f.text:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", shift, 1)
	end
end

local function Hide(btn)
	FS.active[btn] = nil
	btn.fsrPhase = nil
	local f = btn.visual and btn.visual.fsr
	if not f then return end
	if f.pulse:IsPlaying() then f.pulse:Stop() end
	f.text:Hide()
	f:Hide()
end

-- phase "count" (left = seconds to go) or "regen".
local function Show(btn, phase, left)
	local C = Settings()
	local f = Build(btn)
	Anchor(btn, f)
	if phase == "count" then
		local c = C.countColor
		if f.phase ~= "count" then
			f.phase = "count"
			f.pulse:Stop()
			f.regen:Hide()
			f.track:Show()
			f.bar:Show()
			f:SetAlpha(1)
		end
		f.bar:SetStatusBarColor(c[1], c[2], c[3], c[4] or 1)
		f.bar:SetValue(left)
		if C.seconds then
			f.text:SetTextColor(c[1], c[2], c[3], 1)
			local n = math.ceil(left)
			if f.shownNumber ~= n then f.shownNumber = n; f.text:SetText(tostring(n)) end
			f.text:Show()
		else
			f.text:Hide()
		end
	else
		local c = C.regenColor
		if f.phase ~= "regen" then
			f.phase = "regen"
			f.track:Hide()
			f.bar:Hide()
			f.text:Hide()
			f.regen:Show()
		end
		f.line:SetVertexColor(c[1], c[2], c[3], (c[4] or 1) * 0.9)
		SetGlowColor(f.glow, c[1], c[2], c[3])
		if not f.pulse:IsPlaying() then f.pulse:Play() end
	end
	f:Show()
	btn.fsrPhase = phase
end

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------
-- true / false when mana can be read, nil when it is secret right now.
local function IsFull(unit)
	local cur, max = UnitPower(unit, 0), UnitPowerMax(unit, 0)
	if issecret(cur) or issecret(max) or type(cur) ~= "number" or type(max) ~= "number" then return nil end
	return max > 0 and cur >= max
end
FS.IsFull = IsFull

-- Mana secret: the client hides the glow at full mana (1 below 100%, 0 at full), when it can.
local function ApplyNotFull(f, unit, curve)
	f:SetAlpha(UnitPowerPercent(unit, 0, false, curve))
end

local driver = CreateFrame("Frame")
driver:Hide()
FS.driver = driver
local acc = 0
driver:SetScript("OnUpdate", function(self, elapsed)
	acc = acc + (elapsed or 0)
	if acc < TICK then return end
	acc = 0
	FS:Tick()
end)

function FS:Tick()
	for btn in pairs(self.active) do self:Update(btn) end
	if next(self.active) == nil then driver:Hide() end
end

function FS:Update(btn)
	if btn.fake or btn.tankTarget or not btn.visual then return end
	local unit = btn.unit
	local guid = unit and UnitExists(unit) and GUIDOf(unit) or nil
	btn.fsrGUID = guid
	local t = guid and FS.spent[guid]
	if not t then Hide(btn) return end
	if not self:Wants(unit) or not UnitIsConnected(unit) or UnitIsDeadOrGhost(unit) then
		if UnitIsDeadOrGhost(unit) then FS.spent[guid] = nil end
		Hide(btn)
		return
	end
	local left = t + DURATION - GetTime()
	if left > 0 then
		Show(btn, "count", left)
		if not self.active[btn] then
			self.active[btn] = true
			driver:Show()
		end
		return
	end
	self.active[btn] = nil
	local full = IsFull(unit)
	if full then
		FS.spent[guid] = nil
		Hide(btn)
		return
	end
	Show(btn, "regen")
	local f = btn.visual.fsr
	if full == nil then
		local curve = UnitPowerPercent and S.NotFullCurve()
		if not (curve and S.Try("5sr-full", ApplyNotFull, f, unit, curve)) then f:SetAlpha(1) end
	else
		f:SetAlpha(1)
	end
end

function FS:UpdateAll()
	if not ns.Buttons then return end
	for _, btn in ipairs(ns.Buttons.all) do
		if btn.unit and btn:IsVisible() then self:Update(btn) end
	end
end

-- Preview frames: a sample on the mana users the setting covers (some counting, some regenerating).
function FS:RenderFake(btn, d, token, index)
	local C = Settings()
	local show = C and C.enabled and token == "MANA" and not d.dead and not d.offline
	if show and C.who == "me" then show = index == 2 end
	if show and C.who == "healers" then
		show = index == 2 or d.role == "HEALER" or (d.role ~= "TANK" and FS.HEALER_CLASSES[d.class] == true)
	end
	if not show then
		local f = btn.visual.fsr
		if f then f.pulse:Stop(); f.text:Hide(); f:Hide() end
		return
	end
	if index % 2 == 0 then Show(btn, "count", 3.4) else Show(btn, "regen") end
	btn.visual.fsr:SetAlpha(1)
	btn.fsrPhase = nil -- preview frames never join the driver
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
ns:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
	FS:OnCast(unit, spellID)
end)

local function OnPower(_, unit)
	local set = unit and ns.Buttons and ns.Buttons.byUnit[unit]
	if not set then return end
	for btn in pairs(set) do
		if btn.unit == unit and btn.fsrPhase == "regen" then FS:Update(btn) end
	end
end
ns:RegisterEvent("UNIT_POWER_UPDATE", OnPower)
ns:RegisterEvent("UNIT_MAXPOWER", OnPower)
ns:RegisterEvent("UNIT_DISPLAYPOWER", function(_, unit)
	local set = unit and ns.Buttons and ns.Buttons.byUnit[unit]
	if not set then return end
	for btn in pairs(set) do
		if btn.unit == unit then FS:Update(btn) end
	end
end)
-- out of combat mana is readable again: hide the glow on whoever is full
ns:RegisterEvent("PLAYER_REGEN_ENABLED", function() FS:UpdateAll() end)
