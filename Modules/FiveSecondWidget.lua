-- Lattice: the 5-second rule ring. A ring with a gap at the top (like a power button) that you can place anywhere.
--
--   filling  after you spend mana, blue fills the ring clockwise from the gap over the 5 seconds (no Spirit regen)
--   burning  the 5 seconds are over and mana is coming back: the ring glows and one gentle blue flame burns in its
--            middle, rising out through the gap, swaying and breathing slowly (or the glow only, with the flame off)
--   idle     full mana: a dim ring
--
-- When it shows: always while being moved; always in combat (never hidden on a guess about full mana); out of combat
-- not at all with "Only in combat" (the default), else hidden at full mana when the game says mana is full. Leaving
-- combat fades it out instead of snapping it away.
--
-- Spends come from Modules/FiveSecond.lua (FS:OnCast calls FW:OnSpend): no second detection here.
-- Cost: nothing runs while idle. The fill is a Cooldown frame (drawn by the client); the end of the 5 seconds is one
-- C_Timer; burning is client-side AnimationGroups (slow, smooth loops; no Lua while they run).
-- Mana is read only through secret-safe calls: when it is secret, the client fades the burning at full mana with a
-- curve (the ring itself stays). Not a secure frame, so it never taints anything; mouse only while moving.
local ADDON, ns = ...
local FS, S, U = ns.FiveSecond, ns.Secret, ns.Util
local Plain = S.Plain
local FW = {}
ns.FiveSecondWidget = FW
FS.Widget = FW

local MEDIA = "Interface\\AddOns\\" .. ADDON .. "\\Media\\FiveSecond\\"
local DURATION = FS.DURATION
local GAP = 36 -- degrees of the gap at the top (tools/fivesecond_art.py draws the same)
-- The fill is a reversed Cooldown: it sweeps a full turn clockwise from 12 o'clock. Started a little early and run a
-- little longer, the part of the ring you see (from one side of the gap to the other) fills in exactly the 5 seconds.
local TURN = DURATION * 360 / (360 - GAP)
local LEAD = TURN * (GAP / 2) / 360
FW.TURN, FW.LEAD = TURN, LEAD

FW.LABEL = "5sR"         -- the ring's name on its move box
local IDLE_ALPHA = 0.22  -- the dim ring at full mana
-- the flame texture: 0.6 x 1.2 of the ring's size, its foot 0.3 below the centre (tools/fivesecond_art.py)
local FLAME_W, FLAME_H, FLAME_FOOT = 0.6, 1.2, 0.3
local SWAY = 0.03        -- how far the flame sways, x size
FW.MIN_SIZE, FW.MAX_SIZE = 16, 160
local FADE_IN, FADE_OUT = 0.25, 0.6

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
local function Tex(parent, file, layer, sub, add)
	local t = parent:CreateTexture(nil, layer, nil, sub)
	t:SetTexture(MEDIA .. file)
	if add then t:SetBlendMode("ADD") end
	return t
end

local function Fade(group, from, to, dur, order, delay)
	local a = group:CreateAnimation("Alpha")
	a:SetFromAlpha(from)
	a:SetToAlpha(to)
	a:SetDuration(dur)
	a:SetOrder(order or 1)
	if delay then a:SetStartDelay(delay) end
	return a
end

function FW:Build()
	if self.frame then return self.frame end
	-- not a secure frame: placed at once, even in combat (a /reload mid-fight)
	local anchor = ns.Mover:GetAnchor("fiveSecond", FW.LABEL, true)
	anchor.wanted = function() return FW:Wanted() end
	anchor:SetFrameStrata("MEDIUM")
	anchor.label:SetText(FW.LABEL)
	anchor.label:ClearAllPoints()
	anchor.label:SetPoint("BOTTOM", 0, 2)
	self.anchor = anchor

	local f = CreateFrame("Frame", "LatticeFiveSecondRing", anchor)
	f:SetAllPoints(anchor)
	f:EnableMouse(false)
	f:Hide()
	self.frame = f
	f.fadeIn = f:CreateAnimationGroup()
	Fade(f.fadeIn, 0, 1, FADE_IN)
	f.fadeOut = f:CreateAnimationGroup()
	Fade(f.fadeOut, 1, 0, FADE_OUT)
	f.fadeOut:SetScript("OnFinished", function() FW:FinishFade() end)

	-- Layers bottom to top, each its own frame: halo, ring, sweep, burning, text. The animations and the client's
	-- full-mana fade (an alpha) never act on the same frame, so one can't undo the other.
	local L = f:GetFrameLevel()
	local function Layer(parent, n)
		local l = CreateFrame("Frame", nil, parent)
		l:SetAllPoints(f)
		l:SetFrameLevel(L + n)
		return l
	end

	-- burning: a soft halo round the ring, breathing slowly
	f.halo = Layer(f, 0)
	f.glow = Tex(f.halo, "glow", "BACKGROUND", 0, true)
	f.glow:SetPoint("CENTER", f, "CENTER")
	f.breathe = f.glow:CreateAnimationGroup()
	f.breathe:SetLooping("BOUNCE")
	Fade(f.breathe, 1, 0.6, 2.2):SetSmoothing("IN_OUT")
	f.halo:Hide()

	local ring = Layer(f, 1)
	f.track = Tex(ring, "track", "BORDER", 0)
	f.track:SetAllPoints()
	f.fill = Tex(ring, "fill", "ARTWORK", 0)
	f.fill:SetAllPoints()

	-- filling: the client draws the sweep (no Lua per frame)
	local cd = CreateFrame("Cooldown", nil, f)
	-- no numbers on the ring: cooldown-text addons (OmniCC, ClassicCooldownCount and others) skip a cooldown with
	-- noCooldownCount, and some turn the game's own countdown back on unless told so
	cd.noCooldownCount, cd.noCCC = true, true
	cd:SetAllPoints()
	cd:SetFrameLevel(L + 2)
	cd:SetSwipeTexture(MEDIA .. "fill")
	cd:SetReverse(true)
	cd:SetDrawEdge(false)
	if cd.SetDrawBling then cd:SetDrawBling(false) end
	f.cd = cd
	-- and never the game's own numbers, whoever turns them on (some addons do): forced off again at once
	FW.NoNumbers(cd)
	if cd.SetHideCountdownNumbers then
		hooksecurefunc(cd, "SetHideCountdownNumbers", function(self, hide)
			if not hide then FW.NoNumbers(self) end
		end)
	end
	cd:HookScript("OnShow", FW.NoNumbers)
	cd:Hide()

	-- burning: everything above the ring
	local burn = Layer(f, 3)
	burn.core = Tex(burn, "core", "ARTWORK", 0, true)  -- white-hot line along the ring
	burn.core:SetAllPoints()
	burn.tint = Tex(burn, "core", "ARTWORK", 1, true)  -- the same, in the glow colour
	burn.tint:SetAllPoints()
	burn.shimmer = burn.core:CreateAnimationGroup()
	burn.shimmer:SetLooping("BOUNCE")
	Fade(burn.shimmer, 0.85, 0.65, 1.8):SetSmoothing("IN_OUT")
	burn:Hide()
	f.burn = burn

	-- the flame: always in the same place. Two shapes on top of each other, the second fading slowly in and out, and
	-- the pair swaying a little from side to side. Slow, smooth loops only: nothing random, nothing jumps.
	local fire = CreateFrame("Frame", nil, burn)
	fire:SetFrameLevel(L + 4)
	fire.anims = {}
	local function Shape(left, right)
		local h = CreateFrame("Frame", nil, fire)
		h:SetAllPoints()
		h.glow = Tex(h, "flame_glow", "ARTWORK", 0, true)
		h.glow:SetAllPoints()
		h.glow:SetTexCoord(left, right, 0, 1)
		h.core = Tex(h, "flame_core", "ARTWORK", 1, true)
		h.core:SetAllPoints()
		h.core:SetTexCoord(left, right, 0, 1)
		return h
	end
	fire.a = Shape(0, 0.5)
	fire.b = Shape(0.5, 1)
	fire.b:SetAlpha(0)
	local morph = fire.b:CreateAnimationGroup()      -- the second shape comes and goes: the flame breathes
	morph:SetLooping("BOUNCE")
	Fade(morph, 0, 1, 2.2):SetSmoothing("IN_OUT")
	local glow = fire.a.core:CreateAnimationGroup()  -- the hot middle glows a little brighter and back
	glow:SetLooping("BOUNCE")
	Fade(glow, 1, 0.75, 1.7):SetSmoothing("IN_OUT")
	local sway = fire:CreateAnimationGroup()          -- and the whole flame sways, slowly
	sway:SetLooping("BOUNCE")
	fire.sway = sway:CreateAnimation("Translation")
	fire.sway:SetDuration(2.4)
	fire.sway:SetSmoothing("IN_OUT")
	fire.anims = { morph, glow, sway }
	fire:Hide()
	f.fire = fire

	-- mp5 under the ring, above the sweep
	local top = Layer(f, 5)
	f.mp5 = top:CreateFontString(nil, "OVERLAY")
	f.mp5:SetPoint("TOP", f, "BOTTOM", 0, -2)
	f.mp5:Hide()
	return f
end

-- No countdown numbers on the ring, ever: the game's own off, and the text addons' flags set.
function FW.NoNumbers(cd)
	cd.noCooldownCount, cd.noCCC, cd.noOCC = true, true, true
	if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(true) end
	local fs = cd.GetCountdownFontString and cd:GetCountdownFontString()
	if fs then fs:SetAlpha(0) end
end

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------
function FW:Apply()
	local C = Settings()
	if not C then return end
	C.seconds = nil -- the number in the middle is gone; a saved choice means nothing now
	local f = self:Build()
	local size = math.max(FW.MIN_SIZE, math.min(FW.MAX_SIZE, tonumber(C.size) or 32))
	self.anchor:SetSize(size, size)
	-- the name on the move box: small, at the bottom
	U.SetFont(self.anchor.label, math.max(8, math.floor(size * 0.12 + 0.5)), "OUTLINE")
	f.glow:SetSize(size * 2, size * 2)
	f.fire:SetSize(size * FLAME_W, size * FLAME_H)
	f.fire:ClearAllPoints()
	f.fire:SetPoint("BOTTOM", f, "CENTER", -size * SWAY / 2, -size * FLAME_FOOT)
	f.fire.sway:SetOffset(size * SWAY, 0)
	U.SetFont(f.mp5, math.max(8, math.floor(size * 0.16 + 0.5)), "OUTLINE")

	local fr, fg, fb = rgb(C.fillColor)
	local br, bg, bb = rgb(C.burnColor)
	local hr, hg, hb = 0.8 + br * 0.2, 0.9 + bg * 0.1, 1 -- white-hot, a touch of the glow colour
	f.cd:SetSwipeColor(fr, fg, fb, 1)
	f.glow:SetVertexColor(br, bg, bb, 0.95)
	f.burn.core:SetVertexColor(1, 1, 1, 0.75)
	f.burn.tint:SetVertexColor(br, bg, bb, 0.5)
	for _, h in ipairs({ f.fire.a, f.fire.b }) do
		h.glow:SetVertexColor(br, bg, bb, 0.85)
		h.core:SetVertexColor(hr, hg, hb, 0.8)
	end
	self.restyle = true -- redraw with the new look
	self.combat = self.combat or InCombatLockdown()
	ns.Mover:RefreshOverlays()
	self:Update()
end

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------
local curves = {}
-- Step curve on the mana fraction: `below` while not full, `full` at 100%.
local function FullCurve(below, full)
	local key = below .. ":" .. full
	if curves[key] ~= nil then return curves[key] or nil end
	local c = false
	if C_CurveUtil and C_CurveUtil.CreateCurve then
		c = C_CurveUtil.CreateCurve()
		if Enum.LuaCurveType then c:SetType(Enum.LuaCurveType.Step) end
		c:AddPoint(0, below)
		c:AddPoint(1, full)
	end
	curves[key] = c
	return c or nil
end

local function SetCurveAlpha(region, below, full)
	local curve = UnitPowerPercent and FullCurve(below, full)
	local ok = curve and S.Try("5sr-ring", function()
		region:SetAlpha(UnitPowerPercent("player", 0, false, curve))
	end)
	if not ok then region:SetAlpha(below) end
end

local function Dead()
	return Plain(UnitIsDeadOrGhost("player"), false) == true
end

-- Mana per 5 seconds: while casting (inside the 5 seconds) or not. nil when the client can't say.
local function Mp5(casting)
	if not GetManaRegen then return nil end
	local ok, base, cast = pcall(GetManaRegen)
	local v = ok and (casting and cast or base) or nil
	if S.IsSecret(v) or type(v) ~= "number" then return nil end
	return math.floor(v * 5 + 0.5)
end

function FW:OnSpend(t)
	self.spentAt = t
	self:Update()
end

-- Wake up when the 5 seconds are over. Only the newest timer counts.
FW.gen = 0
function FW:Schedule(delay)
	self.gen = self.gen + 1
	local gen = self.gen
	C_Timer.After(math.max(0.02, delay), function()
		if gen == self.gen and self.state == "count" then self:Update() end
	end)
end

function FW:Update()
	local f = self.frame
	local C = Settings()
	if not f or not C then return end
	if self:IsMoving() and self:Wanted() then return self:Show("burn", "preview") end
	if not C.enabled or not FS.UsesMana("player") or Dead() then
		if Dead() then self.spentAt = nil end
		return self:Show(nil)
	end
	local combat = self:InCombat()
	local left = self.spentAt and (self.spentAt + DURATION - GetTime()) or 0
	if left <= 0 then self.spentAt = nil end
	-- out of combat with "Only in combat": gone (fading if it was up)
	if C.combatOnly and not combat then return self:Show(nil, true) end
	if left > 0 then return self:Show("count", left) end
	local full = FS.IsFull("player")
	if full then
		-- hidden only out of combat, and only when the game says plainly that mana is full
		if C.hideIdle and not combat then return self:Show(nil, true) end
		return self:Show("idle")
	end
	self:Show("burn", full == nil and "secret" or nil)
end

local function StopBurn(f)
	f.breathe:Stop()
	f.burn.shimmer:Stop()
	for _, g in ipairs(f.fire.anims) do g:Stop() end
	f.fire:Hide()
	f.burn:Hide()
	f.halo:Hide()
end

local function ShowMp5(f, C, casting)
	local v = C.mp5 and Mp5(casting)
	if v then
		f.mp5:SetText(v .. " mp5")
		f.mp5:Show()
	else
		f.mp5:Hide()
	end
end

-- Done fading out (and nothing showed it again meanwhile): really hide.
function FW:FinishFade()
	local f = self.frame
	if self.state ~= nil then return end
	StopBurn(f)
	f.cd:Hide()
	f.mp5:Hide()
	f:Hide()
	f:SetAlpha(1)
end

-- state: nil (hidden; fade = fade out if it is up) | "idle" | "count" (arg = seconds left) |
-- "burn" (arg = nil, "secret" or "preview")
function FW:Show(state, arg)
	local f, C = self.frame, Settings()
	local prev = self.state
	local was = not self.restyle and prev or "restyle"
	self.restyle = nil
	self.state = state
	if not state then
		self.cdStart = nil
		if arg and f:IsShown() and prev ~= nil then
			-- fade out as it is (mid-fill or burning); FinishFade hides it
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
		if was ~= "count" then
			StopBurn(f)
			f.fill:Hide()
		end
		if self.cdStart ~= self.spentAt then
			self.cdStart = self.spentAt
			f.cd:SetCooldown(self.spentAt - LEAD, TURN)
			FW.NoNumbers(f.cd)
		end
		f.cd:Show()
		ShowMp5(f, C, true)
		self:Schedule(arg)
		return
	end

	self.cdStart = nil
	f.cd:Hide()
	f.fill:Show()
	if state == "idle" then
		if was ~= "idle" then StopBurn(f) end
		f.fill:SetVertexColor(rgb(C.fillColor))
		f.fill:SetAlpha(IDLE_ALPHA)
		f.mp5:Hide()
		return
	end

	-- burning
	f.fill:SetVertexColor(rgb(C.burnColor))
	f.halo:Show()
	f.burn:Show()
	if not f.breathe:IsPlaying() then f.breathe:Play() end
	if not f.burn.shimmer:IsPlaying() then f.burn.shimmer:Play() end
	if C.lightning then -- the flame (saved under its first name)
		if not f.fire:IsShown() then
			f.fire:Show()
			for _, g in ipairs(f.fire.anims) do g:Play() end
		end
	elseif f.fire:IsShown() then
		for _, g in ipairs(f.fire.anims) do g:Stop() end
		f.fire:Hide()
	end
	if arg == "secret" then
		-- mana can't be read (combat, instances): the client calms the burning at full mana; the ring stays
		SetCurveAlpha(f.burn, 1, 0)
		SetCurveAlpha(f.halo, 1, 0)
		SetCurveAlpha(f.fill, 1, IDLE_ALPHA)
	else
		f.burn:SetAlpha(1)
		f.halo:SetAlpha(1)
		f.fill:SetAlpha(1)
	end
	ShowMp5(f, C, false)
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
	-- while filling, the timer does the work
	if FW.state == "count" and FW.spentAt and FW.spentAt + DURATION > GetTime() then return end
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
