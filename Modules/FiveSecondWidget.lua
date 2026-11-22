-- Lattice: the 5-second rule ring. A ring with a gap at the top (like a power button) that you can place anywhere.
--
--   filling  after you spend mana, blue fills the ring clockwise from the gap over the 5 seconds (no Spirit regen)
--   burning  the 5 seconds are over and mana is coming back: the ring glows, lightning crackles around it and rises
--            out of the gap (or a calm glow only, with lightning off)
--   idle     full mana: a dim ring, or hidden (the default)
--
-- Spends come from Modules/FiveSecond.lua (FS:OnCast calls FW:OnSpend): no second detection here.
-- Cost: nothing runs while idle. The fill is a Cooldown frame (drawn by the client); the seconds number and the end of
-- the 5 seconds are a few C_Timer calls; burning is client-side AnimationGroups (a couple of tiny OnLoop calls per
-- second pick the next lightning sprite). Mana is read only through secret-safe calls: when it is secret, the client
-- fades the glow at full mana with a curve. Not a secure frame, so it never taints anything; mouse only while moving.
local ADDON, ns = ...
local FS, S, U = ns.FiveSecond, ns.Secret, ns.Util
local issecret, Plain = S.IsSecret, S.Plain
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

local IDLE_ALPHA = 0.22  -- the dim ring at full mana
local WISP_BASE = 0.2    -- wisps start this far (x size) above the centre, inside the gap
local WISP_RISE = 0.25

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

-- A sprite: a glow layer (tinted) and a white-hot core layer, sharing texture coordinates.
local function Sprite(parent, file)
	local h = CreateFrame("Frame", nil, parent)
	h.glow = Tex(h, file .. "_glow", "ARTWORK", 0, true)
	h.glow:SetAllPoints()
	h.core = Tex(h, file .. "_core", "ARTWORK", 1, true)
	h.core:SetAllPoints()
	h:SetAlpha(0)
	return h
end

-- cells: list of { left, right, top, bottom }; a random one (sometimes mirrored) on each loop.
local function PickCell(h, cells)
	local c = cells[math.random(#cells)]
	local l, r = c[1], c[2]
	if math.random() < 0.5 then l, r = r, l end
	h.glow:SetTexCoord(l, r, c[3], c[4])
	h.core:SetTexCoord(l, r, c[3], c[4])
end

local ARC_CELLS = { { 0, 0.5, 0, 0.5 }, { 0.5, 1, 0, 0.5 }, { 0, 0.5, 0.5, 1 }, { 0.5, 1, 0.5, 1 } }
local WISP_CELLS = { { 0, 0.25, 0, 1 }, { 0.25, 0.5, 0, 1 }, { 0.5, 0.75, 0, 1 }, { 0.75, 1, 0, 1 } }
-- different periods, so the flashes never fall into a pattern
local ARC_WAIT = { 0.6, 1.0, 1.5 }
local WISP_TIME = { 1.05, 1.3, 1.6 }

function FW:Build()
	if self.frame then return self.frame end
	local anchor = ns.Mover:GetAnchor("fiveSecond", "5SR")
	anchor.wanted = function() return FW:Wanted() end
	anchor:SetFrameStrata("MEDIUM")
	self.anchor = anchor

	local f = CreateFrame("Frame", "LatticeFiveSecondRing", anchor)
	f:SetAllPoints(anchor)
	f:EnableMouse(false)
	f:Hide()
	self.frame = f

	-- Layers bottom to top, each its own frame: halo, ring, sweep, burning, text. The animations and the client's
	-- full-mana fade (an alpha) never act on the same frame, so one can't undo the other.
	local L = f:GetFrameLevel()
	local function Layer(parent, n)
		local l = CreateFrame("Frame", nil, parent)
		l:SetAllPoints(f)
		l:SetFrameLevel(L + n)
		return l
	end

	-- burning: a soft halo (with a plume rising out of the gap), breathing
	f.halo = Layer(f, 0)
	f.glow = Tex(f.halo, "glow", "BACKGROUND", 0, true)
	f.glow:SetPoint("CENTER", f, "CENTER")
	f.breathe = f.glow:CreateAnimationGroup()
	f.breathe:SetLooping("BOUNCE")
	Fade(f.breathe, 1, 0.55, 1.2):SetSmoothing("IN_OUT")
	f.halo:Hide()

	local ring = Layer(f, 1)
	f.track = Tex(ring, "track", "BORDER", 0)
	f.track:SetAllPoints()
	f.fill = Tex(ring, "fill", "ARTWORK", 0)
	f.fill:SetAllPoints()

	-- filling: the client draws the sweep (no Lua per frame)
	local cd = CreateFrame("Cooldown", nil, f)
	cd:SetAllPoints()
	cd:SetFrameLevel(L + 2)
	cd:SetSwipeTexture(MEDIA .. "fill")
	cd:SetReverse(true)
	cd:SetDrawEdge(false)
	if cd.SetDrawBling then cd:SetDrawBling(false) end
	if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(true) end
	cd:Hide()
	f.cd = cd

	-- burning: everything above the ring
	local burn = Layer(f, 3)
	burn.core = Tex(burn, "core", "ARTWORK", 0, true)  -- white-hot line along the ring
	burn.core:SetAllPoints()
	burn.tint = Tex(burn, "core", "ARTWORK", 1, true)  -- the same, in the glow colour
	burn.tint:SetAllPoints()
	burn.shimmer = burn.core:CreateAnimationGroup()
	burn.shimmer:SetLooping("BOUNCE")
	Fade(burn.shimmer, 0.85, 0.55, 0.45):SetSmoothing("IN_OUT")
	burn:Hide()
	f.burn = burn

	-- lightning: crackles on the ring and wisps rising out of the gap
	local sparks = CreateFrame("Frame", nil, burn)
	sparks:SetAllPoints()
	sparks.anims = {}
	for i = 1, #ARC_WAIT do
		local h = Sprite(sparks, "arcs")
		h:SetPoint("CENTER", f, "CENTER")
		local g = h:CreateAnimationGroup()
		g:SetLooping("REPEAT")
		Fade(g, 0, 1, 0.05, 1, ARC_WAIT[i])
		Fade(g, 1, 0, 0.25, 2)
		g:SetScript("OnLoop", function() PickCell(h, ARC_CELLS) end)
		PickCell(h, ARC_CELLS)
		sparks[#sparks + 1] = h
		sparks.anims[#sparks.anims + 1] = g
	end
	sparks.wisps = {}
	for i = 1, #WISP_TIME do
		local h = Sprite(sparks, "wisps")
		local g = h:CreateAnimationGroup()
		g:SetLooping("REPEAT")
		h.rise = g:CreateAnimation("Translation")
		h.rise:SetDuration(WISP_TIME[i])
		h.rise:SetOrder(1)
		Fade(g, 0, 1, 0.12, 1)
		Fade(g, 1, 0, WISP_TIME[i] * 0.55, 1, WISP_TIME[i] * 0.4)
		g:SetScript("OnLoop", function()
			PickCell(h, WISP_CELLS)
			FW:PlaceWisp(h, (math.random() - 0.5) * 0.14)
		end)
		PickCell(h, WISP_CELLS)
		sparks.wisps[i] = h
		sparks.anims[#sparks.anims + 1] = g
	end
	sparks:Hide()
	f.sparks = sparks

	-- text above the sweep
	local top = Layer(f, 4)
	f.text = top:CreateFontString(nil, "OVERLAY")
	f.text:SetPoint("CENTER")
	f.text:Hide()
	f.mp5 = top:CreateFontString(nil, "OVERLAY")
	f.mp5:SetPoint("TOP", f, "BOTTOM", 0, -2)
	f.mp5:Hide()
	return f
end

function FW:PlaceWisp(h, dx)
	local size = Settings().size
	h:ClearAllPoints()
	h:SetPoint("BOTTOM", self.frame, "CENTER", (dx or 0) * size, WISP_BASE * size)
end

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------
function FW:Apply()
	local C = Settings()
	if not C then return end
	local f = self:Build()
	local size = math.max(24, math.min(256, tonumber(C.size) or 64))
	self.anchor:SetSize(size, size)
	f.glow:SetSize(size * 2, size * 2)
	for _, h in ipairs(f.sparks) do h:SetSize(size * 2, size * 2) end
	for _, h in ipairs(f.sparks.wisps) do
		h:SetSize(size * 0.5, size)
		h.rise:SetOffset(0, size * WISP_RISE)
		self:PlaceWisp(h, 0)
	end
	U.SetFont(f.text, math.max(9, math.floor(size * 0.24 + 0.5)), "OUTLINE")
	U.SetFont(f.mp5, math.max(8, math.floor(size * 0.16 + 0.5)), "OUTLINE")

	local fr, fg, fb = rgb(C.fillColor)
	local br, bg, bb = rgb(C.burnColor)
	f.cd:SetSwipeColor(fr, fg, fb, 1)
	f.glow:SetVertexColor(br, bg, bb, 0.95)
	f.burn.core:SetVertexColor(1, 1, 1, 0.75)
	f.burn.tint:SetVertexColor(br, bg, bb, 0.5)
	for _, h in ipairs(f.sparks) do
		h.glow:SetVertexColor(br, bg, bb, 0.95)
		h.core:SetVertexColor(0.85 + br * 0.15, 0.9 + bg * 0.1, 1, 1)
	end
	for _, h in ipairs(f.sparks.wisps) do
		h.glow:SetVertexColor(br, bg, bb, 0.95)
		h.core:SetVertexColor(0.85 + br * 0.15, 0.9 + bg * 0.1, 1, 1)
	end
	self.state = nil -- redraw with the new look
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
	if issecret(v) or type(v) ~= "number" then return nil end
	return math.floor(v * 5 + 0.5)
end

function FW:OnSpend(t)
	self.spentAt = t
	self:Update()
end

-- Wake up at the next whole second of the countdown (or its end). Only the newest timer counts.
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
	if not f then return end
	local C = Settings()
	if self:IsMoving() and self:Wanted() then return self:Show("burn", "preview") end
	if not C.enabled or not FS.UsesMana("player") or Dead() then
		if Dead() then self.spentAt = nil end
		return self:Show(nil)
	end
	local left = self.spentAt and (self.spentAt + DURATION - GetTime()) or 0
	if left > 0 then return self:Show("count", left) end
	self.spentAt = nil
	local full = FS.IsFull("player")
	if full then return self:Show("idle") end
	self:Show("burn", full == nil and "secret" or nil)
end

local function StopBurn(f)
	f.breathe:Stop()
	f.burn.shimmer:Stop()
	for _, g in ipairs(f.sparks.anims) do g:Stop() end
	f.sparks:Hide()
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

-- state: nil (hidden) | "idle" | "count" (arg = seconds left) | "burn" (arg = nil, "secret" or "preview")
function FW:Show(state, arg)
	local f, C = self.frame, Settings()
	if state == "idle" and C.hideIdle then state = nil end
	local was = self.state
	self.state = state
	if not state then
		if was then StopBurn(f); f.cd:Hide() end
		self.cdStart = nil
		f.text:Hide()
		f.mp5:Hide()
		f:Hide()
		return
	end
	f:SetAlpha(1)
	f:Show()

	if state == "count" then
		if was ~= "count" then
			StopBurn(f)
			f.fill:Hide()
		end
		if self.cdStart ~= self.spentAt then
			self.cdStart = self.spentAt
			f.cd:SetCooldown(self.spentAt - LEAD, TURN)
		end
		f.cd:Show()
		local whole = math.ceil(arg)
		if C.seconds then
			f.text:SetText(tostring(whole))
			f.text:SetTextColor(1, 1, 1, 1)
			f.text:Show()
		else
			f.text:Hide()
		end
		ShowMp5(f, C, true)
		-- the next whole second when the number shows; else just the end
		self:Schedule(C.seconds and (arg - (whole - 1)) or arg)
		return
	end

	self.cdStart = nil
	f.cd:Hide()
	f.text:Hide()
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
	if C.lightning then
		if not f.sparks:IsShown() then
			f.sparks:Show()
			for _, g in ipairs(f.sparks.anims) do g:Play() end
		end
	elseif f.sparks:IsShown() then
		for _, g in ipairs(f.sparks.anims) do g:Stop() end
		f.sparks:Hide()
	end
	if arg == "secret" then
		-- mana can't be read (combat, instances): the client fades the burning at full mana
		SetCurveAlpha(f.burn, 1, 0)
		SetCurveAlpha(f.halo, 1, 0)
		SetCurveAlpha(f.fill, 1, IDLE_ALPHA)
		if C.hideIdle then SetCurveAlpha(f, 1, 0) end
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
	-- while filling, the timers do the work
	if FW.state == "count" and FW.spentAt and FW.spentAt + DURATION > GetTime() then return end
	FW:Update()
end
ns:RegisterEvent("UNIT_POWER_UPDATE", OnPower)
ns:RegisterEvent("UNIT_MAXPOWER", OnPower)
ns:RegisterEvent("UNIT_DISPLAYPOWER", function(_, unit) if unit == "player" then FW:Update() end end)
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST", "PLAYER_REGEN_ENABLED" }) do
	ns:RegisterEvent(e, function() FW:Update() end)
end
