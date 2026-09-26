--[[  Profession Tool Manager  (WoW Midnight 12.1.0; verified vs wow-ui-source @ tag 12.1.0)

      Adds "Equip <stat>" buttons next to the native Create/Craft button on:
        * the crafter order craft page   ProfessionsFrame.OrdersPage.OrderView
        * the regular crafting page       ProfessionsFrame.CraftingPage
      Clicking one equips the best profession tool you own for that stat; you then click
      Blizzard's own Create/Craft button (never touched, so there's no taint/secure issue).

      A stat's button shows only when equipping is actually worthwhile, i.e. ALL of:
        * the recipe uses that stat -- it's listed in Crafting Details (operationInfo.bonusStats)
        * you own a tool granting it, higher-rated than (or different from) the equipped one
        * (Ingenuity only) "Apply Concentration" is on -- it does nothing otherwise
      The best tool is chosen by RATING, so a 150 Resourcefulness tool beats an equipped 100.

      Matching, per candidate tool:
        * Profession -> item subclass == the equipped tool's subclass (expansion-independent).
        * Expansion  -> item expac index == the CRAFT's expac. The craft's expac comes from the
          recipe's output item (or, for outputless recipes like enchants, its newest reagent),
          NOT the equipped tool or the tier name -- both are unreliable across expansions.

      Glow: the recommended button gets Blizzard's green NPE tutorial glow -- Multicraft on
      regular / Personal / Guild crafts that support it, Resourcefulness otherwise (Public /
      Patron orders, or recipes with no Multicraft). Ingenuity is a click option, never glowed.

      Tools are equipped via the cursor (PickupContainerItem -> PickupInventoryItem), the same
      primitives Blizzard's gear flyout uses; EquipItemByName does NOT work for profession tools.

      Verified facts: Enum.ItemClass.Profession = 19; tool equip loc "INVTYPE_PROFESSION_TOOL";
      profession-tool slot IDs Prof0 tool = 20, gear = 21/22; C_Item.GetItemStats / the tooltip
      give stat ratings; bonusStat.bonusStatName identifies the stat (bonusStatValue is the amount).
      "/ptm" prints a diagnostic; the DEBUG flag toggles verbose refresh logging.
]]

local PROFESSION_ITEM_CLASS = Enum.ItemClass.Profession        -- 19
local TOOL_EQUIPLOC         = "INVTYPE_PROFESSION_TOOL"
local NUM_BAGS              = NUM_BAG_SLOTS or 4               -- backpack(0) + bags(1..4)

-- Namespaced API handles.
--
-- 12.1.0 removed the GetInventorySlotInfo global and moved it to C_PaperDollInfo.
-- The old name only still resolves because of Blizzard_DeprecatedPaperDoll, a shim
-- addon that bails out unless the loadDeprecationFallbacks CVar is set, and whose
-- own header says it goes away next expansion. The item globals are the same deal,
-- just further along: C_Item is the real home, Blizzard_DeprecatedItemScript is the
-- shim. Bind the namespaced versions once here and fall back to the globals so this
-- file still runs unchanged on 12.0.x.
local GetInventorySlotInfo_ = (C_PaperDollInfo and C_PaperDollInfo.GetInventorySlotInfo) or GetInventorySlotInfo
local GetItemInfo_          = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemInfoInstant_   = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local GetItemStats_         = (C_Item and C_Item.GetItemStats) or GetItemStats

-- Locale needles for the tooltip fallback. The primary detector is C_Item.GetItemStats
-- (locale-independent keys); these are only used if that returns nothing useful.
-- Non-enUS clients: adjust or rely on GetItemStats keys. Use "/ptm dump" to inspect.
local NEEDLE_R = "Resourcefulness"
local NEEDLE_M = "Multicraft"
local NEEDLE_I = "Ingenuity"

-- Set to false to silence the diagnostic prints once equipping is confirmed working.
local DEBUG = false
local function dbg(...) if DEBUG then print("|cff66ccffPTM|r", ...) end end

-- module state ----------------------------------------------------------------
local hosts = {}            -- { { frame=, name=, place=fn, localOnly=, requireCreateShown=, rf=, mc=, ig=, wasShown=, retries= }, ... }
local curToolSlotID, curRF, curMC, curIG -- profession-global (same regardless of which page is up)
local statCache = {}        -- [itemLink] = { rVal, mVal, iVal } -- stable forever; survives idle eviction
local expacCache = {}       -- [recipeID] = expac index          -- craft expansion; stable per recipe

-- helpers ---------------------------------------------------------------------

-- Returns the tool's Resourcefulness and Multicraft RATING values (0 if absent). Numeric so we
-- can rank two tools of the same stat (e.g. a 100 vs a 150 Resourcefulness tool).
local function DetectStats(link)
	local rVal, mVal, iVal = 0, 0, 0
	if not link then return rVal, mVal, iVal end

	-- 1) Stat table: keys -> rating value (locale-independent).
	if GetItemStats_ then
		local ok, stats = pcall(GetItemStats_, link)
		if ok and type(stats) == "table" then
			for key, val in pairs(stats) do
				local K, num = tostring(key):upper(), tonumber(val) or 0
				if K:find("RESOURCEFUL") and num > rVal then rVal = num end
				if K:find("MULTICRAFT")  and num > mVal then mVal = num end
				if K:find("INGENUITY")   and num > iVal then iVal = num end
			end
		end
	end

	-- 2) Fallback: parse the "+N <stat>" tooltip lines (value = leading number on the line).
	if (rVal == 0 or mVal == 0 or iVal == 0) and C_TooltipInfo and C_TooltipInfo.GetHyperlink then
		local data = C_TooltipInfo.GetHyperlink(link)
		if data and data.lines then
			for _, line in ipairs(data.lines) do
				local t = line and line.leftText
				if t then
					local clean = t:gsub("|c%x+", "") -- strip any color escape before reading digits
					if rVal == 0 and clean:find(NEEDLE_R) then rVal = tonumber(clean:match("%d+")) or 1 end
					if mVal == 0 and clean:find(NEEDLE_M) then mVal = tonumber(clean:match("%d+")) or 1 end
					if iVal == 0 and clean:find(NEEDLE_I) then iVal = tonumber(clean:match("%d+")) or 1 end
				end
			end
		end
	end

	return rVal, mVal, iVal
end

-- Cached stat lookup. A tool's stats never change, so once known we cache by link and
-- reuse forever -- this survives the game evicting item data after you idle, so the
-- buttons reappear instantly. If the item's data isn't loaded yet we request it and
-- return best-effort; GET_ITEM_INFO_RECEIVED then refreshes once it arrives.
local function GetToolStats(link)
	if not link then return 0, 0, 0 end
	local c = statCache[link]
	if c then return c[1], c[2], c[3] end
	local r, m, i = DetectStats(link)
	if r > 0 or m > 0 or i > 0 then
		statCache[link] = { r, m, i }         -- a real reading is permanent -> cache it.
		                                      -- Never cache a not-yet-loaded 0/0/0 (that
		                                      -- previously left the buttons permanently blank).
	elseif C_Item and C_Item.RequestLoadItemDataByID then
		local id = GetItemInfoInstant_(link)  -- not resolved yet -> ensure a load so a refresh fires
		if id then C_Item.RequestLoadItemDataByID(id) end
	end
	return r, m, i
end

-- Resolve the inventory slot ID of the OPEN profession's tool slot.
local TOOL_SLOT_NAMES = { "PROF0TOOLSLOT", "PROF1TOOLSLOT", "COOKINGTOOLSLOT", "FISHINGTOOLSLOT" }
local function GetToolSlotID()
	local info = (C_TradeSkillUI.GetChildProfessionInfo and C_TradeSkillUI.GetChildProfessionInfo())
	          or (C_TradeSkillUI.GetBaseProfessionInfo  and C_TradeSkillUI.GetBaseProfessionInfo())
	if not info or not info.profession then return nil end

	local slots = C_TradeSkillUI.GetProfessionSlots(info.profession)
	if not slots or #slots == 0 then return nil end

	local slotSet = {}
	for _, s in ipairs(slots) do slotSet[s] = true end
	for _, name in ipairs(TOOL_SLOT_NAMES) do
		local ok, id = pcall(GetInventorySlotInfo_, name)
		if ok and id and slotSet[id] then return id end
	end
	return slots[1] -- convention: tool is the first profession slot
end

local function ItemMatches(link, refSub, targetExpac)
	local _, _, _, equipLoc, _, classID, subclassID = GetItemInfoInstant_(link)
	if classID ~= PROFESSION_ITEM_CLASS then return false end
	if equipLoc ~= TOOL_EQUIPLOC then return false end
	if refSub and subclassID ~= refSub then return false end                    -- same profession
	local expacID = select(15, GetItemInfo_(link))                              -- tool's expac index
	if targetExpac and expacID and expacID ~= targetExpac then return false end -- same expansion
	return true
end

-- Eligible tools (equipped + bags), using the equipped tool as profession/expansion reference.
local function EnumerateEligibleTools(targetExpac)
	local toolSlotID = GetToolSlotID()
	local equippedLink = toolSlotID and GetInventoryItemLink("player", toolSlotID) or nil
	local tools = {}
	if not equippedLink then return tools, nil, toolSlotID end

	local _, _, _, _, _, refClass, refSub = GetItemInfoInstant_(equippedLink)
	if refClass ~= PROFESSION_ITEM_CLASS then return tools, equippedLink, toolSlotID end
	-- Expansion = the craft's own expac index (passed in, from its output item) when known;
	-- otherwise fall back to the equipped tool's expac. Profession comes from the equipped tool.
	local expac = targetExpac or select(15, GetItemInfo_(equippedLink))

	local seen = {}
	local function consider(link, bag, slot)
		if not link or seen[link] then return end
		if not ItemMatches(link, refSub, expac) then return end
		seen[link] = true
		local rVal, mVal, iVal = GetToolStats(link)
		tools[#tools + 1] = { link = link, bag = bag, slot = slot, rVal = rVal, mVal = mVal, iVal = iVal, equipped = (link == equippedLink) }
	end

	consider(equippedLink) -- equipped tool has no bag/slot; we never re-equip it
	for bag = 0, NUM_BAGS do
		local n = C_Container.GetContainerNumSlots(bag)
		for slot = 1, n do
			consider(C_Container.GetContainerItemLink(bag, slot), bag, slot)
		end
	end
	return tools, equippedLink, toolSlotID
end

-- Highest-rated eligible tool for the stat (nil if none has it). The equipped tool is considered
-- first, so on a tie the equipped one wins (no needless swap); a strictly higher rating wins even
-- if the weaker tool is the one currently equipped -- that's the 100-vs-150 upgrade case.
local function PickTool(tools, want) -- want = "R", "M", or "I"
	local field = (want == "R" and "rVal") or (want == "M" and "mVal") or "iVal"
	local best, bestVal = nil, 0
	for _, t in ipairs(tools) do
		local v = t[field] or 0
		if v > bestVal then best, bestVal = t, v end
	end
	return best
end

-- Equip a bag tool into the profession tool slot via the cursor (same primitives as
-- Blizzard's gear flyout: PickupContainerItem -> PickupInventoryItem). EquipItemByName
-- does not reliably equip profession tools from addon code.
-- NOTE: we intentionally do NOT call C_PaperDollInfo.CanCursorCanGoInSlot() here -- that
-- helper targets character paperdoll slots (1-19) and rejects the profession tool slot.
local function EquipTool(target)
	if not target then dbg("click: no target (no matching tool)"); return end
	if target.equipped then dbg("click: that stat's tool is already equipped"); return end
	if InCombatLockdown() then
		UIErrorsFrame:AddMessage("Can't swap profession tools in combat.", 1, 0.3, 0.3)
		return
	end
	local invSlot = curToolSlotID
	dbg("equip", target.link, "from bag", target.bag, "slot", target.slot, "-> invSlot", invSlot)
	if not invSlot or not target.bag or not target.slot then dbg("abort: missing invSlot/bag/slot"); return end

	local before = GetInventoryItemLink("player", invSlot)
	ClearCursor()
	C_Container.PickupContainerItem(target.bag, target.slot)      -- new tool -> cursor
	if not CursorHasItem() then dbg("abort: nothing picked up from bag"); return end
	PickupInventoryItem(invSlot)                                 -- equip new; old tool -> cursor
	if CursorHasItem() then
		C_Container.PickupContainerItem(target.bag, target.slot) -- stow the swapped-out tool
	end
	ClearCursor()
	dbg("invSlot", invSlot, "before:", tostring(before), "after:", tostring(GetInventoryItemLink("player", invSlot)))
	-- UI also refreshes on PLAYER_EQUIPMENT_CHANGED
end

-- UI --------------------------------------------------------------------------

-- A button is only ever visible/hoverable when its target tool exists and is a real swap, so
-- we just show that tool plus a hint.
local function ButtonTooltip(self, target)
	if not (target and target.link) then return end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetHyperlink(target.link)
	GameTooltip:AddLine("Click to equip this tool.", 0.6, 0.8, 1)
	GameTooltip:Show()
end

-- Anchor the RIGHTMOST visible button to each page's spot; RefreshHost chains the other button
-- (when both are shown) to its left. Order view: on the Create button's row, just left of it
-- (the AH-style window is wide). Crafting page: just above the Create-All/Create cluster.
local function PlaceOrder(frame, btn)
	btn:ClearAllPoints()
	if frame.CreateButton then
		btn:SetPoint("RIGHT", frame.CreateButton, "LEFT", -8, 0)
	else
		btn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -110, 7)
	end
end

local function PlaceCrafting(frame, btn)
	btn:ClearAllPoints()
	-- Sit on the create-button row, just left of the cluster: anchor to the leftmost visible
	-- native button (Create All when it's shown, otherwise Create).
	local anchorTo = (frame.CreateAllButton and frame.CreateAllButton:IsShown() and frame.CreateAllButton)
		or frame.CreateButton
	if anchorTo then
		btn:SetPoint("RIGHT", anchorTo, "LEFT", -10, 0)
	else
		btn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, 7)
	end
end

local function EnsureWidgets(host)
	if host.rf then return end
	local frame = host.frame
	frame:HookScript("OnHide", function() host.wasShown = false end) -- so a reopen resets the retry budget

	host.rf = CreateFrame("Button", "ProfessionToolManager_" .. host.name .. "_RF", frame, "UIPanelButtonTemplate")
	host.rf:SetSize(160, 22)
	host.rf:SetText("Equip Resourcefulness")
	host.rf:SetScript("OnClick", function() EquipTool(curRF) end)
	host.rf:SetScript("OnEnter", function(self) ButtonTooltip(self, curRF) end)
	host.rf:SetScript("OnLeave", GameTooltip_Hide)

	host.mc = CreateFrame("Button", "ProfessionToolManager_" .. host.name .. "_MC", frame, "UIPanelButtonTemplate")
	host.mc:SetSize(150, 22)
	host.mc:SetText("Equip Multicraft")
	host.mc:SetScript("OnClick", function() EquipTool(curMC) end)
	host.mc:SetScript("OnEnter", function(self) ButtonTooltip(self, curMC) end)
	host.mc:SetScript("OnLeave", GameTooltip_Hide)

	host.ig = CreateFrame("Button", "ProfessionToolManager_" .. host.name .. "_IG", frame, "UIPanelButtonTemplate")
	host.ig:SetSize(140, 22)
	host.ig:SetText("Equip Ingenuity")
	host.ig:SetScript("OnClick", function() EquipTool(curIG) end)
	host.ig:SetScript("OnEnter", function(self) ButtonTooltip(self, curIG) end)
	host.ig:SetScript("OnLeave", GameTooltip_Hide)

	-- Draw above the order-view detail panel: its border sits at a high MEDIUM frame level
	-- and was covering the button art on the Orders page (only the label showed through).
	host.rf:SetFrameStrata("HIGH")
	host.mc:SetFrameStrata("HIGH")
	host.ig:SetFrameStrata("HIGH")

	host.rf:Hide(); host.mc:Hide(); host.ig:Hide() -- initial state; RefreshHost lays out the active one(s)
end

-- Glow the "active" (enabled) button with Blizzard's tutorial glow (NPE green glow, tuned for
-- red UIPanel buttons). Track state so we only Show/Hide on change (Show re-plays otherwise).
local function SetGlow(button, on)
	if not GlowEmitterFactory then return end
	if on and not button.ptmGlowing then
		button.ptmGlowing = true
		GlowEmitterFactory:Show(button, GlowEmitterMixin.Anims.NPE_RedButton_GreenGlow)
	elseif not on and button.ptmGlowing then
		button.ptmGlowing = nil
		GlowEmitterFactory:Hide(button)
	end
end

local function HideHost(host)
	if host.rf then
		SetGlow(host.rf, false); SetGlow(host.mc, false); SetGlow(host.ig, false)
		host.rf:Hide(); host.mc:Hide(); host.ig:Hide()
	end
end

-- The recipe form differs per page: the order view nests it under OrderDetails.
local function GetSchematicForm(host)
	local f = host.frame
	return (f.OrderDetails and f.OrderDetails.SchematicForm) or f.SchematicForm
end

local function GetDetails(host)
	local sf = GetSchematicForm(host)
	return sf and sf.Details
end

-- Is "Apply Concentration" currently toggled on for this craft? (Ingenuity only matters then.)
local function IsConcentrating(host)
	local sf = GetSchematicForm(host)
	local tx = sf and sf.transaction
	return (tx and tx.IsApplyingConcentration and tx:IsApplyingConcentration()) or false
end

-- Which crafting stats this recipe actually uses (i.e. shown in Crafting Details), plus whether
-- the details have been computed yet. A stat only appears when it applies to the craft -- so a
-- recipe that can't Multicraft simply has no Multicraft line, and we won't offer that button.
-- (bonusStatValue is the rating amount, so we identify the stat by its localized name.)
local function RecipeStatSupport(host)
	local details = GetDetails(host)
	local opInfo = details and details.operationInfo
	if not opInfo or not opInfo.bonusStats then return false, false, false, false end -- not ready yet
	local rf, mc, ig = false, false, false
	for _, b in ipairs(opInfo.bonusStats) do
		local name = b.bonusStatName
		if name then
			if name:find(NEEDLE_R) then rf = true end
			if name:find(NEEDLE_M) then mc = true end
			if name:find(NEEDLE_I) then ig = true end
		end
	end
	return rf, mc, ig, true
end

-- The craft's numeric expansion index, taken from its OUTPUT item (items carry a real expac,
-- unlike the tier which only exposes a themed name). Correct regardless of the equipped tool.
-- Returns nil for outputless recipes (e.g. enchants) or before the recipe data is ready.
local function CraftExpac(host)
	local details = GetDetails(host)
	local opInfo = details and details.operationInfo
	local recipeID = opInfo and opInfo.recipeID
	if not recipeID then return nil end
	if expacCache[recipeID] then return expacCache[recipeID] end -- stable per recipe -> reuse
	if not C_TradeSkillUI.GetRecipeSchematic then return nil end
	local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
	if not schematic then return nil end

	-- 1) Normal crafts: the output item's expansion (15th GetItemInfo return).
	local result
	if schematic.outputItemID then
		result = select(15, GetItemInfo_(schematic.outputItemID))
	end

	-- 2) Outputless recipes (enchants): use the NEWEST reagent's expansion. Craft reagents are
	--    the recipe's own expansion mats, so the max expac among them is the craft's expansion.
	--    Items/reagents carry the same expac numbering tools use, so this matches cleanly.
	if not result and schematic.reagentSlotSchematics then
		local best
		for _, slot in ipairs(schematic.reagentSlotSchematics) do
			for _, r in ipairs(slot.reagents or {}) do
				local e = r.itemID and select(15, GetItemInfo_(r.itemID))
				if e and (not best or e > best) then best = e end
			end
		end
		result = best
	end

	if result then expacCache[recipeID] = result end -- cache only resolved (non-nil) results
	return result
end

local function RefreshHost(host)
	if not host.frame then return end
	EnsureWidgets(host)

	-- Reset the load-retry budget each time the page is freshly opened.
	local shownNow = host.frame:IsShown()
	if shownNow and not host.wasShown then host.retries = 0 end
	host.wasShown = shownNow

	if host.localOnly then
		local localMode = Professions and Professions.InLocalCraftingMode and Professions.InLocalCraftingMode()
		if not localMode then HideHost(host); return end
	end

	local tools, equippedLink, toolSlotID = EnumerateEligibleTools(CraftExpac(host))
	curToolSlotID = toolSlotID
	curRF = PickTool(tools, "R")
	curMC = PickTool(tools, "M")
	curIG = PickTool(tools, "I")

	-- Does the recipe actually use each stat? (don't offer a swap for a stat the craft can't use)
	local rfSup, mcSup, igSup, statsReady = RecipeStatSupport(host)

	-- Actionable = recipe uses the stat, we own a better tool for it, and it isn't already the
	-- equipped one. PickTool ranks by rating, so a stronger same-stat tool counts as a swap.
	-- Ingenuity only matters while "Apply Concentration" is on, so it's additionally gated on that.
	local rfOn = (curRF ~= nil) and not curRF.equipped and rfSup
	local mcOn = (curMC ~= nil) and not curMC.equipped and mcSup
	local igOn = (curIG ~= nil) and not curIG.equipped and igSup and IsConcentrating(host)

	-- Poll while data is still loading: tools not enumerated, tool ratings not read yet, or the
	-- Crafting Details (operationInfo) not computed yet. Bounded; resets on each fresh open.
	local notReady = (not toolSlotID) or (not equippedLink)
	local statsUnresolved = (#tools >= 2) and not (curRF or curMC)
	if shownNow and (notReady or statsUnresolved or not statsReady) then
		host.retries = (host.retries or 0) + 1
		if host.retries <= 20 then
			C_Timer.After(0.25, function() if host.frame:IsShown() then RefreshHost(host) end end)
		end
	end

	-- On the order view, only show while the native Create button is shown (i.e. an accepted
	-- order you can actually craft). Other pages: no such requirement.
	local createShown = (not host.requireCreateShown)
		or (host.frame.CreateButton and host.frame.CreateButton:IsShown())

	-- Show only when there's an actionable swap; on the order view also require the Create button.
	local show = shownNow and createShown and (rfOn or mcOn or igOn)
	if DEBUG then
		dbg(host.name, "rfOn=" .. tostring(rfOn), "mcOn=" .. tostring(mcOn), "igOn=" .. tostring(igOn),
			"ready=" .. tostring(statsReady), "retries=" .. tostring(host.retries))
	end
	if not show then HideHost(host); return end

	-- Show only the actionable button(s); lay out right-to-left: Multicraft nearest the Create
	-- side, then Resourcefulness, then Ingenuity (the rare third) furthest out.
	host.rf:SetShown(rfOn); host.mc:SetShown(mcOn); host.ig:SetShown(igOn)
	local shown = {}
	if mcOn then shown[#shown + 1] = host.mc end
	if rfOn then shown[#shown + 1] = host.rf end
	if igOn then shown[#shown + 1] = host.ig end
	local prev
	for _, b in ipairs(shown) do
		b:ClearAllPoints()
		if prev then
			b:SetPoint("RIGHT", prev, "LEFT", -6, 0)
		else
			host.place(host.frame, b) -- rightmost anchored to the page's create spot
		end
		prev = b
	end

	-- Which stat to prioritise for the glow: Multicraft on regular / Personal / Guild crafts that
	-- support it; Resourcefulness otherwise (Public/Patron orders, or recipes with no Multicraft).
	local rec
	if not mcSup then
		rec = "R"
	else
		local ot = host.frame.order and host.frame.order.orderType
		rec = (ot == Enum.CraftingOrderType.Public or ot == Enum.CraftingOrderType.Npc) and "R" or "M"
	end
	SetGlow(host.rf, rec == "R" and rfOn)
	SetGlow(host.mc, rec == "M" and mcOn)
end

local function RefreshVisible()
	for _, host in ipairs(hosts) do
		if host.frame and host.frame:IsShown() then RefreshHost(host) end
	end
end

-- Coalesce bursts of GET_ITEM_INFO_RECEIVED (and other triggers) into a single refresh.
local refreshPending
local function ScheduleRefresh()
	if refreshPending then return end
	refreshPending = true
	C_Timer.After(0.05, function() refreshPending = false; RefreshVisible() end)
end

-- init ------------------------------------------------------------------------

local installed = false

local function Install()
	if installed then return true end

	local pf = ProfessionsFrame
	if not pf then return false end

	if C_AddOns and C_AddOns.LoadAddOn then pcall(C_AddOns.LoadAddOn, "Blizzard_FrameEffects") end -- for GlowEmitterFactory

	-- Host 1: crafter order craft page.
	-- IMPORTANT: hook the FRAME INSTANCES, not the mixin tables. Frames copy their mixin
	-- methods when created (before this runs), so hooking ProfessionsCrafterOrderViewMixin
	-- never fires for the live frame -- that's why the Order view never refreshed on open.
	local orderView = pf.OrdersPage and pf.OrdersPage.OrderView
	if orderView then
		local h = { frame = orderView, name = "Order", place = PlaceOrder, localOnly = false, requireCreateShown = true }
		hosts[#hosts + 1] = h
		orderView:HookScript("OnShow", function() RefreshHost(h) end)
		if orderView.SetOrder then hooksecurefunc(orderView, "SetOrder", function() RefreshHost(h) end) end
		-- keep our buttons in sync with the Create button's visibility (claimed vs not, etc.)
		if orderView.UpdateCreateButton then hooksecurefunc(orderView, "UpdateCreateButton", function() RefreshHost(h) end) end
		if orderView.SetOrderState then hooksecurefunc(orderView, "SetOrderState", function() RefreshHost(h) end) end
		local d = orderView.OrderDetails and orderView.OrderDetails.SchematicForm and orderView.OrderDetails.SchematicForm.Details
		if d and d.SetStats then hooksecurefunc(d, "SetStats", function() RefreshHost(h) end) end -- re-eval on Crafting Details change
	end

	-- Host 2: regular crafting page (same instance-hook approach)
	local craftingPage = pf.CraftingPage
	if craftingPage then
		local h = { frame = craftingPage, name = "Crafting", place = PlaceCrafting, localOnly = true, requireCreateShown = true }
		hosts[#hosts + 1] = h
		craftingPage:HookScript("OnShow", function() RefreshHost(h) end)
		if craftingPage.Init    then hooksecurefunc(craftingPage, "Init",    function() RefreshHost(h) end) end
		if craftingPage.Refresh then hooksecurefunc(craftingPage, "Refresh", function() RefreshHost(h) end) end
		-- ValidateControls governs the Create button (recipe select, recraft mode, reagents), so
		-- it's the reliable trigger to re-evaluate visibility -- e.g. hide when entering recraft.
		if craftingPage.ValidateControls then hooksecurefunc(craftingPage, "ValidateControls", ScheduleRefresh) end
		local d = craftingPage.SchematicForm and craftingPage.SchematicForm.Details
		if d and d.SetStats then hooksecurefunc(d, "SetStats", function() RefreshHost(h) end) end -- re-eval on Crafting Details change
	end

	local ev = CreateFrame("Frame")
	FrameUtil.RegisterFrameForEvents(ev, {
		"PLAYER_EQUIPMENT_CHANGED", -- tool swapped
		"BAG_UPDATE_DELAYED",       -- tools added / moved in bags
		"GET_ITEM_INFO_RECEIVED",   -- tool data streams in after opening
	})
	ev:SetScript("OnEvent", ScheduleRefresh)

	-- Blizzard fires this when you change profession or expansion tier (the dropdown) -- an
	-- official signal alongside our per-frame hooks.
	if EventRegistry then
		EventRegistry:RegisterCallback("Professions.ProfessionSelected", function() ScheduleRefresh() end, ev)
	end

	installed = true
	return true
end

-- Blizzard_Professions is load on demand, so on a normal login ProfessionsFrame
-- does not exist yet and Install() just reports "not yet".
--
-- This used to be a single EventUtil.ContinueOnAddOnLoaded("Blizzard_Professions")
-- call. That fires its callback exactly once and then forgets you, which stopped
-- being safe in 12.1.0: the TOC now starts with
--
--     Blizzard_Professions_Bootstrap.lua [Bootstrap]
--
-- a partition the client runs at startup, well before the rest of the addon. It
-- defines only ProfessionsFrame_LoadUI and friends. If ADDON_LOADED ever lands
-- for that early partition, a one-shot callback would run while ProfessionsFrame
-- is still nil, bail out, and never get a second chance -- no buttons, and no
-- error to explain why. So keep listening until the real files have actually run.
if not Install() then
	local watcher = CreateFrame("Frame")
	watcher:RegisterEvent("ADDON_LOADED")
	watcher:SetScript("OnEvent", function(self, _, addOnName)
		if addOnName == "Blizzard_Professions" and Install() then
			self:UnregisterEvent("ADDON_LOADED")
		end
	end)

	-- Belt and braces. ProfessionsFrame_LoadUI is what actually pulls the addon
	-- in, and it exists from startup on both 12.0.x (where it lived in
	-- UIParent.lua) and 12.1.0 (where it moved into the bootstrap partition), so
	-- this lands right after the load completes however ADDON_LOADED is timed.
	if type(ProfessionsFrame_LoadUI) == "function" then
		hooksecurefunc("ProfessionsFrame_LoadUI", Install)
	end
end

-- debug: /ptm   (list eligible tools)   |   /ptm dump   (also dump stat keys)
SLASH_PTM1 = "/ptm"
SlashCmdList["PTM"] = function(msg)
	local shownHost
	for _, h in ipairs(hosts) do if h.frame and h.frame:IsShown() then shownHost = h; break end end
	local craftExpac = shownHost and CraftExpac(shownHost)
	local tools, eq, slotID = EnumerateEligibleTools(craftExpac)
	local eqExpac = eq and select(15, GetItemInfo_(eq))
	print("|cff66ccffProfessionToolManager|r  craftExpac=" .. tostring(craftExpac) .. "  equippedExpac=" .. tostring(eqExpac) .. "  toolSlot=" .. tostring(slotID))
	print("  equipped=" .. tostring(eq))
	print("Eligible tools: " .. #tools)
	for i, t in ipairs(tools) do
		print(("  %d) %s  R=%s  M=%s  I=%s  bag=%s slot=%s%s"):format(i, tostring(t.link), tostring(t.rVal),
			tostring(t.mVal), tostring(t.iVal), tostring(t.bag), tostring(t.slot), t.equipped and "  (equipped)" or ""))
	end
	if msg == "dump" and eq then
		local ok, stats = pcall(GetItemStats_, eq)
		if ok and type(stats) == "table" then
			print("GetItemStats keys for equipped tool:")
			for k, v in pairs(stats) do print("   " .. tostring(k) .. " = " .. tostring(v)) end
		end
	end
	ScheduleRefresh() -- nudge the buttons to (re)appear on the visible page
end
