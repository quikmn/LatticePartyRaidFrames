-- Offline test run for Lattice. Loads the addon in TOC order against wowmock.lua
-- and drives login, group changes, combat, options pages, preview and profiles.
local ROOT = ...
local ADDON = "Lattice"
local ns = {}
local failures, passes = {}, 0

local function step(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passes = passes + 1
		print("  ok   " .. name)
	else
		failures[#failures + 1] = name .. ": " .. tostring(err)
		print("  FAIL " .. name .. "\n         " .. tostring(err))
	end
end

local function check(cond, msg) if not cond then error(msg, 2) end end

-- Taint guard: every global the addon assigns (at load or later) is recorded, and
-- Blizzard's party/raid frames record any :Hide() call. Addon code must not write
-- Blizzard globals or run Blizzard Lua on Blizzard frames (in WoW Forever that taints
-- Blizzard's UI and its secret-value checks fail, e.g. closing the character sheet).
local globalWrites = {}
local addonEnv = setmetatable({}, {
	__index = _G,
	__newindex = function(_, k, v) globalWrites[k] = true; _G[k] = v end,
})
local BLIZZARD_FRAMES = { "PartyFrame", "CompactPartyFrame", "CompactRaidFrameContainer" }
local blizzardHides = {}
for _, name in ipairs(BLIZZARD_FRAMES) do
	local f = _G[name]
	f:SetParent(UIParent)
	f.Hide = function() blizzardHides[#blizzardHides + 1] = name end
end

-- Load files listed in the TOC
step("load TOC files", function()
	local toc = assert(io.open(ROOT .. "/LatticePartyRaidFrames.toc")):read("*a")
	for line in toc:gmatch("[^\r\n]+") do
		if not line:match("^%s*#") and line:match("%.lua%s*$") then
			local path = ROOT .. "/" .. line:gsub("\\", "/"):gsub("%s+$", "")
			local chunk, err = loadfile(path)
			if not chunk then error("syntax: " .. err) end
			setfenv(chunk, addonEnv)
			chunk(ADDON, ns)
		end
	end
end)

step("ADDON_LOADED + PLAYER_LOGIN", function()
	MOCK.Fire("ADDON_LOADED", ADDON)
	check(ns.db and ns.char, "db not initialised")
	ns.db.debug = true
	MOCK.Fire("PLAYER_LOGIN")
	MOCK.Fire("PLAYER_ENTERING_WORLD")
	MOCK.RunTimers()
	check(#ns.Buttons.all >= 5 + 40 + 40, "expected pre-created buttons, got " .. #ns.Buttons.all)
end)

local function shownUnits()
	local n, units = 0, {}
	for _, b in ipairs(ns.Buttons.all) do
		if b.unit then n = n + 1; units[#units + 1] = b.unit end
	end
	return n, units
end

step("solo shows nothing by default", function()
	MOCK.UpdateAllHeaders()
	local n, units = shownUnits()
	-- party header has showSolo=false by default
	check(n == 0, "solo should show 0 units, got " .. n .. " (" .. table.concat(units, ",") .. ")")
end)

step("party of 5", function()
	MOCK.SetGroup(5, false)
	MOCK.Fire("GROUP_ROSTER_UPDATE")
	MOCK.UpdateAllHeaders()
	MOCK.RunTimers()
	local n = shownUnits()
	check(n == 5, "party should show 5 units, got " .. n)
end)

step("unit events in party (secret values)", function()
	for _, u in ipairs({ "player", "party1", "party2", "party3", "party4" }) do
		for _, e in ipairs({ "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_POWER_UPDATE", "UNIT_HEAL_PREDICTION",
			"UNIT_ABSORB_AMOUNT_CHANGED", "UNIT_CONNECTION", "UNIT_NAME_UPDATE", "UNIT_FLAGS", "UNIT_IN_RANGE_UPDATE",
			"UNIT_THREAT_SITUATION_UPDATE", "UNIT_DISPLAYPOWER" }) do
			MOCK.Fire(e, u)
		end
	end
	MOCK.Fire("PLAYER_TARGET_CHANGED")
	MOCK.Fire("RAID_TARGET_UPDATE")
	MOCK.Fire("PARTY_LEADER_CHANGED")
	MOCK.RunTimers()
end)

step("all appearance modes render without touching secrets", function()
	for _, mode in ipairs({ "class", "custom", "gradient" }) do
		ns.db.appearance.healthColor = mode
		for _, st in ipairs({ "none", "percent", "deficit" }) do
			ns.db.appearance.statusText = st
			ns.Buttons:UpdateAllButtons()
		end
	end
end)

step("raid of 40 out of combat", function()
	MOCK.SetGroup(40, true)
	MOCK.Fire("GROUP_ROSTER_UPDATE")
	MOCK.RunTimers()
	MOCK.UpdateAllHeaders()
	local n = shownUnits()
	check(n >= 40, "raid should show 40 units, got " .. n)
	check(ns.Headers.activeLayout == "raid40", "expected large raid layout, got " .. tostring(ns.Headers.activeLayout))
end)

step("combat: roster change + events without protected calls", function()
	MOCK.Fire("PLAYER_REGEN_DISABLED")
	MOCK.combat = true
	MOCK.SetGroup(20, true)
	MOCK.Fire("GROUP_ROSTER_UPDATE") -- our handler must defer layout work
	MOCK.UpdateAllHeaders()          -- secure header reassigns units
	for i = 1, 20 do MOCK.Fire("UNIT_HEALTH", "raid" .. i) end
	MOCK.Fire("READY_CHECK", "Leader", 30)
	MOCK.Fire("READY_CHECK_CONFIRM", "raid2", true)
	MOCK.Fire("READY_CHECK_FINISHED", false)
	ns:ApplySettings("layout") -- queued
	MOCK.RunTimers()
	MOCK.combat = false
	MOCK.Fire("PLAYER_REGEN_ENABLED")
	MOCK.RunTimers()
	check(ns.Headers.activeLayout == "raid", "after combat expected raid layout, got " .. tostring(ns.Headers.activeLayout))
end)

step("click-cast bindings set attributes", function()
	ns.ClickCast:Add({ button = 1, mods = "shift", action = "spell", value = 774 })
	ns.ClickCast:Add({ button = 2, mods = "ctrl", action = "macro", value = "/cast [@mouseover] Renew" })
	MOCK.RunTimers()
	local b = ns.Buttons.all[1]
	check(b:GetAttribute("shift-type1") == "spell", "shift-type1 not set")
	check(b:GetAttribute("shift-spell1") == "Spell774", "shift-spell1 = " .. tostring(b:GetAttribute("shift-spell1")))
	check(b:GetAttribute("ctrl-type2") == "macro", "ctrl-type2 not set")
	check(b:GetAttribute("type1") == "target", "type1 should stay target")
	ns.ClickCast:Remove(1)
end)

step("aura containers + indicator by spell name", function()
	local ids = ns.Auras:ResolveSpells("Rejuvenation")
	check(#ids >= 2, "expected both Rejuvenation ranks, got " .. #ids)
	ns.Auras:AddIndicator("Rejuvenation", ids)
	MOCK.RunTimers()
	local b = ns.Buttons.all[1]
	check(b.auraContainers and #b.auraContainers >= 3, "expected aura containers on buttons")
	for _, style in ipairs({ "border", "both", "overlay", "icon" }) do
		ns.db.auras.dispel.style = style
		ns.Auras:Refresh()
	end
	ns.db.auras.debuffs.onlyDispellable = true
	ns.Auras:Refresh()
end)

step("pet frames follow the group", function()
	ns.db.general.showPets = true
	MOCK.SetGroup(3, false)
	MOCK.units.partypet2 = { name = "Imp", class = "WARRIOR", role = "NONE", hp = 100, maxhp = 200, power = 1, maxpower = 1, connected = true }
	ns:ApplySettingsNow("layout")
	MOCK.RunTimers()
	MOCK.UpdateAllHeaders()
	local found = {}
	for child in ns.Headers.Children(ns.Headers.pets) do
		local u = child:GetAttribute("unit")
		if u and child.__shown then found[u] = true end
		check(child.latticeReady, "pet button not decorated (created late?)")
	end
	check(found.pet and found.partypet2, "expected pet and partypet2 frames")
	for _, b in ipairs(ns.Buttons.all) do
		if b.unit == "pet" then ns.Buttons:UpdateAll(b) end
	end
	ns.db.general.showPets = false
	ns:ApplySettingsNow("layout")
	MOCK.RunTimers()
end)

step("hover-cast keys", function()
	local HC = ns.HoverCast
	check(HC:Add({ key = "shift-1", action = "spell", value = 139, fallback = true }), "add failed")
	check(HC:Add({ key = "CTRL-SHIFT-2", action = "spell", value = 2061, fallback = false }), "add 2 failed")
	MOCK.RunTimers()
	check(MOCK.bindings["SHIFT-1"] == "LatticeHoverCast2" or MOCK.bindings["SHIFT-1"] == "LatticeHoverCast1", "SHIFT-1 not bound")
	local function textFor(key)
		local b = _G[MOCK.bindings[key]]
		return b and b:GetAttribute("macrotext") or ""
	end
	check(textFor("SHIFT-1"):find("[@mouseover,help,nodead][help,nodead]", 1, true), "fallback macro wrong: " .. textFor("SHIFT-1"))
	check(not textFor("CTRL-SHIFT-2"):find("[help,nodead]", 1, true), "no-fallback macro wrong: " .. textFor("CTRL-SHIFT-2"))
	check(not textFor("SHIFT-1"):find("@player", 1, true), "self fallback without asking")
	check(HC.MacroText({ action = "spell", value = 139, side = "harm", fallback = true, self = true }):find("[@mouseover,harm,nodead][harm,nodead] ", 1, true)
		and not HC.MacroText({ action = "spell", value = 139, side = "harm", self = true }):find("@player", 1, true), "enemy key")
	check(HC.MacroText({ action = "spell", value = 139, side = "help", fallback = true, self = true }):find("[help,nodead][@player] ", 1, true), "self fallback when asked")
	check(HC.MacroText({ action = "spell", value = 139, side = "any", fallback = false }):find("/cast [@mouseover,exists,nodead] ", 1, true), "either side")
	check(not textFor("SHIFT-1"):find("@player", 1, true), "must never target self")
	-- in combat: changes queue, no protected calls
	MOCK.combat = true
	HC:Remove(1)
	MOCK.RunTimers()
	MOCK.combat = false
	MOCK.Fire("PLAYER_REGEN_ENABLED")
	MOCK.RunTimers()
	local n = 0
	for _ in pairs(MOCK.bindings) do n = n + 1 end
	check(n == 1, "expected 1 binding after removal, got " .. n)
	HC:Remove(1)
	MOCK.RunTimers()
end)

step("summon and dead states", function()
	MOCK.SetGroup(5, false)
	MOCK.Fire("GROUP_ROSTER_UPDATE")
	MOCK.UpdateAllHeaders()
	MOCK.RunTimers()
	MOCK.summons.party1 = Enum.SummonStatus.Pending
	MOCK.units.party2.dead = true
	MOCK.units.party3.connected = false
	for _, u in ipairs({ "party1", "party2", "party3" }) do
		MOCK.Fire("INCOMING_SUMMON_CHANGED", u)
		MOCK.Fire("UNIT_HEALTH", u)
	end
	local shown
	for _, b in ipairs(ns.Buttons.all) do
		if b.unit == "party1" and b.visual.summon:IsShown() then shown = true end
	end
	check(shown, "summon icon not shown")
	for _, b in ipairs(ns.Buttons.all) do
		if b.unit == "party2" then check(b.visual.status:IsShown() and b.visual.status:GetText() == "Dead", "dead text not shown") end
	end
	MOCK.units.party2.dead = false
	MOCK.Fire("UNIT_HEALTH", "party2")
	for _, b in ipairs(ns.Buttons.all) do
		if b.unit == "party2" then check(not b.visual.status:IsShown(), "dead text should clear on resurrect") end
	end
	-- a new ready check must survive the previous one's clean-up timer
	MOCK.Fire("READY_CHECK", "Leader", 30)
	MOCK.Fire("READY_CHECK_FINISHED", false)
	MOCK.Fire("READY_CHECK", "Leader", 30)
	MOCK.RunTimers()
	check(ns.Buttons.readyState.party1 == "waiting", "old ready check timer wiped the new check")
	MOCK.Fire("READY_CHECK_FINISHED", false)
	MOCK.RunTimers()
	MOCK.summons.party1 = nil
end)

step("tank guessing: rules", function()
	local D = ns.Roles.Decide
	local function m(key, class, t) t = t or {}; t.key = key; t.class = class; t.assigned = t.assigned or "NONE"; return t end
	local function only(out, key)
		local n = 0
		for _ in pairs(out) do n = n + 1 end
		return n == 1 and out[key] ~= nil
	end
	-- five players, nothing to go on: the only warrior
	check(only(D({ m("p", "PRIEST"), m("w", "WARRIOR"), m("m", "MAGE"), m("r", "ROGUE"), m("h", "HUNTER") }, 5), "w"), "lone warrior")
	-- two warriors and no signal: no guess
	check(next(D({ m("w1", "WARRIOR"), m("w2", "WARRIOR"), m("p", "PRIEST"), m("m", "MAGE"), m("r", "ROGUE") }, 5)) == nil, "two warriors should not guess")
	-- a bear beats a warrior in battle stance
	check(only(D({ m("w", "WARRIOR"), m("d", "DRUID", { stance = true }), m("p", "PRIEST"), m("m", "MAGE"), m("r", "ROGUE") }, 5), "d"), "bear form")
	-- equal signals: warrior before paladin; two warriors in defensive stance: no guess
	check(only(D({ m("pa", "PALADIN", { stance = true }), m("w", "WARRIOR", { stance = true }), m("p", "PRIEST"), m("m", "MAGE"), m("r", "ROGUE") }, 5), "w"), "class tie-break")
	check(next(D({ m("w1", "WARRIOR", { stance = true }), m("w2", "WARRIOR", { stance = true }), m("p", "PRIEST"), m("m", "MAGE"), m("r", "ROGUE") }, 5)) == nil, "real tie")
	-- main tank flag beats a stance
	check(only(D({ m("w", "WARRIOR", { stance = true }), m("x", "PRIEST", { mainTank = true }), m("p", "PRIEST"), m("m", "MAGE"), m("r", "ROGUE") }, 5), "x"), "main tank")
	-- an assigned tank or a user choice stops guessing in five-player groups
	check(only(D({ m("w", "WARRIOR"), m("t", "PALADIN", { assigned = "TANK" }), m("p", "PRIEST"), m("m", "MAGE"), m("r", "ROGUE") }, 5), "t"), "assigned tank")
	check(only(D({ m("w", "WARRIOR"), m("x", "MAGE", { override = "tank" }), m("p", "PRIEST"), m("m", "MAGE"), m("r", "ROGUE") }, 5), "x"), "override tank")
	check(next(D({ m("w", "WARRIOR", { override = "notank" }), m("p", "PRIEST"), m("m", "MAGE"), m("r", "ROGUE"), m("h", "HUNTER") }, 5)) == nil, "override notank")
	-- assigned dps is trusted even in defensive stance
	check(next(D({ m("w", "WARRIOR", { stance = true, assigned = "DAMAGER" }), m("p", "PRIEST"), m("m", "MAGE"), m("r", "ROGUE"), m("h", "HUNTER") }, 5)) == nil, "assigned dps")
	-- raids: every stance/form/main tank counts, main assist alone doesn't, class alone doesn't
	local raid = D({ m("w1", "WARRIOR", { stance = true }), m("d", "DRUID", { stance = true }), m("mt", "PRIEST", { mainTank = true }),
		m("ma", "WARRIOR", { mainAssist = true }), m("w2", "WARRIOR") }, 20)
	check(raid.w1 and raid.d and raid.mt and not raid.ma and not raid.w2, "raid rules")
end)

step("tank guessing: in a party", function()
	MOCK.SetGroup(5, false)
	for _, u in ipairs({ "player", "party1", "party2", "party3", "party4" }) do MOCK.units[u].role = "NONE" end
	-- classes: player PRIEST, party1 WARRIOR, party2 MAGE, party3 DRUID, party4 ROGUE
	MOCK.Fire("GROUP_ROSTER_UPDATE")
	MOCK.UpdateAllHeaders()
	MOCK.RunTimers()
	local R = ns.Roles
	check(R:IsTank("party1"), "lone warrior should be the tank")
	local function roleShown(unit)
		for _, b in ipairs(ns.Buttons.all) do
			if b.unit == unit and b:IsVisible() then return b.visual.role:IsShown() end
		end
	end
	check(roleShown("party1"), "guessed tank should get a role icon")
	-- druid shifts to bear: rage bar, works in combat too
	MOCK.combat = true
	MOCK.units.party3.ptype = "RAGE"
	MOCK.Fire("UNIT_DISPLAYPOWER", "party3")
	MOCK.RunTimers()
	MOCK.combat = false
	MOCK.Fire("PLAYER_REGEN_ENABLED")
	MOCK.RunTimers()
	check(R:IsTank("party3") and not R:IsTank("party1"), "bear should take over")
	-- the user says the druid is not a tank
	SlashCmdList.LATTICE("notank party3")
	MOCK.RunTimers()
	check(not R:IsTank("party3") and R:IsTank("party1"), "notank override ignored")
	SlashCmdList.LATTICE("autotank party3")
	MOCK.units.party3.ptype = "MANA"
	MOCK.Fire("UNIT_DISPLAYPOWER", "party3")
	MOCK.RunTimers()
	-- defensive stance seen on the warrior's auras (read out of combat only)
	MOCK.units.party4.class = "WARRIOR"
	MOCK.auras.party1 = { { spellId = 71, name = "Defensive Stance" } }
	MOCK.Fire("UNIT_AURA", "party1")
	MOCK.RunTimers()
	check(R:IsTank("party1") and not R:IsTank("party4"), "defensive stance should pick party1")
	MOCK.combat = true
	MOCK.auras.party1 = nil
	MOCK.Fire("UNIT_AURA", "party1") -- unreadable in combat: keep the last answer
	MOCK.RunTimers()
	check(R:IsTank("party1"), "combat should keep the last answer")
	MOCK.combat = false
	MOCK.Fire("PLAYER_REGEN_ENABLED")
	MOCK.RunTimers()
	check(not R:IsTank("party1"), "stance gone after combat: two warriors, no guess")
	SlashCmdList.LATTICE("tanks")
	-- raid main tank flag
	MOCK.SetGroup(20, true)
	MOCK.assignments.raid7 = "MAINTANK"
	MOCK.Fire("GROUP_ROSTER_UPDATE")
	MOCK.RunTimers()
	check(not R:IsTank("raid7"), "assigned damage role should win over the main tank flag")
	MOCK.units.raid7.role = "NONE"
	MOCK.Fire("PLAYER_ROLES_ASSIGNED")
	MOCK.RunTimers()
	check(R:IsTank("raid7"), "main tank flag")
	MOCK.assignments = {}
	MOCK.auras = {}
end)

step("power bar: rules per power type and role", function()
	local allows = ns.Buttons.PowerRuleAllows
	local rules = ns.db.appearance.powerRules
	check(allows(rules, "MANA", "NONE") and allows(rules, "MANA", "DAMAGER"), "mana should show")
	check(not allows(rules, "ENERGY", "NONE") and not allows(rules, "ENERGY", "TANK"), "energy should hide")
	check(allows(rules, "RAGE", "TANK") and not allows(rules, "RAGE", "NONE"), "rage only for tanks")
	check(allows(rules, "FOCUS", "NONE"), "other power types show")
	check(allows({ MANA = "tankheal" }, "MANA", "HEALER") and not allows({ MANA = "tankheal" }, "MANA", "DAMAGER"), "tankheal")

	MOCK.SetGroup(5, false)
	for _, u in ipairs({ "player", "party1", "party2", "party3", "party4" }) do MOCK.units[u].role = "NONE" end
	MOCK.units.party1.ptype = "RAGE"   -- warrior
	MOCK.units.party3.ptype = "ENERGY" -- druid in cat form
	MOCK.units.party4.ptype = "ENERGY" -- rogue
	MOCK.Fire("GROUP_ROSTER_UPDATE")
	MOCK.UpdateAllHeaders()
	MOCK.RunTimers()
	local function shown(unit)
		for _, b in ipairs(ns.Buttons.all) do
			if b.unit == unit and b:IsVisible() then return b.visual.power:IsShown() end
		end
		error("no button for " .. unit)
	end
	check(shown("player") and shown("party2"), "mana users should have a power bar")
	check(shown("party1"), "lone warrior is the tank: rage shown")
	check(not shown("party4"), "rogue energy should be hidden")
	check(not shown("party3"), "cat form energy should be hidden")
	-- druid leaves cat form (mana), then goes bear in combat (rage, takes the tank spot)
	MOCK.units.party3.ptype = "MANA"
	MOCK.Fire("UNIT_DISPLAYPOWER", "party3")
	check(shown("party3"), "caster form should show mana")
	MOCK.combat = true
	MOCK.units.party3.ptype = "RAGE"
	MOCK.Fire("UNIT_DISPLAYPOWER", "party3")
	MOCK.RunTimers()
	check(shown("party3") and not shown("party1"), "bear should show rage, the warrior no longer tanks")
	MOCK.combat = false
	MOCK.Fire("PLAYER_REGEN_ENABLED")
	MOCK.RunTimers()
	-- the layout switch still turns everything off
	ns.db.layouts.party.showPower = false
	ns:ApplySettingsNow("layout")
	MOCK.RunTimers()
	check(not shown("player"), "layout switch should hide every power bar")
	ns.db.layouts.party.showPower = true
	ns:ApplySettingsNow("layout")
	MOCK.RunTimers()
end)

step("aura filters: lists reach the containers", function()
	local A = ns.Auras
	local sets = A.ListSets(ns.db.auras.lists)
	check(sets.show[10060] and sets.hide[12966], "defaults missing")
	check(sets.skip[10060] and sets.skip[12966], "skip should hold both lists")
	check(A.ListSets({}).show == nil and A.ListSets({ [5] = false }).skip == nil, "empty and removed entries")
	check(A.RAID_BUFFS[10938] and A.RAID_BUFFS[21564] and A.RAID_BUFFS[9885], "raid buffs: Fortitude, Prayer of Fortitude, Mark of the Wild")
	check(A.RaidBuffsShown() == not IsInRaid(), "raid buff row: party yes, raid no by default")
	local rb = ns.db.auras.raidbuffs
	local old = { which = rb.which, pick = rb.pick, extra = rb.extra }
	rb.which = "all"
	check(A:RaidBuffSet()[10938] and A:RaidBuffSet()[19740], "raid buffs: all")
	rb.which = "pick"; rb.pick = { intellect = true }
	check(A:RaidBuffSet()[10156] and not A:RaidBuffSet()[10938], "raid buffs: picked only")
	rb.extra = { 467 }
	check(A:RaidBuffSet()[467], "raid buffs: extra spells")
	rb.which, rb.pick, rb.extra = old.which, old.pick, old.extra
	check(ns.MissingBuff and ns.MissingBuff.HasBuff, "missing-buff module loaded")
	for _, entry in ipairs(A.PRESETS.PRIEST) do
		local name = type(entry) == "table" and entry.name or entry
		check(name ~= "Prayer of Mending", "presets are Classic spells only")
	end
	check(ns.Headers.tanks and ns.Headers.tankTargets, "tank headers made")
	check(ns.Headers.tankTargets:GetAttribute("unitsuffix") == "target", "tank target header shows targets")
	check(ns.Buttons.RangeSpell, "range spell lookup")
	MOCK.SetGroup(5, false)
	MOCK.Fire("GROUP_ROSTER_UPDATE")
	MOCK.UpdateAllHeaders()
	MOCK.RunTimers()
	A:SetListMode(774, "show")
	MOCK.RunTimers()
	local b
	for _, btn in ipairs(ns.Buttons.all) do if btn.unit == "party1" then b = btn end end
	local groups, slots = {}, {}
	for _, c in ipairs(b.auraContainers) do
		for k, g in pairs(c.__groups) do groups[k] = g end
		for k, sl in pairs(c.__slots) do slots[k] = sl end
	end
	local bl, bn = groups.buffsListed, groups.buffs
	check(bl and bl.filter == "HELPFUL" and bl.opts.candidateFilters.includeSpellIDs[774], "listed buff group")
	check(bl.opts.layout.layoutIndex < bn.opts.layout.layoutIndex, "listed buffs should come first")
	local ex = bn.opts.candidateFilters.excludeSpellIDs
	check(ex[774] and ex[12966] and bn.filter == "HELPFUL|PLAYER", "normal buff group should skip listed and hidden")
	check(groups.debuffsListed and groups.debuffs.opts.candidateFilters.excludeSpellIDs[11196], "debuff groups")
	check(slots.boss.opts.candidateFilters.isBossOrRoleAura and slots.boss.opts.candidateFilters.excludeSpellIDs[12966], "boss slot")
	check(slots.dispel.opts.candidateFilters.excludeSpellIDs[15007], "dispel slot")
	local def = slots.defensive.opts.candidateFilters.includeSpellIDs
	check(def and def[871] and not def[774] and slots.defensive.filter == "HELPFUL", "defensive slot shows only the defensive list")
	check(groups.debuffsDispel and groups.debuffsDispel.opts.candidateFilters.includeDispelTypes.Magic
		and groups.debuffs.opts.candidateFilters.maxDuration and groups.debuffs.opts.candidateFilters.excludeDispelTypes.Curse,
		"long debuffs nobody can dispel are skipped, dispellable ones kept")
	check(not slots.dispel.opts.candidateFilters.excludeSpellIDs[774], "an always-show spell must not be hidden")

	-- removing a default sticks through logout/login
	A:SetListMode(12966, nil)
	check(ns.db.auras.lists[12966] == false, "removed default should be stored as false")
	A:SetListMode(774, nil)
	check(ns.db.auras.lists[774] == nil, "removed own entry should vanish")
	local p = ns.Util.CopyTable(ns.db)
	ns.Util.StripDefaults(p, ns.Defaults)
	check(p.auras.lists[12966] == false and p.auras.lists[10060] == nil, "strip should keep only changes")
	ns.Util.FillDefaults(p, ns.Defaults)
	check(p.auras.lists[12966] == false and p.auras.lists[10060] == "show", "fill should not bring back a removed default")
	check(not A.ListSets(p.auras.lists).skip[12966], "removed default still applied")
	check(not A:SetListMode("abc", "hide") and not A:SetListMode(0, "hide"), "bad ids accepted")
end)

step("aura filters: text import and export", function()
	local A = ns.Auras
	local text = A:ExportLists()
	check(text:find("show 10060", 1, true) and text:find("hide 11196", 1, true), "export missing lines: " .. text)
	check(not text:find("12966", 1, true), "removed default exported")
	local n, bad = A:ImportLists("# my list\nshow 774 Rejuvenation\nhide Healing Touch\nnever 9999\nbogus line\nhide NoSuchSpellAnywhere", true)
	check(n == 3 and #bad == 2 and bad[1] == "bogus line", "import counts: " .. n .. " / " .. #bad)
	check(A:ListMode(774) == "show" and A:ListMode(5185) == "hide" and A:ListMode(9999) == "hide", "imported modes")
	check(A:ListMode(10060) == nil and ns.db.auras.lists[10060] == false, "replace should drop defaults")
	A:ImportLists(text, true)
	check(A:ListMode(10060) == "show" and A:ListMode(774) == nil, "round trip")
	A:ResetLists()
	check(A:ListMode(12966) == "hide", "reset to defaults")
	MOCK.RunTimers()
end)

step("frame menu: Ctrl+Alt+Right-click", function()
	local W, M = ns.Widgets, ns.UnitMenu
	local b
	for _, btn in ipairs(ns.Buttons.all) do if btn.unit == "party1" then b = btn end end
	check(b:GetAttribute("alt-ctrl-type2") == M.TYPE, "menu click should be a no-op for the secure button")
	local real, last = W.OpenPopup, nil
	W.OpenPopup = function(_, items, current, onPick) last = { items = items, current = current, pick = onPick } end
	b.__scripts.PostClick(b, "RightButton")
	check(last == nil, "menu opened without modifiers")
	MOCK.mods = { ctrl = true, alt = true }
	b.__scripts.PostClick(b, "RightButton")
	check(last and last.items[1].title and last.current == "auto", "menu not opened")
	last.pick("notank")
	check(ns.Roles:Override(ns.Roles.Key("party1")) == "notank", "notank from menu")
	b.__scripts.PostClick(b, "RightButton")
	check(last.current == "notank", "menu should show the current choice")
	last.pick("auto")
	check(ns.Roles:Override(ns.Roles.Key("party1")) == nil, "auto from menu")
	-- aura picker
	MOCK.auras.party1 = { { spellId = 23170, name = "Brood Affliction: Bronze", harmful = true }, { spellId = 1243, name = "Power Word: Fortitude" } }
	b.__scripts.PostClick(b, "RightButton")
	last.pick("auras")
	check(#last.items == 3, "picker should list two auras")
	local fort
	for _, it in ipairs(last.items) do if it.text and it.text:find("Fortitude") then fort = it.value end end
	last.pick(fort)
	last.pick("hide")
	check(ns.Auras:ListMode(1243) == "hide", "picked aura not hidden")
	-- no picker in combat
	MOCK.combat = true
	b.__scripts.PostClick(b, "RightButton")
	local before = last
	last.pick("auras")
	check(last == before, "picker opened in combat")
	MOCK.combat = false
	MOCK.Fire("PLAYER_REGEN_ENABLED")
	MOCK.mods = {}
	W.OpenPopup = real
	ns.Auras:SetListMode(1243, nil)
	MOCK.auras = {}
	-- a user binding on that click wins
	ns.ClickCast:Add({ button = 2, mods = "alt-ctrl", action = "spell", value = 774 })
	MOCK.RunTimers()
	check(b:GetAttribute("alt-ctrl-type2") == "spell" and not M:Enabled(), "user binding should replace the menu")
	ns.ClickCast:Remove(ns.ClickCast:FindConflict(2, "alt-ctrl"))
	MOCK.RunTimers()
	check(b:GetAttribute("alt-ctrl-type2") == M.TYPE, "menu should come back")
	MOCK.RunTimers()
end)

step("class presets add only known spells", function()
	local realClass = UnitClass
	UnitClass = function(u) if u == "player" then return "Druid", "DRUID", 11 end return realClass(u) end
	wipe(ns.db.auras.indicators)
	local before = 0
	local added, skipped = ns.Auras:AddClassPresets()
	UnitClass = realClass
	check(#added == 1 and added[1] == "Rejuvenation", "expected Rejuvenation only, got " .. table.concat(added, ","))
	check(#skipped >= 1, "expected unknown spells to be skipped")
	local ind = ns.db.auras.indicators[#ns.db.auras.indicators]
	check(#ind.spells >= 2, "expected every Rejuvenation rank")
	check(#ns.db.auras.indicators == before + 1, "wrong indicator count")
	MOCK.RunTimers()
	-- second press adds nothing
	UnitClass = function(u) if u == "player" then return "Druid", "DRUID", 11 end return realClass(u) end
	local again = ns.Auras:AddClassPresets()
	UnitClass = realClass
	check(#again == 0, "presets added twice")
end)

step("class presets skip spots already used", function()
	local realClass = UnitClass
	wipe(ns.db.auras.indicators)
	ns.Auras:AddIndicator("Renew", { 139 }, { point = "TOP", x = -12, y = -2 }, true)
	UnitClass = function(u) if u == "player" then return "Paladin", "PALADIN", 2 end return realClass(u) end
	local added = ns.Auras:AddClassPresets()
	UnitClass = realClass
	check(#added == 1 and added[1] == "Forbearance", "expected Forbearance, got " .. table.concat(added, ","))
	local ind = ns.db.auras.indicators[2]
	check(not (ind.point == "TOP" and ind.x == -12), "new preset placed on top of an existing indicator")
	wipe(ns.db.auras.indicators)
	ns.Auras:Refresh()
	MOCK.RunTimers()
end)

step("low health warning", function()
	MOCK.SetGroup(5, false)
	MOCK.Fire("GROUP_ROSTER_UPDATE")
	MOCK.UpdateAllHeaders()
	MOCK.RunTimers()
	local btn
	for _, b in ipairs(ns.Buttons.all) do if b.unit == "party1" then btn = b break end end
	check(btn, "no party1 button")
	ns.db.appearance.lowHealth = true
	ns.Buttons:UpdateAll(btn)
	check(btn.visual.low:IsShown(), "low health layer should show")
	ns.db.appearance.lowHealth = false
	ns.Buttons:UpdateAll(btn)
	check(not btn.visual.low:IsShown(), "low health layer should hide when off")
	ns.db.appearance.lowHealth = true
	MOCK.units.party1.dead = true
	ns.Buttons:UpdateAll(btn)
	check(not btn.visual.low:IsShown(), "no low health warning on the dead")
	MOCK.units.party1.dead = false
	ns.Buttons:UpdateAll(btn)
	check(ns.Secret.LowHealthCurve(0.3, 0.7) == ns.Secret.LowHealthCurve(0.3, 0.7), "curve should be cached")
end)

step("countdown numbers build", function()
	ns.db.auras.countdown = true
	ns.Auras:Refresh()
	MOCK.RunTimers()
	check(ns.Auras.lastError == nil, "aura build failed: " .. tostring(ns.Auras.lastError))
	ns.db.auras.countdown = false
	ns.Auras:Refresh()
	MOCK.RunTimers()
end)

step("options: dependents grey out at once, confirm buttons ask first", function()
	local W = ns.Widgets
	local holder = CreateFrame("Frame")
	local s = W.Stack(holder, 400)
	local parentOn = true
	local parent = W.Toggle(s, { label = "Parent", get = function() return parentOn end, set = function(v) parentOn = v end })
	local child = W.Toggle(s, { label = "Child", get = function() return false end, set = function() end,
		disabled = function() return not parentOn end })
	local color = W.Color(s, { label = "Color", get = function() return { 1, 1, 1, 1 } end, set = function() end,
		disabled = function() return not parentOn end })
	check(child:GetAlpha() == 1, "child should start enabled")
	parent:GetScript("OnClick")(parent)
	check(not parentOn, "parent toggle didn't change")
	check(child:GetAlpha() < 1 and color:GetAlpha() < 1, "dependents should grey out when the parent is turned off")
	local done = 0
	local b = W.ConfirmButton(holder, "Delete", function() done = done + 1 end)
	b:GetScript("OnClick")(b)
	check(done == 0, "confirm button acted on the first click")
	b:GetScript("OnClick")(b)
	check(done == 1, "confirm button didn't act on the second click")
end)

step("settings upgrade from schema 1", function()
	local sv = { schema = 1, profiles = { Default = {} }, chars = { ["A-B"] = { profile = "Default", bindings = {} } } }
	ns.Database:Migrate(sv)
	check(sv.schema == ns.Database.SCHEMA, "schema not bumped")
	check(type(sv.chars["A-B"].hover) == "table", "hover list not created")
end)

step("character key on client build 71037: GetRealmName \"\", GetRealmID 0, no realm from UnitFullName", function()
	local DB = ns.Database
	local realFull, realName, realID = UnitFullName, GetRealmName, GetRealmID
	check(DB:CharKey({}):match("%-MockRealm$"), "the usual key changed: " .. DB:CharKey({}))
	-- WoW Forever: the second value is the surname; the key stays what it always was
	UnitFullName = function() return "Miy", "Sake" end
	check(DB:CharKey({}) == "Miy-Sake", "surname key changed")
	-- nothing from UnitFullName and an empty realm name: the realm ID from the GUID, never "Miy-"
	UnitFullName = function() return "Miy", nil end
	GetRealmName = function() return "" end
	GetRealmID = function() return 0 end
	local sv = { chars = {} }
	local key = DB:CharKey(sv)
	check(key == "Miy-realm:1", "ID-only key expected, got " .. key)
	sv.realmNames = { [1] = "Mock Realm" }
	check(DB:CharKey(sv) == "Miy-MockRealm", "saved name for the ID not used")
	-- a character saved as "Miy-" is adopted when it is the only Miy; left (and reported) when another Miy exists
	sv = { chars = { ["Miy-"] = { profile = "Raid" } } }
	key = DB:CharKey(sv)
	check(DB:AdoptNameless(sv, key, "Miy") == nil and sv.chars[key].profile == "Raid" and not sv.chars["Miy-"], "not adopted")
	sv = { chars = { ["Miy-"] = { profile = "Raid" }, ["Miy-OtherRealm"] = { profile = "Default" } } }
	check(DB:AdoptNameless(sv, DB:CharKey(sv), "Miy") == "Miy-" and sv.chars["Miy-"], "an ambiguous one was moved")
	UnitFullName, GetRealmName, GetRealmID = realFull, realName, realID
end)

step("options window: every page builds", function()
	ns.Options:Open()
	for _, id in ipairs({ "general", "layout", "appearance", "auras", "aurafilters", "clickcast", "hovercast", "profiles" }) do
		ns.Options:ShowPage(id)
	end
	ns.Options:RebuildAll()
	ns.Options:ShowPage("auras")
	ns.Options:Toggle()
end)

step("options search: finds controls on every page, live, and puts them back", function()
	local O = ns.Options
	O:Open("general")
	local f = LatticeOptionsWindow
	check(f.searchBox and f.results, "no search box")
	-- word starts on another page, with its path
	local results = O:Search("opacity out")
	check(#results >= 1 and results[1].entry.info.label == "Opacity when out of range", "range opacity not found first")
	check(results[1].entry.path:find("^General"), "path: " .. results[1].entry.path)
	local slider = results[1].entry.frame
	check(slider:GetParent() == f.results.child, "control not listed in the results")
	check(#O:Search("FRAMES show lattice") >= 1, "multi-word search")
	local seen = {}
	for _, e in ipairs(O:SearchEntries()) do seen[e.page.id] = true end
	check(seen.general and seen.appearance and seen.layout, "pages not indexed")
	-- a toggle in the results works
	results = O:Search("fade players out of range")
	local toggle = results[1].entry.frame
	local before = ns.db.general.rangeFade
	toggle:GetScript("OnClick")(toggle)
	check(ns.db.general.rangeFade ~= before, "toggle in the results didn't change the setting")
	toggle:GetScript("OnClick")(toggle)
	-- nothing found, then clearing restores the page
	O:Search("zzqqxx")
	check(f.results.empty:IsShown(), "no 'nothing matches' text")
	O:Search("")
	check(slider:GetParent() == slider.searchSlot.stack.parent, "control not given back")
	-- Ctrl+F focuses; Escape clears, then closes
	MOCK.mods.ctrl = true
	local focused
	rawset(f.searchBox, "SetFocus", function() focused = true end)
	f:GetScript("OnKeyDown")(f, "F")
	MOCK.mods.ctrl = false
	rawset(f.searchBox, "SetFocus", nil)
	check(focused, "Ctrl+F didn't focus the box")
	f.searchBox:SetText("tank")
	O:Search("tank")
	f:GetScript("OnKeyDown")(f, "ESCAPE")
	check(f:IsShown() and f.searchBox:GetText() == "", "Escape should clear the search first")
	-- the path jumps to the page
	O:Search("opacity out")
	local row = f.results.paths[1]
	row:GetScript("OnClick")(row)
	check(not f.results:IsShown() and slider.searchFlash and slider.searchFlash:IsShown(), "jump didn't open the page and light it up")
	f:GetScript("OnKeyDown")(f, "ESCAPE")
	check(not f:IsShown(), "second Escape should close")
	-- a page rebuilt during a search stays searchable
	O:Open("general")
	O:Search("opacity out")
	O:RebuildPage("general")
	check(#O:Search("opacity out") >= 1, "rebuilt page lost from the search")
	O:Search("")
	O:Toggle()
end)

step("settings: the wheel scrolls the page, text areas only while typing, sliders never", function()
	ns.Options:Open()
	ns.Options:ShowPage("profiles")
	local function patch(sf)
		sf.SetVerticalScroll = function(self, v) self.__vs = v end
		sf.GetVerticalScroll = function(self) return self.__vs or 0 end
	end
	local page
	for _, c in ipairs(LatticeOptionsWindow.content.__children) do
		if c.__kind == "ScrollFrame" and c:IsShown() then page = c end
	end
	check(page and page.track, "no page scroll with a bar")
	local inner
	for _, w in ipairs(MOCK.widgets) do
		if w.__kind == "ScrollFrame" and w ~= page then
			local p = w:GetParent()
			while p and p ~= page do p = p:GetParent() end
			if p then inner = w end
		end
	end
	check(inner, "no text area on the profiles page")
	patch(page); patch(inner)
	local box = inner.__children[1]
	local focus = false
	box.HasFocus = function() return focus end
	page.__h, page.child.__h = 400, 1500
	inner.__h, box.__h = 60, 200
	local wheel = inner:GetScript("OnMouseWheel")
	wheel(inner, -1)
	check(page:GetVerticalScroll() == 40 and inner:GetVerticalScroll() == 0, "wheel over a text area didn't scroll the page")
	focus = true
	wheel(inner, -1)
	check(inner:GetVerticalScroll() == 30 and page:GetVerticalScroll() == 40, "wheel while typing didn't scroll the text")
	inner.__vs = 140
	wheel(inner, -1)
	check(page:GetVerticalScroll() == 80, "text at its end didn't pass the wheel to the page")
	for _, w in ipairs(MOCK.widgets) do
		if w.__kind == "Slider" then check(not w.__scripts.OnMouseWheel, "a slider takes the mouse wheel") end
	end
	ns.Options:Toggle()
end)

step("preview mode all sizes", function()
	for _, n in ipairs({ 5, 10, 20, 25, 40 }) do
		ns.TestMode:Start(n)
		for _, mode in ipairs({ "class", "custom", "gradient" }) do
			ns.db.appearance.healthColor = mode
			ns.TestMode:Relayout()
		end
	end
	ns.TestMode:Stop()
end)

step("mover toggle", function()
	ns.Mover:Toggle()
	ns.Mover:Toggle()
end)

step("profiles: create, switch, export, import, delete", function()
	check(ns.Profiles:Create("Healer"), "create failed")
	ns.Profiles:Switch("Healer")
	check(ns.Database:ActiveName() == "Healer", "switch failed")
	ns.db.layouts.raid.width = 101
	local str = assert(ns.Profiles:Export())
	check(str:sub(1, 5) == "LAT1:", "bad export prefix")
	local ok, err = ns.Profiles:Import(str, "Imported")
	check(ok, "import failed: " .. tostring(err))
	check(ns.Database:ActiveName() == "Imported" and ns.db.layouts.raid.width == 101, "import switches to it")
	-- with click-casting, unnamed: gets a free name; same class takes the bindings
	ns.char.bindings[1].action = "menu"
	local withCast = assert(ns.Profiles:Export(nil, true))
	ns.char.bindings[1].action = "target"
	local ok2, name2, note = ns.Profiles:Import(withCast, nil, true)
	check(ok2 and name2 == "Imported 2", "free name: " .. tostring(name2))
	check(ns.char.bindings[1].action == "menu", "click-casting taken: " .. tostring(note))
	ns.char.bindings[1].action = "target"
	ns.Profiles:Switch("Default")
	check(ns.db.layouts.raid.width ~= 101, "profiles share data")
	check(ns.Profiles:Delete("Healer"), "delete failed")
end)

step("slash commands", function()
	SlashCmdList.LATTICE("")
	SlashCmdList.LATTICE("probe")
	SlashCmdList.LATTICE("status")
	SlashCmdList.LATTICE("preview 10")
	SlashCmdList.LATTICE("preview")
	SlashCmdList.LATTICE("hide 1243")
	assert(ns.Auras:ListMode(1243) == "hide", "slash hide")
	SlashCmdList.LATTICE("unlist 1243")
	assert(ns.Auras:ListMode(1243) == nil, "slash unlist")
	SlashCmdList.LATTICE("show nosuchspell")
	SlashCmdList.LATTICE("help")
end)

step("chat commands follow the shared EverlookDB pattern", function()
	check(SLASH_LATTICE1 == "/lattice" and SLASH_LATTICE2 == "/lat", "slash words")
	local function logText() return table.concat(MOCK.log or {}, "\n") end
	MOCK.log = {}
	SlashCmdList.LATTICE("?")
	local help = logText()
	for _, want in ipairs({ "/lattice preview [5||10||20||25||40]", "/lattice tank [name]", "/lattice unlock || lock",
		"/lattice show <spell>", "/lattice search <words>", "/lattice status || version || help", "Also works as /lat" }) do
		check(help:find(want, 1, true), "help lacks " .. want .. ": " .. help)
	end
	MOCK.log = {}
	SlashCmdList.LATTICE("tnaks")
	check(logText():find("Did you mean /lattice tanks?", 1, true), "typo: " .. logText())
	MOCK.log = {}
	SlashCmdList.LATTICE("version")
	check(logText():find("Lattice", 1, true), "version: " .. logText())
	MOCK.log = {}
	SlashCmdList.LATTICE("get")
	check(logText():find("general.enabled|r = on", 1, true), "get lists the window's settings: " .. logText())
	SlashCmdList.LATTICE("search Range")
	check(LatticeOptionsWindow:IsShown() and LatticeOptionsWindow.searchBox:GetText() == "range", "search: " .. tostring(LatticeOptionsWindow.searchBox:GetText()))
	ns.Options:StopSearch()
	SlashCmdList.LATTICE("")
	check(not LatticeOptionsWindow:IsShown(), "bare /lattice toggles the window closed")
	SlashCmdList.LATTICE("config")
	check(LatticeOptionsWindow:IsShown(), "/lattice config opens it")
end)

step("feedback link", function()
	SlashCmdList.LATTICE("feedback")
	local d = LatticeFeedbackWindow
	check(d and d:IsShown(), "feedback window not shown")
	check(d.box:GetText() == ns.FEEDBACK_URL, "feedback box doesn't hold the URL")
	d.box:SetText("typed over")
	d.box:GetScript("OnTextChanged")(d.box, true)
	check(d.box:GetText() == ns.FEEDBACK_URL, "feedback URL can be edited away")
	d.box:GetScript("OnEscapePressed")(d.box)
	check(not d:IsShown(), "escape in the box didn't close the window")
	ns.ShowFeedback()
	d:GetScript("OnKeyDown")(d, "ESCAPE")
	check(not d:IsShown(), "escape didn't close the window")
	check(next(MOCK.popups) == nil, "a Blizzard StaticPopup was used")
end)

step("options window closes on Escape without UISpecialFrames", function()
	ns.Options:Open()
	check(LatticeOptionsWindow:IsShown(), "options window not shown")
	LatticeOptionsWindow:GetScript("OnKeyDown")(LatticeOptionsWindow, "A")
	check(LatticeOptionsWindow:IsShown(), "a normal key closed the window")
	LatticeOptionsWindow:GetScript("OnKeyDown")(LatticeOptionsWindow, "ESCAPE")
	check(not LatticeOptionsWindow:IsShown(), "escape didn't close the window")
end)

step("no taint: Blizzard globals and frames left alone", function()
	local allowed = {
		LatticeDB = true, SLASH_LATTICE1 = true, SLASH_LATTICE2 = true,
		Lattice_OnCompartmentClick = true, Lattice_OnCompartmentEnter = true, Lattice_OnCompartmentLeave = true,
	}
	for k in pairs(globalWrites) do
		check(allowed[k], "addon assigned the global " .. tostring(k))
	end
	check(next(UISpecialFrames) == nil, "addon added to UISpecialFrames")
	check(next(StaticPopupDialogs) == nil, "addon added to StaticPopupDialogs")
	check(#blizzardHides == 0, "addon called :Hide() on Blizzard frame " .. tostring(blizzardHides[1]))
	for _, name in ipairs(BLIZZARD_FRAMES) do
		check(not _G[name]:IsVisible(), name .. " still visible with hideBlizzard on")
	end
end)

step("aura icons grow into the frame from any corner", function()
	local A = ns.Auras
	check(A.InwardGrow("TOPLEFT") == "RIGHT", "top-left buffs would grow out of the frame")
	check(A.InwardGrow("BOTTOMLEFT") == "RIGHT", "bottom-left would grow out of the frame")
	check(A.InwardGrow("TOPRIGHT") == "LEFT", "top-right would grow out of the frame")
	check(A.InwardGrow("RIGHT") == "LEFT", "right would grow out of the frame")
	check(A.InwardGrow("CENTER") == "RIGHT", "center should grow right")
end)

step("player tooltip on mouseover, in combat too unless turned off", function()
	local btn
	for _, b in ipairs(ns.Buttons.all) do if b.unit then btn = b; break end end
	check(btn, "no frame with a unit to hover")
	local shown
	rawset(GameTooltip, "SetUnit", function(_, u) shown = u end)
	local enter, leave = btn:GetScript("OnEnter"), btn:GetScript("OnLeave")
	MOCK.combat = true
	enter(btn); leave(btn)
	check(shown == btn.unit, "no tooltip in combat")
	shown = nil
	ns.db.general.tooltipsInCombat = false
	enter(btn); leave(btn)
	check(shown == nil, "tooltip shown in combat with Tooltip in combat too off")
	MOCK.combat = false
	enter(btn); leave(btn)
	check(shown == btn.unit, "no tooltip out of combat")
	ns.db.general.tooltipsInCombat = nil
	rawset(GameTooltip, "SetUnit", nil)
end)

step("Fear Ward is on Always show by default (Hide long buffs would drop it)", function()
	check(ns.Defaults.auras.lists[6346] == "show", "Fear Ward not on the default Always show list")
	local saved = ns.db.auras.lists
	ns.db.auras.lists = { [6346] = "show" }
	local sets = ns.Auras.ListSets(ns.db.auras.lists)
	check(sets.show and sets.show[6346], "Fear Ward not in the show set")
	ns.db.auras.lists = saved
end)

step("lock and unlock: explicit commands, chat line, combat drops a held box", function()
	local M = ns.Mover
	if M:IsUnlocked() then M:SetUnlocked(false, true) end
	local synced = 0
	ns:Listen("MoverChanged", function() synced = synced + 1 end)
	SlashCmdList.LATTICE("lock")
	check(not M:IsUnlocked(), "/lattice lock unlocked the frames")
	SlashCmdList.LATTICE("unlock")
	check(M:IsUnlocked(), "/lattice unlock didn't unlock")
	SlashCmdList.LATTICE("unlock")
	check(M:IsUnlocked(), "/lattice unlock twice locked again")
	check(synced == 1, "window not told about the change (" .. synced .. ")")
	local a = M:GetAnchor("party")
	local stopped = false
	rawset(a, "StopMovingOrSizing", function() stopped = true end)
	a.overlay:GetScript("OnDragStart")(a.overlay)
	check(a.moving, "drag didn't start")
	MOCK.Fire("PLAYER_REGEN_DISABLED")
	check(not M:IsUnlocked() and not a.moving and stopped, "combat didn't lock and drop the held box")
	check(not ns.TestMode:IsActive(), "preview from unlocking still up in combat")
	rawset(a, "StopMovingOrSizing", nil)
	MOCK.Fire("PLAYER_REGEN_ENABLED")
end)

step("preview stops when combat starts (it hides the real frames)", function()
	ns.TestMode:Toggle()
	check(ns.TestMode:IsActive(), "preview didn't start")
	MOCK.Fire("PLAYER_REGEN_DISABLED")
	check(not ns.TestMode:IsActive(), "preview still up in combat")
	MOCK.Fire("PLAYER_REGEN_ENABLED")
end)

step("imported click-casting and hover keys are cleaned", function()
	local b = ns.ClickCast.CleanBindings({
		{ button = 1, mods = "SHIFT", action = "spell", value = "774" },
		{ button = 9, action = "target" }, { button = 2, action = "explode" }, { button = 3, action = "spell" },
		{ button = 4, action = "macro", value = "" }, "junk", { action = "target" },
	})
	check(#b == 1 and b[1].mods == "shift" and b[1].value == 774, "bad bindings kept: " .. #b)
	local h = ns.HoverCast.CleanList({ { key = "shift-1", action = "spell", value = 2061 }, { key = "", action = "spell", value = 1 },
		{ key = "F", action = "nuke" }, 5 })
	check(#h == 1 and h[1].key == "SHIFT-1", "bad hover keys kept: " .. #h)
	check(#ns.ClickCast.CleanBindings(nil) == 0 and #ns.HoverCast.CleanList("x") == 0, "non-tables not handled")
end)

step("blank profile names are refused; chat escapes typed text", function()
	check(not ns.Profiles:Create("   "), "blank profile name accepted")
	check(not ns.Profiles:Rename(ns.Database:ActiveName(), ""), "blank rename accepted")
	check(ns.Escape("a|cffb") == "a||cffb", "| not escaped")
	SlashCmdList.LATTICE("hide |cffnothing")
	SlashCmdList.LATTICE("show")
end)

step("enemy hover keys list harmful spells, not everything that isn't helpful", function()
	local O = ns.Options
	local harmful = { [3] = true }
	C_SpellBook.IsSpellBookItemHelpful = function(slot) return slot == 1 end
	C_SpellBook.IsSpellBookItemHarmful = function(slot) return harmful[slot] == true end
	local harm = O.SpellbookSpells("harm")
	check(#harm == 1 and harm[1].value == 5185, "harm list: " .. #harm)
	check(#O.SpellbookSpells("help") == 1 and #O.SpellbookSpells("any") == 2, "help/any lists")
	C_SpellBook.IsSpellBookItemHelpful = function() return true end
	C_SpellBook.IsSpellBookItemHarmful = nil
	check(not ns.HoverCast.MacroText({ action = "spell", value = 774, side = "any", fallback = false }):find("@player", 1, true),
		"either side without self falls back to you")
end)

step("AFK: the status and the health text never share the spot", function()
	local btn
	for _, b in ipairs(ns.Buttons.all) do if b.unit and b:IsVisible() then btn = b; break end end
	check(btn, "no frame with a unit")
	ns.db.appearance.statusText = "deficit"
	local afk = true
	UnitIsAFK = function() return afk end
	ns.Buttons:UpdateAll(btn)
	local v = btn.visual
	check(v.status:IsShown() and v.status:GetText() == "AFK", "AFK not shown")
	MOCK.Fire("UNIT_HEALTH", btn.unit)
	check(not v.healthText:IsShown(), "health text drawn over AFK after a health change")
	afk = false
	MOCK.Fire("PLAYER_FLAGS_CHANGED", btn.unit)
	check(not v.status:IsShown() and v.healthText:IsShown(), "health text didn't come back after AFK")
	UnitIsAFK = function() return false end
end)

step("names sit above the aura icons; the leader icon beside the role icon", function()
	local btn = ns.Buttons.all[1]
	local v = btn.visual
	check(v.name:GetParent() == v.text and v.text:GetFrameLevel() >= v.over:GetFrameLevel() + 10,
		"name not above the big dispel icon")
	local anchor
	rawset(v.leader, "SetPoint", function(_, point, rel, relPoint) anchor = { point, rel, relPoint } end)
	ns.Buttons:ApplyLayout(btn)
	check(anchor and anchor[2] == v.role and anchor[1] == "LEFT" and anchor[3] == "RIGHT", "leader not beside the role icon")
	ns.db.appearance.roleIconPoint = "TOPRIGHT"
	ns.Buttons:ApplyLayout(btn)
	check(anchor[1] == "RIGHT" and anchor[3] == "LEFT", "leader should sit left of a top-right role icon")
	ns.db.appearance.roleIconPoint = "TOPLEFT"
	rawset(v.leader, "SetPoint", nil)
	ns.Buttons:ApplyLayout(btn)
end)

step("settings search finds sections made of buttons and lists", function()
	local O = ns.Options
	O:Open()
	for _, q in ipairs({ "export", "import", "preset", "indicator", "filter", "reset position", "copy profile" }) do
		check(#O:Search(q) >= 1, "search found nothing for " .. q)
	end
	O:StopSearch()
	O:Toggle()
end)

step("one failing out-of-combat job doesn't drop the others", function()
	MOCK.combat = true
	local ran = false
	ns:RunOutOfCombat("test-broken", function() error("boom") end)
	ns:RunOutOfCombat("test-after", function() ran = true end)
	MOCK.combat = false
	local before = #MOCK.errors
	MOCK.Fire("PLAYER_REGEN_ENABLED")
	check(ran, "the job after a failing one never ran")
	check(#MOCK.errors == before + 1, "the failure wasn't reported")
	table.remove(MOCK.errors)
end)

step("hover-casting: \"cast on me\" is on for new keys in a fresh profile, off in profiles saved before", function()
	-- this run started with no saved variables: a new install
	check(ns.db.general.hoverCastSelf == true, "fresh profile: expected on, got " .. tostring(ns.db.general.hoverCastSelf))
	check(LatticeDB.schema == ns.Database.SCHEMA, "a new install should start at the newest schema")
	-- saved before the change (schema 3): every profile without the key gets an explicit off
	local sv = { schema = 3, profiles = {
		Default = {},
		Healer = { general = { rangeFade = false } },
		On = { general = { hoverCastSelf = true } },
		Off = { general = { hoverCastSelf = false } },
	}, chars = {} }
	ns.Database:Migrate(sv)
	check(sv.schema == ns.Database.SCHEMA, "schema not bumped")
	check(sv.profiles.Default.general.hoverCastSelf == false, "existing profile without the key: expected off")
	check(sv.profiles.Healer.general.hoverCastSelf == false and sv.profiles.Healer.general.rangeFade == false, "other settings lost")
	check(sv.profiles.On.general.hoverCastSelf == true, "explicit on changed")
	check(sv.profiles.Off.general.hoverCastSelf == false, "explicit off changed")
	-- the explicit off survives logout's default stripping, and filling defaults keeps it
	local p = sv.profiles.Default
	ns.Util.StripDefaults(p, ns.Defaults)
	check(p.general and p.general.hoverCastSelf == false, "logout stripped the explicit off")
	ns.Util.FillDefaults(p, ns.Defaults)
	check(p.general.hoverCastSelf == false, "defaults overwrote the explicit off")
	-- already migrated: a profile made later (new or reset) gets the new default
	local later = { schema = ns.Database.SCHEMA, profiles = { New = {} }, chars = {} }
	ns.Database:Migrate(later)
	check(later.profiles.New.general == nil, "a migration ran again on new data")
	check(ns.Util.FillDefaults(later.profiles.New, ns.Defaults).general.hoverCastSelf == true, "new profile: expected on")
	-- the settings window: the switch, its search, and a new key's starting value follow it
	local O = ns.Options
	O:Open("hovercast")
	local found
	for _, r in ipairs(O:Search("cast on me")) do
		if r.entry.info.label == "New keys cast on me when nobody else fits" then found = r.entry end
	end
	check(found, "search 'cast on me' doesn't find the setting")
	local selfCast
	for _, r in ipairs(O:Search("self cast")) do
		if r.entry.info.label == "New keys cast on me when nobody else fits" then selfCast = true end
	end
	check(selfCast, "search 'self cast' doesn't find the setting")
	O:StopSearch()
	local draftSwitch, setting
	for _, e in ipairs(O:SearchEntries()) do
		if e.page.id == "hovercast" and e.info.label == "If there's still nobody, cast on me (friendly spells only)" then draftSwitch = e.frame end
		if e.info.label == "New keys cast on me when nobody else fits" then setting = e.frame end
	end
	check(draftSwitch and setting, "hover-cast page controls missing")
	check(setting.setting.opt.get() == true and draftSwitch.setting.opt.get() == true, "a new key should start with cast on me on")
	setting:GetScript("OnClick")(setting)
	check(ns.db.general.hoverCastSelf == false and draftSwitch.setting.opt.get() == false, "turning the default off didn't reach the new key")
	setting:GetScript("OnClick")(setting)
	check(ns.db.general.hoverCastSelf == true, "back on")
	O:Toggle()
end)

step("AI help: /lattice ai lists the window's settings by page, per layout, and nothing that isn't a setting", function()
	local app = ns.app
	MOCK.log = {}
	check(app:HandleSlash("ai") == "ai", "/lattice ai not handled")
	local f = LatticeAiHelpWindow
	check(f and f:IsShown(), "AI help window not shown")
	local t = f.box:GetText()
	for _, want in ipairs({
		"Lattice draws party and raid frames",
		"General \194\187 Range:\n- general.rangeFade: Fade players who are out of range. On/off. Now: on. Default: on.",
		"- layouts.party.width: Width (Party). Number 30 to 200, step 1. Now: 110. Default: 110.",
		"- layouts.raid40.width: Width (Large raid). Number 30 to 200, step 1.",
		"- layouts.raid.mode: Raid style (Raid). Choice: groups = One column per raid group; combined = All players in one grid.",
		"- layouts.party.showSolo:",
		"- general.hoverCastSelf: New keys cast on me when nobody else fits. On/off. Now: on. Default: on.",
		"- appearance.backgroundColor: Background color. Colour: hex rrggbb, or r g b a",
		"- general.hideBlizzard:",
		"- auras.raidbuffs.which:",
		"MORE ABOUT LATTICE",
	}) do
		check(t:find(want, 1, true), "AI text lacks: " .. want)
	end
	for _, unwanted in ipairs({ "Layout to edit", "layouts.raid.showSolo", "layouts.party.mode", "If nobody fitting is under the mouse",
		"Preview group size", "Mouse button" }) do
		check(not t:find(unwanted, 1, true), "AI text lists what isn't a setting: " .. unwanted)
	end
	f:Hide()
	-- the settings window's button: plain (the page keeps its one gold button), opens it, closes nothing
	ns.Options:Open("general")
	local b = LatticeOptionsWindow.aiButton
	check(b, "no AI help button in the settings window")
	local r, g, bl = b.bg:GetVertexColor()
	check(not (r == ns.Theme.accent[1] and g == ns.Theme.accent[2] and bl == ns.Theme.accent[3]), "the AI help button is a gold/primary one")
	b:GetScript("OnClick")(b)
	check(f:IsShown() and LatticeOptionsWindow:IsShown(), "the button didn't open AI help, or closed the settings window")
	f:Hide()
	ns.Options:Toggle()
end)

step("AI help: /lattice apply previews, changes only listed settings with valid values, and waits for combat", function()
	local app, db = ns.app, ns.db
	local text = table.concat({
		"# wider raid frames",
		"/lattice layouts.raid.width 100",
		"layouts.raid.width 5000",
		"layouts.party.orientation sideways",
		"general.rangeAlpha 0.5",
		"appearance.texture flat",
		"appearance.backgroundColor 1 0 0 0.5",
		"appearance.borderColor 3 0 0",
		"layouts.raid.showSolo on",
		"debug on",
		"general.hoverCastSelf off",
		"/run print('hi')",
		"reset",
		"tank Bob",
		"/lattice show 1243",
		"__index on",
		"layouts.__index.width 90",
	}, "\n")
	local rows = app:PlanApply(text)
	local kinds = {}
	for _, r in ipairs(rows) do kinds[#kinds + 1] = r.err and "err" or r.kind end
	check(table.concat(kinds, " ") == "set err err set set set err err err set err err err err err err",
		"rows: " .. table.concat(kinds, " "))
	check(db.layouts.raid.width == 86, "planning changed something")
	check((app:PreviewLine(rows[1])) == "Width (Raid) (layouts.raid.width): 86 -> 100", "preview: " .. (app:PreviewLine(rows[1])))
	MOCK.log = {}
	local changed, skipped = app:ApplyText(text)
	MOCK.RunTimers()
	check(changed == 5 and skipped == 11, ("changed %d, skipped %d"):format(changed, skipped))
	check(db.layouts.raid.width == 100 and db.layouts.party.width == 110, "layout width")
	check(math.abs(db.general.rangeAlpha - 0.5) < 1e-9 and db.appearance.texture == "flat", "values")
	check(db.appearance.backgroundColor[1] == 1 and db.appearance.backgroundColor[4] == 0.5, "colour")
	check(db.general.hoverCastSelf == false, "hover default")
	check(ns.Auras:ListMode(1243) == nil, "the apply window ran a command")
	-- the apply window: /lattice apply opens it with the lines
	check(app:HandleSlash("apply layouts.raid.width 90 ; general.hoverCastSelf on") == "apply", "/lattice apply")
	local w = LatticeAiApplyWindow
	check(w and w:IsShown() and w.changes == 2, "apply window: " .. tostring(w and w.changes))
	w:Hide()
	-- in combat: nothing changes until it ends, then everything that waited
	MOCK.combat = true
	local c2, _, _, msg, queued = app:ApplyText("layouts.raid.width 90\ngeneral.hoverCastSelf on\nappearance.texture smooth")
	check(c2 == 0 and queued == 3, "in combat: changed " .. c2 .. ", queued " .. tostring(queued))
	check(msg:find("3 apply when combat ends", 1, true), "message: " .. msg)
	check(db.layouts.raid.width == 100 and db.general.hoverCastSelf == false and db.appearance.texture == "flat", "changed in combat")
	MOCK.combat = false
	MOCK.Fire("PLAYER_REGEN_ENABLED")
	MOCK.RunTimers()
	check(db.layouts.raid.width == 90 and db.general.hoverCastSelf == true and db.appearance.texture == "smooth", "not applied after combat")
	-- back to the defaults for the tests after this one
	db.layouts.raid.width, db.general.rangeAlpha, db.appearance.texture = 86, 0.35, "lattice"
	db.appearance.backgroundColor = ns.Util.CopyTable(ns.Defaults.appearance.backgroundColor)
	ns:ApplySettings("all")
	MOCK.RunTimers()
end)

-- 5-second rule: mana spells start it (seen from the cast + the spell's mana cost, never from mana values)
local COSTS = {
	[2050] = { { type = 0, cost = 55 } },        -- Lesser Heal
	[1] = {},                                    -- a free spell
	[5019] = { { type = 0, cost = 0 } },         -- Shoot (wand)
	[75] = { { type = 0, cost = 10 } },          -- Auto Shot (ignored even if the client lists a cost)
	[100] = { { type = 1, cost = 10 } },         -- a rage spell
	[7777] = "secret fields",
	[8888] = "error",
	[9999] = "secret table",
}
local function MockCosts(id)
	local c = COSTS[id]
	if c == "error" then error("bad spell") end
	if c == "secret table" then return MOCK.S({ { type = 0, cost = 50 } }) end
	if c == "secret fields" then return { { type = MOCK.S(0), cost = MOCK.S(50) } } end
	return c
end
local function ButtonFor(unit)
	for btn in pairs(ns.Buttons.byUnit[unit] or {}) do
		if btn.unit == unit then return btn end
	end
end
local function Tick(dt)
	MOCK.time = MOCK.time + dt
	local d = ns.FiveSecond.driver
	if d:IsShown() then d:GetScript("OnUpdate")(d, dt) end
end
local function Cast(unit, id) MOCK.Fire("UNIT_SPELLCAST_SUCCEEDED", unit, "Cast-1", id) end

step("5-second rule: mana spells start it; free spells, Shoot, Auto Shot and secret cast info don't (and don't error)", function()
	local FS = ns.FiveSecond
	C_Spell.GetSpellPowerCost = MockCosts
	check(FS.SpellCostsMana(2050) == true, "a mana spell")
	for _, id in ipairs({ 1, 5019, 75, 100, 7777, 8888, 9999, 424242 }) do
		check(FS.SpellCostsMana(id) == false, "not a mana spend: " .. id)
	end
	check(FS.SpellCostsMana(MOCK.S(2050)) == false and FS.SpellCostsMana(nil) == false, "a secret spell ID")
	local C = ns.db.appearance.fiveSecond
	check(C.enabled == true and C.who == "healers" and C.seconds == false, "defaults: on, you and healers, no number")

	MOCK.SetGroup(5, false)
	MOCK.Fire("GROUP_ROSTER_UPDATE")
	MOCK.UpdateAllHeaders()
	MOCK.RunTimers()
	wipe(FS.spent)
	local me = ButtonFor("player")
	check(me, "no frame for the player")
	check(not FS.driver:IsShown(), "the driver runs while nothing counts")
	for _, id in ipairs({ 1, 5019, 75, 100, 7777, 8888, 9999 }) do Cast("player", id) end
	Cast("player", MOCK.S(2050))
	Cast("target", 2050)
	Cast("nameplate1", 2050)
	check(me.fsrPhase == nil and next(FS.spent) == nil and not FS.driver:IsShown(), "something that isn't a mana spend started it")
	Cast("player", 2050)
	check(me.fsrPhase == "count" and FS.driver:IsShown(), "a mana spell didn't start the countdown")
	local f = me.visual.fsr
	check(f and f:IsShown() and f.bar:IsShown() and math.abs(f.bar:GetValue() - 5) < 1e-6, "the bar isn't full at the start")
	check(not f.text:IsShown(), "seconds number shown while it's off")
	-- a member whose GUID is secret: nothing, no error
	local guid = UnitGUID
	UnitGUID = function(u) if u == "party3" then return MOCK.S("x") end return guid(u) end
	MOCK.units.party3.role = "NONE"
	Cast("party3", 2050)
	UnitGUID = guid
	check(ButtonFor("party3").fsrPhase == nil, "a secret GUID started it")
	MOCK.units.party3.role = "DAMAGER"
end)

step("5-second rule: drains over 5 seconds, then shows mana coming back until full", function()
	local FS, C = ns.FiveSecond, ns.db.appearance.fiveSecond
	local me = ButtonFor("player")
	local f = me.visual.fsr
	Tick(2)
	check(me.fsrPhase == "count" and math.abs(f.bar:GetValue() - 3) < 1e-6, "after 2 s: " .. tostring(f.bar:GetValue()))
	C.seconds = true
	ns:ApplySettings("appearance")
	check(f.text:IsShown() and f.text:GetText() == "3", "seconds number: " .. tostring(f.text:GetText()))
	-- a second spend starts it over
	Cast("player", 2050)
	check(math.abs(f.bar:GetValue() - 5) < 1e-6, "a new spend didn't restart the countdown")
	Tick(5.1)
	check(me.fsrPhase == "regen" and f.regen:IsShown() and not f.bar:IsShown() and not f.text:IsShown(), "after 5 s: expected mana coming back")
	check(not FS.driver:IsShown() and next(FS.active) == nil, "the driver keeps running after the countdown")
	-- mana is secret (combat, instances): keep showing; with the client's percent curve, the glow's alpha comes from it
	UnitPowerPercent = function() return MOCK.S(1) end
	MOCK.Fire("UNIT_POWER_UPDATE", "player", "MANA")
	check(me.fsrPhase == "regen" and f:IsShown(), "secret mana hid the glow")
	UnitPowerPercent = nil
	MOCK.Fire("UNIT_POWER_UPDATE", "player", "MANA")
	check(me.fsrPhase == "regen" and f:GetAlpha() == 1, "without the curve the glow stays on")
	-- readable and not full: still on; full: off, and the spend is forgotten
	MOCK.secretsOn = false
	MOCK.units.player.power = 60
	MOCK.Fire("UNIT_POWER_UPDATE", "player", "MANA")
	check(me.fsrPhase == "regen", "not full yet")
	MOCK.units.player.power = 100
	MOCK.Fire("UNIT_POWER_UPDATE", "player", "MANA")
	check(me.fsrPhase == nil and not f:IsShown() and next(FS.spent) == nil, "full mana didn't hide it")
	MOCK.secretsOn = true
	MOCK.units.player.power = 50
	-- in combat, unreadable: shown until combat ends
	Cast("player", 2050)
	Tick(6)
	check(me.fsrPhase == "regen", "expected mana coming back")
	MOCK.secretsOn = false
	MOCK.units.player.power = 100
	MOCK.Fire("PLAYER_REGEN_ENABLED")
	check(me.fsrPhase == nil, "full mana after combat didn't hide it")
	MOCK.secretsOn = true
	MOCK.units.player.power = 50
	-- dying ends it
	Cast("player", 2050)
	MOCK.units.player.dead = true
	FS:Update(me)
	check(me.fsrPhase == nil and next(FS.spent) == nil, "a dead player still counts")
	MOCK.units.player.dead = false
	C.seconds = false
	ns:ApplySettings("appearance")
	FS:Tick()
	check(not FS.driver:IsShown(), "driver left running")
end)

step("5-second rule: who it shows for, settings, chat and search", function()
	local FS, C = ns.FiveSecond, ns.db.appearance.fiveSecond
	wipe(FS.spent)
	-- party1 warrior tank (rage), party2 mage, party3 druid (no role), party4 rogue (energy)
	MOCK.units.party1.ptype = "RAGE"
	MOCK.units.party4.ptype = "ENERGY"
	MOCK.units.party3.role = "NONE"
	local function phases()
		local out = {}
		for _, u in ipairs({ "party1", "party2", "party3", "party4" }) do
			wipe(FS.spent)
			Cast(u, 2050)
			out[#out + 1] = ButtonFor(u).fsrPhase or "-"
		end
		wipe(FS.spent)
		FS:UpdateAll()
		return table.concat(out, " ")
	end
	local p = phases()
	check(p == "- - count -", "healers (druid with no role): " .. p)
	C.who = "all"
	p = phases()
	check(p == "- count count -", "everyone with mana: " .. p)
	C.who = "me"
	p = phases()
	check(p == "- - - -", "only me: " .. p)
	Cast("player", 2050)
	check(ButtonFor("player").fsrPhase == "count", "only me: my frame")
	C.enabled = false
	ns:ApplySettings("appearance")
	check(ButtonFor("player").fsrPhase == nil and not ButtonFor("player").visual.fsr:IsShown(), "turning it off didn't hide it")
	Cast("player", 2050)
	check(ButtonFor("player").fsrPhase == nil, "off, but a cast started it")
	C.enabled, C.who = true, "healers"
	-- a druid healer shifting out of mana form: hidden
	MOCK.units.party3.role = "HEALER"
	Cast("party3", 2050)
	check(ButtonFor("party3").fsrPhase == "count", "healer role")
	MOCK.units.party3.ptype = "ENERGY"
	MOCK.Fire("UNIT_DISPLAYPOWER", "party3")
	check(ButtonFor("party3").fsrPhase == nil, "cat form still shows it")
	MOCK.units.party3.ptype, MOCK.units.party3.role = nil, "DAMAGER"
	MOCK.units.party1.ptype, MOCK.units.party4.ptype = nil, nil
	wipe(FS.spent)
	FS:UpdateAll()
	FS:Tick()

	-- chat: the shared settings syntax
	local app = ns.app
	app:HandleSlash("appearance.fiveSecond.who all")
	check(C.who == "all", "chat didn't set who: " .. tostring(C.who))
	app:HandleSlash("appearance.fiveSecond.seconds on")
	check(C.seconds == true, "chat didn't turn the number on")
	app:HandleSlash("appearance.fiveSecond.who healers")
	app:HandleSlash("appearance.fiveSecond.seconds off")
	MOCK.RunTimers()
	check(C.who == "healers" and C.seconds == false, "chat: back to defaults")
	-- the typed command goes through lower case: keys still match
	SlashCmdList.LATTICE("appearance.fiveSecond.who all")
	check(C.who == "all", "typed (lower-cased) setting key didn't match")
	SlashCmdList.LATTICE("5sr off")
	check(C.enabled == false, "/lattice 5sr off")
	SlashCmdList.LATTICE("5sr")
	check(C.enabled == true, "/lattice 5sr flips it")
	SlashCmdList.LATTICE("5sr healers")
	check(C.enabled and C.who == "healers", "/lattice 5sr healers")
	MOCK.log = {}
	SlashCmdList.LATTICE("5sr sometimes")
	check(C.who == "healers" and table.concat(MOCK.log, " "):find("Example", 1, true), "a wrong word: no example given")
	MOCK.log = {}
	ns.app:HandleSlash("help")
	check(table.concat(MOCK.log, " "):find("5sr", 1, true), "help doesn't list 5sr")
	ns.app:HandleSlash("ai")
	local ai = LatticeAiHelpWindow.box:GetText()
	check(ai:find("- appearance.fiveSecond.who: Show it for. Choice: me = Only me; healers = Me and healers; all = Everyone who uses mana", 1, true)
		and ai:find("- appearance.fiveSecond.countColor:", 1, true), "AI help lacks the 5-second rule settings")
	LatticeAiHelpWindow:Hide()

	-- the settings window: found by its names
	local O = ns.Options
	O:Open("appearance")
	for _, q in ipairs({ "5sr", "five second rule", "mana regen", "spirit", "countdown color" }) do
		check(#O:Search(q) >= 1, "search found nothing for " .. q)
	end
	local labels = {}
	for _, r in ipairs(O:Search("5sr")) do labels[r.entry.info.label] = true end
	for _, l in ipairs({ "Show the 5-second rule", "Show it for", "Seconds left as a number", "Countdown color", "Mana coming back color" }) do
		check(labels[l], "search '5sr' misses " .. l)
	end
	O:StopSearch()
	O:Toggle()
end)

step("5-second rule: raid frames match by player, the preview shows samples", function()
	local FS = ns.FiveSecond
	MOCK.SetGroup(10, true)
	MOCK.Fire("GROUP_ROSTER_UPDATE")
	MOCK.UpdateAllHeaders()
	MOCK.RunTimers()
	wipe(FS.spent)
	-- the game names you "player" in the event; your raid frame is "raid1"
	Cast("player", 2050)
	check(ButtonFor("raid1").fsrPhase == "count", "your raid frame didn't start")
	Tick(5.1)
	check(ButtonFor("raid1").fsrPhase == "regen" and not FS.driver:IsShown(), "raid: expected mana coming back")
	wipe(FS.spent)
	FS:UpdateAll()
	ns.TestMode:Start(5)
	local shown = 0
	for _, w in ipairs(MOCK.widgets) do
		if rawget(w, "fake") and rawget(w, "visual") and w.visual.fsr and w.visual.fsr:IsVisible() then shown = shown + 1 end
	end
	check(shown >= 1, "the preview shows no sample")
	check(not FS.driver:IsShown(), "preview samples run the driver")
	ns.TestMode:Stop()
end)

local function Later(dt)
	MOCK.time = MOCK.time + dt
	MOCK.RunTimers()
end
-- the client ends a fade-out by itself; the mock needs a nudge
local function Settle()
	local f = ns.FiveSecondWidget.frame
	if f.fadeOut:IsPlaying() then
		f.fadeOut:Stop()
		f.fadeOut:GetScript("OnFinished")(f.fadeOut)
	end
end
local function Fight(on)
	MOCK.combat = on
	MOCK.Fire(on and "PLAYER_REGEN_DISABLED" or "PLAYER_REGEN_ENABLED")
end

step("5Sr bar: defaults, built at login, label, never takes the mouse, no numbers anywhere", function()
	local FW, W = ns.FiveSecondWidget, ns.db.appearance.fiveSecond.widget
	check(W.enabled == true and W.combatOnly == true and W.width == 120 and W.height == 10 and W.mp5 == true,
		"defaults: on, only in combat, 120 x 10, mp5 text")
	for _, k in ipairs(FW.GONE) do check(W[k] == nil, "old ring setting kept: " .. k) end
	local f = FW.frame
	check(f and _G.LatticeFiveSecondBar == f, "the bar wasn't built")
	check(FW.anchor:GetWidth() == 120 and FW.anchor:GetHeight() == 10, "size")
	-- one "5Sr", beside the bar: the move box adds none of its own (it showed twice while moving)
	check(f.label:GetText() == "5Sr" and (FW.anchor.label:GetText() or "") == "" and not FW.anchor.label:IsShown(), "label: " .. tostring(f.label:GetText()))
	check(not f:IsMouseEnabled() and not FW.anchor.overlay:IsShown(), "takes the mouse while locked")
	-- no Cooldown frame (nothing can draw countdown numbers) and no text but the label and mp5
	local function walk(w, fn)
		fn(w)
		for _, c in ipairs(rawget(w, "__children") or {}) do walk(c, fn) end
	end
	walk(f, function(w)
		check(w.__kind ~= "Cooldown", "a Cooldown frame in the bar")
		if w.__kind == "FontString" then check(w == f.label or w == f.mp5, "an extra text on the bar") end
	end)
	-- a /reload mid-fight: placed at once (it isn't secure), not after combat
	local placed = false
	rawset(FW.anchor, "SetPoint", function() placed = true end)
	MOCK.combat = true
	ns.Mover:RestorePosition(FW.anchor)
	MOCK.combat = false
	rawset(FW.anchor, "SetPoint", nil)
	check(placed, "the bar waits for combat to end to be placed")
end)

step("5Sr bar (not only in combat): counts up, bright with mp5, hidden at full", function()
	local FW, W, FS = ns.FiveSecondWidget, ns.db.appearance.fiveSecond.widget, ns.FiveSecond
	local f = FW.frame
	wipe(FS.spent)
	FW.spentAt = nil
	W.combatOnly = false
	MOCK.secretsOn = false
	GetManaRegen = function() return 8.4, 1.2 end
	MOCK.units.player.power = 100
	MOCK.Fire("UNIT_POWER_UPDATE", "player", "MANA")
	Settle()
	check(FW.state == nil and not f:IsShown(), "full mana out of combat: shown, got " .. tostring(FW.state))
	-- a spend: counts up from empty over 5 s, muted, no text
	Cast("player", 2050)
	check(FW.state == "count" and f:IsShown() and f.bar:GetValue() == 0 and FS.driver:IsShown(), "a spend didn't start counting")
	check(not f.mp5:IsShown() and not f.glow:IsShown(), "text or glow while counting")
	Tick(2)
	check(math.abs(f.bar:GetValue() - 2) < 1e-6, "after 2 s: " .. tostring(f.bar:GetValue()))
	Cast("player", 2050)
	check(FW.state == "count" and f.bar:GetValue() == 0, "a new spend didn't restart it")
	-- the 5 s are over, mana not full: bright, mp5 beside it, the driver stops
	MOCK.units.player.power = 60
	Tick(5.05)
	check(FW.state == "bright" and f.bar:GetValue() == 5 and f.glow:IsShown() and f.glow.breathe:IsPlaying(), "not bright after 5 s: " .. tostring(FW.state))
	check(f.mp5:IsShown() and f.mp5:GetText() == "mp5: 42", "mp5 text: " .. tostring(f.mp5:GetText()))
	check(not FS.driver:IsShown(), "the driver keeps running")
	W.mp5 = false
	ns:ApplySettings("appearance")
	check(not f.mp5:IsShown(), "mp5 text off but shown")
	W.mp5 = true
	GetManaRegen = function() return MOCK.Secret(8.4), MOCK.Secret(1.2) end
	ns:ApplySettings("appearance")
	check(FW.state == "bright" and not f.mp5:IsShown(), "secret mp5 shown")
	GetManaRegen = nil
	ns:ApplySettings("appearance")
	check(FW.state == "bright" and not f.mp5:IsShown(), "no regen data: text shown")
	-- full mana out of combat: fades away
	MOCK.units.player.power = 100
	MOCK.Fire("UNIT_POWER_UPDATE", "player", "MANA")
	check(FW.state == nil and f.fadeOut:IsPlaying(), "full mana: no fade out")
	Settle()
	check(not f:IsShown() and not f.glow.breathe:IsPlaying(), "faded but still shown")
	MOCK.secretsOn = true
	MOCK.units.player.power = 50
	W.combatOnly = true
	ns:ApplySettings("appearance")
	Settle()
	FS:Tick()
end)

step("5Sr bar: only in combat (shows when a fight starts, fades out after; full and secret mana never hide it in combat)", function()
	local FW, FS = ns.FiveSecondWidget, ns.FiveSecond
	local f = FW.frame
	FW.spentAt = nil
	check(FW.state == nil and not f:IsShown(), "out of combat: shown")
	Cast("player", 2050)
	check(FW.state == nil and not f:IsShown() and FW.spentAt and not FW.counting, "out of combat: a spend showed it")
	Later(1)
	Fight(true)
	check(FW.state == "count" and f:IsShown() and f.fadeIn:IsPlaying() and math.abs(f.bar:GetValue() - 1) < 1e-6, "combat start mid-count")
	Tick(4.1)
	check(FW.state == "bright", "in combat after 5 s: " .. tostring(FW.state))
	-- secret mana at full: the bar stays; only the glow is turned off by the client
	UnitPowerPercent = function(_, _, _, curve) check(curve, "no curve") return MOCK.S(0) end
	MOCK.Fire("UNIT_POWER_UPDATE", "player", "MANA")
	check(FW.state == "bright" and f:IsShown() and f:GetAlpha() == 1 and MOCK.isSecret(f.glow:GetAlpha()), "secret full mana hid the bar")
	UnitPowerPercent = nil
	MOCK.Fire("UNIT_POWER_UPDATE", "player", "MANA")
	check(f.glow:GetAlpha() == 1, "without the curve the glow stays")
	-- readable full mana in combat: a dim full bar
	MOCK.secretsOn = false
	MOCK.units.player.power = 100
	MOCK.Fire("UNIT_POWER_UPDATE", "player", "MANA")
	check(FW.state == "full" and f:IsShown() and not f.glow:IsShown() and not f.mp5:IsShown(), "full mana in combat hid the bar")
	MOCK.secretsOn = true
	MOCK.units.player.power = 50
	-- rapid casts
	for _ = 1, 12 do
		Tick(0.3)
		Cast("player", 2050)
	end
	check(FW.state == "count" and f.bar:GetValue() == 0 and FS.driver:IsShown(), "rapid casts")
	-- combat ends mid-count: fades out, the driver stops
	Fight(false)
	check(FW.state == nil and f.fadeOut:IsPlaying(), "combat end: snapped away instead of fading")
	FS:Tick()
	check(not FW.counting, "the bar still counts while hidden")
	Settle()
	check(not f:IsShown() and f:GetAlpha() == 1, "faded out but still shown")
	Fight(true)
	Fight(false)
	Fight(true)
	check(f:IsShown() and not f.fadeOut:IsPlaying(), "a new fight during the fade")
	Fight(false)
	Settle()
	-- moving always shows it, out of combat too
	SlashCmdList.LATTICE("5sr move")
	check(FW.state == "bright" and f:IsShown(), "moving out of combat: hidden")
	SlashCmdList.LATTICE("5sr lock")
	Settle()
	check(FW.state == nil and not f:IsShown(), "locked out of combat: still shown")
	-- off: nothing, even in combat
	FW:SetEnabled(false)
	Fight(true)
	check(not f:IsShown(), "off but shown in combat")
	Fight(false)
	FW:SetEnabled(true)
	Settle()
end)

step("5Sr bar: spends seen in combat (secret spell ID, secret cost, other unit names, secret power type)", function()
	local FW, FS = ns.FiveSecondWidget, ns.FiveSecond
	local f = FW.frame
	local function Fresh() FW.spentAt = nil; FW:Update() end
	Fight(true)
	Fresh()
	MOCK.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-4170-0-1-2050-0000ABCDEF", MOCK.S(2050))
	check(FW.state == "count", "secret spell ID: not counted")
	check(FS.SpellFromCast(MOCK.S("Cast-3-1-1-1-2050-0")) == nil and FS.SpellFromCast("junk") == nil, "bad cast GUIDs")
	check(FS.SpellCostsMana(2050) == true, "cost not learned")
	local get = C_Spell.GetSpellPowerCost
	C_Spell.GetSpellPowerCost = function() return MOCK.S({ { type = 0, cost = 55 } }) end
	Fresh()
	Cast("player", 2050)
	check(FW.state == "count", "secret cost: not counted")
	C_Spell.GetSpellPowerCost = function() return { { type = MOCK.S(0), cost = MOCK.S(55) } } end
	Fresh()
	Cast("player", 2050)
	check(FW.state == "count", "secret cost fields: not counted")
	Fresh()
	Cast("player", 1)
	check(FW.state ~= "count", "a free spell counted (never read)")
	C_Spell.GetSpellPowerCost = get
	Fight(false)
	local costs = C_Spell.GetSpellPowerCost
	C_Spell.GetSpellPowerCost = function(id) if id == 774 then return { { type = 0, cost = 30 } } end return costs(id) end
	FS:LearnCosts()
	C_Spell.GetSpellPowerCost = costs
	check(FS.costKnown[774] == true, "spellbook costs not learned")
	Fight(true)
	local isUnit = UnitIsUnit
	UnitIsUnit = function() return MOCK.S(true) end
	Fresh()
	Cast("raid1", 2050)
	UnitIsUnit = isUnit
	check(FW.state == "count", "your cast under raid1: not counted")
	local ptype = UnitPowerType
	UnitPowerType = function() return MOCK.S(0), MOCK.S("MANA") end
	FW:Update()
	check(FW.state == "count" and f:IsShown(), "secret power type hid it")
	UnitPowerType = ptype
	Fight(false)
	Settle()
	FS:Tick()
end)

step("5Sr bar: the frames' line off, other classes, death, size, old ring settings dropped", function()
	local FW, W, FS, C = ns.FiveSecondWidget, ns.db.appearance.fiveSecond.widget, ns.FiveSecond, ns.db.appearance.fiveSecond
	local f = FW.frame
	Fight(true)
	wipe(FS.spent)
	C.enabled = false
	ns:ApplySettings("appearance")
	Cast("player", 2050)
	check(FW.state == "count" and next(FS.spent) == nil, "frames' line off: the bar didn't count")
	FW:SetEnabled(false)
	check(FW.state == nil and not f:IsShown(), "off but shown")
	FW.spentAt = nil
	Cast("player", 2050)
	check(FW.state == nil and FW.spentAt == nil, "off, but a cast started it")
	C.enabled = true
	FW:SetEnabled(true)
	MOCK.units.player.ptype = "RAGE"
	MOCK.Fire("UNIT_DISPLAYPOWER", "player")
	check(FW.state == nil and not FW:Wanted(), "shown for rage")
	MOCK.units.player.ptype = nil
	MOCK.Fire("UNIT_DISPLAYPOWER", "player")
	Cast("player", 2050)
	MOCK.units.player.dead = true
	MOCK.Fire("PLAYER_DEAD")
	check(FW.state == nil and FW.spentAt == nil and not f:IsShown(), "dead: still shown")
	MOCK.units.player.dead = false
	MOCK.Fire("PLAYER_ALIVE")
	W.width, W.height = 200, 14
	ns:ApplySettings("appearance")
	check(FW.anchor:GetWidth() == 200 and FW.anchor:GetHeight() == 14, "size not applied")
	W.width, W.height = 1, 1000
	ns:ApplySettings("appearance")
	check(FW.anchor:GetWidth() == FW.MIN_W and FW.anchor:GetHeight() == FW.MAX_H, "size not clamped")
	W.width, W.height = 120, 10
	W.size, W.lightning, W.hideIdle = 64, true, false
	ns:ApplySettings("appearance")
	check(W.size == nil and W.lightning == nil and W.hideIdle == nil, "old ring settings kept")
	-- saved by the ring: the upgrade drops its settings, keeps on/off and Only in combat
	local sv = { schema = 4, profiles = { P = { appearance = { fiveSecond = { widget = {
		enabled = false, combatOnly = false, size = 40, lightning = false, hideIdle = false, fillColor = { 1, 0, 0, 1 } } } } } }, chars = {} }
	ns.Database:Migrate(sv)
	local w = sv.profiles.P.appearance.fiveSecond.widget
	check(w.enabled == false and w.combatOnly == false and w.size == nil and w.lightning == nil and w.hideIdle == nil and w.fillColor == nil,
		"upgrade from the ring")
	Fight(false)
	Settle()
	wipe(FS.spent)
	FS:UpdateAll()
	FS:Tick()
end)

step("5Sr bar: move and lock (on its own, with the frames, combat locks it)", function()
	local FW, M = ns.FiveSecondWidget, ns.Mover
	local f, a = FW.frame, FW.anchor
	MOCK.log = {}
	SlashCmdList.LATTICE("5sr move")
	check(M:IsSolo("fiveSecond") and not M:IsUnlocked(), "5sr move didn't move only the bar")
	check(a.overlay:IsShown() and FW.state == "bright" and f:IsShown(), "moving: no box or no sample")
	check(table.concat(MOCK.log, " "):find("5sr lock", 1, true), "no hint how to lock")
	a.overlay:GetScript("OnDragStart")(a.overlay)
	check(a.moving, "drag didn't start")
	a.overlay:GetScript("OnDragStop")(a.overlay)
	check(ns.db.positions.fiveSecond.y == 0, "position not saved")
	SlashCmdList.LATTICE("5sr lock")
	check(not M:IsSolo("fiveSecond") and not a.overlay:IsShown() and not f:IsMouseEnabled(), "5sr lock")
	M:SetUnlocked(true, true)
	check(a.overlay:IsShown() and FW.state == "bright", "unlock frames: the bar has no box")
	FW:SetEnabled(false)
	check(not a.overlay:IsShown() and not f:IsShown(), "bar off: its box still shows")
	FW:SetEnabled(true)
	check(a.overlay:IsShown(), "bar on: no box")
	M:SetUnlocked(false, true)
	check(not a.overlay:IsShown() and not FW:IsMoving(), "locked: still moving")
	Settle()
	FW:SetMoving(true)
	Fight(true)
	check(not M:IsSolo("fiveSecond") and not a.overlay:IsShown(), "combat didn't lock the bar")
	check(FW:SetMoving(true) == false, "moved in combat")
	Fight(false)
	Settle()
	ns.db.positions = ns.Util.CopyTable(ns.Defaults.positions)
	M:RestoreAll()
	check(ns.db.positions.fiveSecond.y == -140, "reset")
end)

step("5Sr bar: chat, help, settings button and search", function()
	local W = ns.db.appearance.fiveSecond.widget
	SlashCmdList.LATTICE("5sr widget off")
	check(W.enabled == false, "/lattice 5sr widget off")
	SlashCmdList.LATTICE("5sr widget on")
	check(W.enabled == true, "/lattice 5sr widget on")
	SlashCmdList.LATTICE("5sr widget")
	check(W.enabled == false, "/lattice 5sr widget flips it")
	SlashCmdList.LATTICE("5sr bar on")
	check(W.enabled == true, "/lattice 5sr bar on")
	MOCK.log = {}
	SlashCmdList.LATTICE("5sr widget maybe")
	check(W.enabled == true and table.concat(MOCK.log, " "):find("Example", 1, true), "a wrong word: no example")
	check(ns.db.appearance.fiveSecond.enabled == true, "bar commands changed the frames' line")
	ns.app:HandleSlash("appearance.fiveSecond.widget.width 160")
	MOCK.RunTimers()
	check(W.width == 160 and ns.FiveSecondWidget.anchor:GetWidth() == 160, "chat setting for the width")
	ns.app:HandleSlash("appearance.fiveSecond.widget.width 120")
	ns.app:HandleSlash("appearance.fiveSecond.widget.combatOnly off")
	check(W.combatOnly == false, "chat setting for only in combat")
	ns.app:HandleSlash("appearance.fiveSecond.widget.combatOnly on")
	MOCK.RunTimers()
	Settle()
	MOCK.log = {}
	ns.app:HandleSlash("help")
	check(table.concat(MOCK.log, " "):find("widget on", 1, true), "help doesn't list the bar")
	local O = ns.Options
	O:Open("appearance")
	local btn
	for _, w in ipairs(MOCK.widgets) do
		if rawget(w, "label") and w.label.GetText and w.label:GetText() == "Move the bar" then btn = w end
	end
	check(btn, "no Move the bar button")
	btn:GetScript("OnClick")(btn)
	check(ns.Mover:IsSolo("fiveSecond") and btn.label:GetText() == "Lock the bar", "the button didn't start moving")
	btn:GetScript("OnClick")(btn)
	check(not ns.Mover:IsSolo("fiveSecond") and btn.label:GetText() == "Move the bar", "the button didn't lock")
	Settle()
	for _, q in ipairs({ "5sr", "five second rule", "mana", "regen", "mp5", "bar", "spirit", "combat", "only in combat" }) do
		check(#O:Search(q) >= 1, "search found nothing for " .. q)
	end
	local labels = {}
	for _, r in ipairs(O:Search("5sr")) do labels[r.entry.info.label] = true end
	for _, l in ipairs({ "Show the 5Sr bar", "Only in combat", "Bar width", "Bar height", "Show mp5 beside the bar",
		"Counting up color", "Mana coming back color (bright)" }) do
		check(labels[l], "search '5sr' misses " .. l)
	end
	for l in pairs(labels) do check(not l:lower():find("ring", 1, true), "a ring setting is still there: " .. l) end
	O:StopSearch()
	O:Toggle()
end)

step("logout strips defaults", function()
	MOCK.Fire("PLAYER_LOGOUT")
	local p = LatticeDB.profiles.Default
	check(p.general == nil or next(p.general) == nil, "defaults not stripped from general")
end)

-- Guarded calls (S.Try / pcall) report failures to chat in debug mode; treat those as failures too.
for _, line in ipairs(MOCK.log) do
	if line:find("failed") or line:find("unavailable") then
		failures[#failures + 1] = "swallowed error: " .. line
		print("  FAIL swallowed: " .. line)
	end
end

print(string.format("\n%d passed, %d failed", passes, #failures))
if #MOCK.errors > 0 then
	print("error handler captured:")
	for _, e in ipairs(MOCK.errors) do print("  " .. tostring(e)) end
end
return #failures
