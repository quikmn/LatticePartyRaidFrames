-- Lattice: the 5Sr bar. A thin bar you can place anywhere, for your own 5-second rule.
--
--   filling  after you spend mana the bar counts up, left to right, over the 5 seconds (no Spirit regen), muted blue
--   bright   the 5 seconds are over and mana is coming back: full and bright, a soft slow glow, "mp5: N" beside it
--   full     at full mana: hidden out of combat; in combat a dim full bar (it never hides in combat)
--
-- When it shows: always while being moved; always in combat; out of combat not at all with "Only in combat" (the
-- default), else unless the game says plainly that mana is full. Leaving combat fades it out.
--
-- Spends come from Modules/FiveSecond.lua (FS:OnCast calls FW:OnSpend), which also handles the secret cases (spell ID
-- from the cast GUID, costs learned out of combat, your casts under any unit name, your power type remembered).
-- Cost: nothing runs unless filling; then FiveSecond's shared driver moves the bar (25 times a second, 5 seconds).
-- No numbers anywhere: a StatusBar, no Cooldown frame. Not a secure frame; mouse only while moving.
local _, ns = ...
local FS, S, U, T = ns.FiveSecond, ns.Secret, ns.Util, ns.Theme
local Plain = S.Plain
local FW = {}
ns.FiveSecondWidget = FW
FS.Widget = FW

local DURATION = FS.DURATION
FW.LABEL = "5Sr"
FW.MIN_W, FW.MAX_W, FW.MIN_H, FW.MAX_H = 40, 400, 4, 40
local FULL_ALPHA = 0.4   -- the dim full bar at full mana in combat
local FADE_IN, FADE_OUT = 0.25, 0.6
-- settings of the ring this bar replaced: dropped when seen
FW.GONE = { "size", "hideIdle", "lightning", "burnColor", "seconds" }

local function Settings() return ns.db and ns.db.appearance.fiveSecond.widget end
local function rgb(c) return c[1], c[2], c[3] end

function FW:Enabled()
	local C = Settings()
	return C and C.enabled and true or false
end

-- On, and you use mana (or you asked to move it).
function FW:Wanted()
	return self:Enabled() and (FS.UsesMana("player") or (ns.Mover and ns.Mover:IsSolo("fiveSecond"))) and true or false
end

function FW:IsMoving()
	return ns.Mover and (ns.Mover:IsUnlocked() or ns.Mover:IsSolo("fiveSecond")) and true or false
end

-- In combat: our own flag from PLAYER_REGEN_DISABLED/ENABLED (InCombatLockdown is still false while the first one
-- fires), or the game's lockdown after a /reload mid-fight.
function FW:InCombat()
	return (self.combat or InCombatLockdown()) and true or false
end

------------------------------------------------------------------------
-- Frame
------------------------------------------------------------------------
local function Fade(group, from, to, dur)
	local a = group:CreateAnimation("Alpha")
	a:SetFromAlpha(from)
	a:SetToAlpha(to)
	a:SetDuration(dur)
	return a
end

function FW:Build()
	if self.frame then return self.frame end
	-- not a secure frame: placed at once, even in combat (a /reload mid-fight)
	local anchor = ns.Mover:GetAnchor("fiveSecond", FW.LABEL, true)
	anchor.wanted = function() return FW:Wanted() end
	anchor:SetFrameStrata("MEDIUM")
	anchor.label:SetText(FW.LABEL)
	U.SetFont(anchor.label, 8, "OUTLINE")
	self.anchor = anchor

	local f = CreateFrame("Frame", "LatticeFiveSecondBar", anchor)
	f:SetAllPoints(anchor)
	f:EnableMouse(false)
	f:Hide()
	self.frame = f
	f.fadeIn = f:CreateAnimationGroup()
	Fade(f.fadeIn, 0, 1, FADE_IN)
	f.fadeOut = f:CreateAnimationGroup()
	Fade(f.fadeOut, 1, 0, FADE_OUT)
	f.fadeOut:SetScript("OnFinished", function() FW:FinishFade() end)

	-- bright: a soft glow round the bar, breathing slowly
	f.glow = CreateFrame("Frame", nil, f)
	f.glow:SetAllPoints()
	f.glow.outer = U.Solid(f.glow, "BACKGROUND", 1, 1, 1, 1)
	f.glow.outer:SetPoint("TOPLEFT", -3, 3)
	f.glow.outer:SetPoint("BOTTOMRIGHT", 3, -3)
	f.glow.inner = U.Solid(f.glow, "BACKGROUND", 1, 1, 1, 1, 1)
	f.glow.inner:SetPoint("TOPLEFT", -1.5, 1.5)
	f.glow.inner:SetPoint("BOTTOMRIGHT", 1.5, -1.5)
	f.glow.breathe = f.glow:CreateAnimationGroup()
	f.glow.breathe:SetLooping("BOUNCE")
	Fade(f.glow.breathe, 1, 0.45, 1.8):SetSmoothing("IN_OUT")
	f.glow:Hide()

	-- the track: dark, with a 1 px border (Lattice's look)
	f.track = U.Solid(f, "BORDER", 0.05, 0.06, 0.08, 0.9)
	f.track:SetAllPoints()
	U.Border(f, 1, T.border[1], T.border[2], T.border[3], 1)

	f.bar = CreateFrame("StatusBar", nil, f)
	f.bar:SetPoint("TOPLEFT", 1, -1)
	f.bar:SetPoint("BOTTOMRIGHT", -1, 1)
	f.bar:SetStatusBarTexture("Interface\\AddOns\\LatticePartyRaidFrames\\Media\\Bar")
	f.bar:SetMinMaxValues(0, DURATION)
	f.bar:SetValue(0)

	f.label = f.bar:CreateFontString(nil, "OVERLAY")
	f.label:SetPoint("RIGHT", f, "LEFT", -4, 0)
	f.mp5 = f.bar:CreateFontString(nil, "OVERLAY")
	f.mp5:SetPoint("LEFT", f, "RIGHT", 4, 0)
	f.mp5:Hide()
	return f
end

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------
function FW:Apply()
	local C = Settings()
	if not C then return end
	for _, k in ipairs(FW.GONE) do C[k] = nil end
	local f = self:Build()
	local w = math.max(FW.MIN_W, math.min(FW.MAX_W, tonumber(C.width) or 120))
	local h = math.max(FW.MIN_H, math.min(FW.MAX_H, tonumber(C.height) or 10))
	self.anchor:SetSize(w, h)
	local font = math.max(8, math.min(14, math.floor(h * 0.9 + 0.5)))
	U.SetFont(f.label, font, "OUTLINE")
	U.SetFont(f.mp5, font, "OUTLINE")
	f.label:SetText(FW.LABEL)
	local br, bg, bb = rgb(C.brightColor)
	f.glow.outer:SetVertexColor(br, bg, bb, 0.12)
	f.glow.inner:SetVertexColor(br, bg, bb, 0.25)
	self.combat = self.combat or InCombatLockdown()
	ns.Mover:RefreshOverlays()
	self:Update()
end

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------
local notFull
-- 1 while mana is below full, 0 at full: evaluated by the client when mana is secret.
local function NotFullCurve()
	if notFull ~= nil then return notFull or nil end
	notFull = false
	if C_CurveUtil and C_CurveUtil.CreateCurve then
		notFull = C_CurveUtil.CreateCurve()
		if Enum.LuaCurveType then notFull:SetType(Enum.LuaCurveType.Step) end
		notFull:AddPoint(0, 1)
		notFull:AddPoint(1, 0)
	end
	return notFull or nil
end

local function Dead()
	return Plain(UnitIsDeadOrGhost("player"), false) == true
end

-- Mana per 5 seconds outside the 5 seconds. nil when the client can't say.
function FW.Mp5()
	if not GetManaRegen then return nil end
	local ok, base = pcall(GetManaRegen)
	if not ok or S.IsSecret(base) or type(base) ~= "number" then return nil end
	return math.floor(base * 5 + 0.5)
end

function FW:OnSpend(t)
	self.spentAt = t
	self:Update()
end

-- Called by FiveSecond's shared driver while filling.
function FW:Tick()
	if self.state ~= "count" then self.counting = false return end
	local left = self.spentAt and (self.spentAt + DURATION - GetTime()) or 0
	if left <= 0 then
		self.counting = false
		self:Update()
		return
	end
	self.frame.bar:SetValue(DURATION - left)
end

function FW:Update()
	local f = self.frame
	local C = Settings()
	if not f or not C then return end
	if self:IsMoving() and self:Wanted() then return self:Show("bright", "preview") end
	if not C.enabled or not FS.UsesMana("player") or Dead() then
		if Dead() then self.spentAt = nil end
		return self:Show(nil)
	end
	local combat = self:InCombat()
	local left = self.spentAt and (self.spentAt + DURATION - GetTime()) or 0
	if left <= 0 then self.spentAt = nil end
	if C.combatOnly and not combat then return self:Show(nil, true) end
	if left > 0 then return self:Show("count", left) end
	local full = FS.IsFull("player")
	if full then
		-- hidden only out of combat, and only when the game says plainly that mana is full
		if not combat then return self:Show(nil, true) end
		return self:Show("full")
	end
	self:Show("bright", full == nil and "secret" or nil)
end

-- Done fading out (and nothing showed it again meanwhile): really hide.
function FW:FinishFade()
	local f = self.frame
	if self.state ~= nil then return end
	f.glow.breathe:Stop()
	f.glow:Hide()
	f.mp5:Hide()
	f:Hide()
	f:SetAlpha(1)
end

-- state: nil (hidden; fade = fade out if it is up) | "count" (arg = seconds left) | "bright" (arg = nil, "secret" or
-- "preview") | "full"
function FW:Show(state, arg)
	local f, C = self.frame, Settings()
	local prev = self.state
	self.state = state
	self.counting = state == "count"
	if not state then
		if arg and f:IsShown() and prev ~= nil then
			f.fadeIn:Stop()
			if not f.fadeOut:IsPlaying() then f.fadeOut:Play() end
			return
		end
		if f.fadeOut:IsPlaying() and arg then return end
		f.fadeOut:Stop()
		self:FinishFade()
		return
	end
	if f.fadeOut:IsPlaying() then f.fadeOut:Stop() end
	f:SetAlpha(1)
	if not f:IsShown() then
		f:Show()
		f.fadeIn:Play()
	end

	if state == "count" then
		local r, g, b = rgb(C.fillColor)
		f.bar:SetStatusBarColor(r, g, b, 1)
		f.bar:SetValue(DURATION - arg)
		f.glow.breathe:Stop()
		f.glow:Hide()
		f.mp5:Hide()
		FS.driver:Show() -- the shared driver moves the bar
		return
	end

	f.bar:SetValue(DURATION)
	if state == "full" then
		local r, g, b = rgb(C.fillColor)
		f.bar:SetStatusBarColor(r, g, b, FULL_ALPHA)
		f.glow.breathe:Stop()
		f.glow:Hide()
		f.mp5:Hide()
		return
	end

	-- bright
	local r, g, b = rgb(C.brightColor)
	f.bar:SetStatusBarColor(r, g, b, 1)
	f.glow:Show()
	if not f.glow.breathe:IsPlaying() then f.glow.breathe:Play() end
	if arg == "secret" then
		-- mana can't be read (combat, instances): the client turns the glow off at full mana; the bar stays
		local curve = UnitPowerPercent and NotFullCurve()
		local ok = curve and S.Try("5sr-bar", function() f.glow:SetAlpha(UnitPowerPercent("player", 0, false, curve)) end)
		if not ok then f.glow:SetAlpha(1) end
	else
		f.glow:SetAlpha(1)
	end
	local v = C.mp5 and FW.Mp5()
	if v then
		f.mp5:SetText("mp5: " .. v)
		f.mp5:SetTextColor(r, g, b, 1)
		f.mp5:Show()
	else
		f.mp5:Hide()
	end
end

------------------------------------------------------------------------
-- Commands (/lattice 5sr widget|move|lock) and events
------------------------------------------------------------------------
function FW:SetEnabled(on)
	Settings().enabled = on and true or false
	if not on and ns.Mover:IsSolo("fiveSecond") then ns.Mover:SetSolo("fiveSecond", false) end
	self:Apply()
end

-- on: true moves it on its own (frames stay locked), false locks it. Returns whether it is moving now.
function FW:SetMoving(on)
	self:Build()
	if on and not self:Enabled() then
		Settings().enabled = true
		self:Apply()
	end
	ns.Mover:SetSolo("fiveSecond", on)
	return ns.Mover:IsSolo("fiveSecond")
end

ns:RegisterEvent("PLAYER_LOGIN", function()
	if not ns.db then return end
	FW:Apply()
end)

ns:Listen("MoverChanged", function() FW:Update() end)

local function OnPower(_, unit)
	if unit ~= "player" or not FW.frame then return end
	if FW.state == "count" then return end -- the driver does the work while filling
	FW:Update()
end
ns:RegisterEvent("UNIT_POWER_UPDATE", OnPower)
ns:RegisterEvent("UNIT_MAXPOWER", OnPower)
ns:RegisterEvent("UNIT_DISPLAYPOWER", function(_, unit) if unit == "player" then FW:Update() end end)
ns:RegisterEvent("PLAYER_REGEN_DISABLED", function() FW.combat = true; FW:Update() end)
ns:RegisterEvent("PLAYER_REGEN_ENABLED", function() FW.combat = false; FW:Update() end)
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST" }) do
	ns:RegisterEvent(e, function() FW:Update() end)
end
