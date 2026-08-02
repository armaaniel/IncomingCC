local ADDON_NAME = ...

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

local UNITS = { "arenapet1", "arenapet2", "arenapet3" }
local NUM_BARS = #UNITS

local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"

local defaults = {
    barWidth    = 220,
    barHeight   = 20,
    barGap      = 4,
    barColor    = { 1.0, 0.7, 0.0 },
    bgAlpha     = 0,
    onlyAtMe    = true,
    showIcon    = true,
    locked      = true,
    point       = { "CENTER", "CENTER", 0, 150 },
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local bars = {}
local container
local settingsCategory
local previewing = false
local db

local ApplyLayout, ApplyStyle, SetPreview
local PositionBars, ClaimSlot, ReleaseSlot, ClearSlots
local slots = {}

--------------------------------------------------------------------------------
-- Bars
--------------------------------------------------------------------------------

-- Blizzard's CastingBarMixin does all the work: it registers its own spellcast
-- events, drives the fill and the spark, handles channels and interrupts, and
-- resolves PlayerIsSpellTarget internally. It runs untainted, so it is allowed
-- to read secret values that addon code cannot touch. We only restyle it.
local function CreateBar(index)
    -- Everything about the frame - regions, mixin, scripts - comes from the
    -- XML template. Building it here in Lua is what made CastingBarMixin throw
    -- on secret access, so this file must not touch that wiring.
    local bar = CreateFrame(
        "StatusBar",
        "ArenaPetCastBar" .. index,
        container,
        "ArenaPetCastsBarTemplate"
    )

    -- Regions dimmed together when the cast is not aimed at us. The background
    -- is excluded so its own opacity setting still applies.
    bar.dimRegions = {
        bar:GetStatusBarTexture(), bar.Icon, bar.Spark, bar.Text, bar.BorderShield,
    }

    if bar.SetIsHighlightedCastTarget then
        hooksecurefunc(bar, "SetIsHighlightedCastTarget", function(self, isTarget)
            if previewing or not db.onlyAtMe then return end
            for _, region in ipairs(self.dimRegions) do
                local ok = false
                if region.SetAlphaFromBoolean then
                    ok = pcall(region.SetAlphaFromBoolean, region, isTarget, 1, 0)
                end
                if not ok then region:SetAlpha(1) end
            end
        end)
    end

    bar:HookScript("OnShow", function(self)
        if previewing then return end
        ClaimSlot(self)
    end)
    bar:HookScript("OnHide", function(self)
        if previewing then return end
        ReleaseSlot(self)
    end)

    return bar
end

-- Slots are claimed in cast order and held until that cast ends. A freed slot
-- is left as a hole rather than compacted, so a surviving bar keeps its
-- position instead of sliding up while you are reading it.
function PositionBars()
    local h, gap = db.barHeight, db.barGap
    local count = 0
    for i, bar in ipairs(slots) do
        if bar then
            bar:ClearAllPoints()
            bar:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -((i - 1) * (h + gap)))
            count = i
        end
    end
    container:SetHeight(math.max(1, count) * (h + gap))
end

function ClaimSlot(bar)
    for _, b in ipairs(slots) do
        if b == bar then return end
    end
    local target = #slots + 1
    for i, b in ipairs(slots) do
        if not b then target = i break end
    end
    slots[target] = bar
    PositionBars()
end

function ReleaseSlot(bar)
    local found
    for i, b in ipairs(slots) do
        if b == bar then slots[i] = false found = true break end
    end
    if not found then return end
    while #slots > 0 and not slots[#slots] do
        slots[#slots] = nil
    end
    PositionBars()
end

function ClearSlots()
    wipe(slots)
    PositionBars()
end

function ApplyLayout()
    local w, h = db.barWidth, db.barHeight
    container:SetWidth(w)

    for i = 1, NUM_BARS do
        local bar = bars[i]
        bar:SetSize(w, h)

        if bar.Icon then
            bar.Icon:SetSize(h, h)
            bar.Icon:ClearAllPoints()
            bar.Icon:SetPoint("RIGHT", bar, "LEFT", -4, 0)
            bar.Icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            bar.Icon:SetShown(db.showIcon)
        end

        if bar.Spark then
            bar.Spark:SetHeight(h + 10)
        end
    end
end

function ApplyStyle()
    local c = db.barColor
    for i = 1, NUM_BARS do
        local bar = bars[i]
        bar:SetStatusBarColor(c[1], c[2], c[3])
        bar.Background:SetAlpha(db.bgAlpha)

        -- With the filter off nothing dims the bar, so make sure a previous
        -- dimming pass isn't left over.
        if not db.onlyAtMe then
            for _, region in ipairs(bar.dimRegions) do
                region:SetAlpha(1)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Unit binding
--------------------------------------------------------------------------------

-- issecretvalue returns an ordinary boolean, so it is safe to branch on and
-- tells us whether the class came back readable before trusting it.
-- Resolved once per match and cached. Spec data arrives during prep and stays
-- valid for the rest of the game, so re-deriving it on every roster event -
-- which is what ARENA_OPPONENT_UPDATE fires on a death - risks a lookup that
-- worked at prep failing later and unbinding a bar mid-game.
local classCache = {}

local function ResolveClass(index)
    if classCache[index] then return classCache[index] end

    -- Spec API first: it is the route sArena treats as authoritative, and the
    -- count guard stops us asking before the data exists.
    if GetNumArenaOpponentSpecs and GetArenaOpponentSpec and GetSpecializationInfoByID then
        if GetNumArenaOpponentSpecs() >= index then
            local specID = GetArenaOpponentSpec(index) or 0
            if specID > 0 then
                local _, _, _, _, _, classFile = GetSpecializationInfoByID(specID)
                if classFile then
                    classCache[index] = classFile
                    return classFile
                end
            end
        end
    end

    -- Live unit lookup as a last resort. issecretvalue returns an ordinary
    -- boolean, so it is safe to branch on.
    local class = UnitClassBase and UnitClassBase("arena" .. index)
    if class and not issecretvalue(class) then
        classCache[index] = class
        return class
    end

    return nil
end

local function ShouldShowPet(index)
    local class = ResolveClass(index)
    -- Unknown class shows the bar rather than hiding it; the class usually
    -- resolves a moment later, and silently showing nothing is the worse bug.
    if not class then return true end
    return class == "WARLOCK"
end

-- Binding a bar to nil unregisters its events, which is how a non-warlock pet
-- gets filtered out: the bar simply never has a unit to watch.
local function RefreshUnits()
    if previewing then return end

    for i = 1, NUM_BARS do
        local bar = bars[i]
        local wanted = UNITS[i]

        if not ShouldShowPet(i) then
            wanted = nil
        end

        bar:SetUnit(wanted, false, true)

        -- Always hide on rebind. A bound bar with no cast in progress would
        -- otherwise sit on screen blank, because the mixin only hides a bar
        -- when it sees a cast end - and there was never a cast to end.
        bar:Hide()

        if wanted then
            if bar.SetHighlightWhenCastTarget then
                bar:SetHighlightWhenCastTarget(db.onlyAtMe)
            end
        end
    end

    ClearSlots()
end

--------------------------------------------------------------------------------
-- Positioning and preview
--------------------------------------------------------------------------------

local function SavePosition()
    local point, _, relPoint, x, y = container:GetPoint()
    db.point = { point, relPoint, x, y }
end

local function ApplyPosition()
    local p = db.point or defaults.point
    container:ClearAllPoints()
    container:SetPoint(p[1], UIParent, p[2], p[3], p[4])
end

local function ApplyLock()
    container:EnableMouse(not db.locked)
    container.dragBG:SetShown(not db.locked)
    container.dragText:SetShown(not db.locked)
end

local PREVIEW = {
    { label = "Felhunter",  texture = 136174, fill = 0.65 },
    { label = "Sayaad",     texture = 136206, fill = 0.40 },
    { label = "Voidwalker", texture = 136221, fill = 0.15 },
}

function SetPreview(enabled)
    previewing = enabled

    if enabled then
        wipe(slots)
        for i = 1, NUM_BARS do slots[i] = bars[i] end
        PositionBars()
    end

    for i = 1, NUM_BARS do
        local bar = bars[i]

        if enabled then
            -- Unbind so Blizzard's event handling doesn't overwrite the sample.
            bar:SetUnit(nil)
            local s = PREVIEW[i]
            if bar.Icon then bar.Icon:SetTexture(s.texture) end
            if bar.Text then bar.Text:SetText(s.label) end
            bar:SetMinMaxValues(0, 1)
            bar:SetValue(s.fill)
            for _, region in ipairs(bar.dimRegions) do
                region:SetAlpha(1)
            end
            bar:Show()
        else
            bar:Hide()
        end
    end

    if not enabled then RefreshUnits() end
end

local function RefreshVisuals()
    ApplyLayout()
    ApplyStyle()
    if previewing then
        SetPreview(true)
    else
        RefreshUnits()
    end
end

--------------------------------------------------------------------------------
-- Colour picker
--------------------------------------------------------------------------------

local function OpenColorPicker()
    local c = db.barColor

    local function OnChanged()
        local r, g, b = ColorPickerFrame:GetColorRGB()
        db.barColor = { r, g, b }
        ApplyStyle()
    end

    local function OnCancel()
        local r, g, b = ColorPickerFrame:GetPreviousValues()
        db.barColor = { r, g, b }
        ApplyStyle()
    end

    ColorPickerFrame:SetupColorPickerAndShow({
        swatchFunc = OnChanged,
        cancelFunc = OnCancel,
        hasOpacity = false,
        r = c[1], g = c[2], b = c[3],
    })
end

--------------------------------------------------------------------------------
-- Settings panel
--------------------------------------------------------------------------------

local function AddSlider(category, key, name, tooltip, minV, maxV, step)
    local setting = Settings.RegisterAddOnSetting(
        category, ADDON_NAME .. "_" .. key, key, db, "number", name, defaults[key]
    )
    local options = Settings.CreateSliderOptions(minV, maxV, step)
    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
    Settings.CreateSlider(category, setting, options, tooltip)
    setting:SetValueChangedCallback(RefreshVisuals)
end

local function AddCheckbox(category, key, name, tooltip, onChanged)
    local setting = Settings.RegisterAddOnSetting(
        category, ADDON_NAME .. "_" .. key, key, db, "boolean", name, defaults[key]
    )
    Settings.CreateCheckbox(category, setting, tooltip)
    setting:SetValueChangedCallback(onChanged)
end

local function BuildSettings()
    local category, layout = Settings.RegisterVerticalLayoutCategory("ArenaPetCasts")
    settingsCategory = category

    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Size"))
    AddSlider(category, "barWidth",  "Bar Width",   "Width of each cast bar.",                  120, 400, 5)
    AddSlider(category, "barHeight", "Bar Height",  "Height of each cast bar.",                 14,  50,  1)
    AddSlider(category, "barGap",    "Bar Spacing", "Vertical gap between stacked bars.",       0,   20,  1)
    AddSlider(category, "bgAlpha",   "Background",  "Opacity of the unfilled part of the bar.", 0,   1,   0.05)

    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Appearance"))
    AddCheckbox(category, "showIcon", "Show Spell Icon", "Show the spell icon beside the bar.", RefreshVisuals)

    if CreateSettingsButtonInitializer then
        layout:AddInitializer(CreateSettingsButtonInitializer(
            "Bar Colour", "Choose...", OpenColorPicker,
            "Pick the fill colour for the cast bars.", true
        ))
    end

    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Filtering"))
    AddCheckbox(category, "onlyAtMe",    "Only Casts At Me",  "Hide bars for pet casts aimed at someone else.",   RefreshVisuals)


    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Position"))
    AddCheckbox(category, "locked", "Lock Position", "Prevent the bars from being dragged.", ApplyLock)

    do
        local setting = Settings.RegisterProxySetting(
            category, ADDON_NAME .. "_preview", "boolean", "Show Preview Bars", false,
            function() return previewing end,
            function(value) SetPreview(value) end
        )
        Settings.CreateCheckbox(category, setting,
            "Show sample bars so you can size and position them outside of arena.")
    end

    Settings.RegisterAddOnCategory(category)
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local function Initialize()
    ArenaPetCastsDB = ArenaPetCastsDB or {}
    db = ArenaPetCastsDB
    for k, v in pairs(defaults) do
        if db[k] == nil then db[k] = v end
    end

    container = CreateFrame("Frame", "ArenaPetCastsAnchor", UIParent)
    container:SetFrameStrata("HIGH")
    container:SetMovable(true)
    container:RegisterForDrag("LeftButton")
    container:SetScript("OnDragStart", container.StartMoving)
    container:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)

    local dragBG = container:CreateTexture(nil, "BACKGROUND")
    dragBG:SetAllPoints()
    dragBG:SetColorTexture(1.0, 0.7, 0.0, 0.20)
    dragBG:Hide()
    container.dragBG = dragBG

    local dragText = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dragText:SetPoint("BOTTOM", container, "TOP", 0, 4)
    dragText:SetText("ArenaPetCasts - drag to move")
    dragText:Hide()
    container.dragText = dragText

    for i = 1, NUM_BARS do
        bars[i] = CreateBar(i)
    end

    ApplyLayout()
    ApplyStyle()
    ApplyPosition()
    ApplyLock()
    BuildSettings()
    RefreshUnits()
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("ARENA_OPPONENT_UPDATE")
events:RegisterEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS")
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            Initialize()
            self:UnregisterEvent("ADDON_LOADED")
        end
        return
    end

    -- Opponents change between matches, so the cache only survives one game.
    if event == "PLAYER_ENTERING_WORLD" then
        wipe(classCache)
    end

    -- Classes aren't known until prep, so keep retrying until they resolve.
    RefreshUnits()
end)

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

local function Print(msg)
    print("|cffffb300ArenaPetCasts|r " .. msg)
end

SLASH_ARENAPETCASTS1 = "/apc"
SlashCmdList.ARENAPETCASTS = function(msg)
    msg = strlower(strtrim(msg or ""))

    if msg == "unlock" then
        db.locked = false
        ApplyLock()
        SetPreview(true)
        Print("unlocked with preview bars. /apc lock when done")

    elseif msg == "lock" then
        db.locked = true
        ApplyLock()
        SetPreview(false)
        Print("locked")

    elseif msg == "color" or msg == "colour" then
        OpenColorPicker()

    elseif msg:match("^testunit") then
        local unit = msg:match("^testunit%s+(%S+)")
        if not unit then
            Print("usage: /apc testunit target   (or focus, mouseover, pet)")
            Print("binds the first bar to that unit so you can test anywhere")
            return
        end
        previewing = false
        local bar = bars[1]
        bar:SetUnit(unit, false, true)
        if bar.SetHighlightWhenCastTarget then
            bar:SetHighlightWhenCastTarget(db.onlyAtMe)
        end
        bar:Hide()
        wipe(slots)
        slots[1] = bar
        PositionBars()
        Print("bar 1 bound to " .. unit .. " - cast at something, or /apc lock to undo")

    elseif msg == "check" then
        Print("---- self check ----")
        Print(string.format("globals: CastingBarMixin=%s Mixin=%s hooksecurefunc=%s",
            tostring(CastingBarMixin ~= nil), tostring(Mixin ~= nil), tostring(hooksecurefunc ~= nil)))
        Print(string.format("apis: PlayerIsSpellTarget=%s issecretvalue=%s IsSpellCrowdControl=%s",
            tostring(PlayerIsSpellTarget ~= nil), tostring(issecretvalue ~= nil),
            tostring(C_Spell and C_Spell.IsSpellCrowdControl ~= nil)))

        Print(string.format("bars created: %d of %d", #bars, NUM_BARS))
        local b = bars[1]
        if not b then
            Print("BAR 1 MISSING - CreateFrame failed, template probably absent")
        else
            Print(string.format("bar1 methods: SetUnit=%s OnLoad=%s OnEvent=%s SetHighlightWhenCastTarget=%s",
                tostring(b.SetUnit ~= nil), tostring(b.OnLoad ~= nil),
                tostring(b.OnEvent ~= nil), tostring(b.SetHighlightWhenCastTarget ~= nil)))
            local tex = b:GetStatusBarTexture()
            Print(string.format("bar1 state: unit=%s shown=%s alpha=%.2f texAlpha=%.2f size=%dx%d",
                tostring(b.unit), tostring(b:IsShown()), b:GetAlpha(),
                tex and tex:GetAlpha() or -1,
                math.floor(b:GetWidth()), math.floor(b:GetHeight())))
        end

        local p1, _, p2, x, y = container:GetPoint()
        Print(string.format("anchor: shown=%s %s/%s x=%d y=%d size=%dx%d strata=%s",
            tostring(container:IsShown()), tostring(p1), tostring(p2),
            math.floor(x or 0), math.floor(y or 0),
            math.floor(container:GetWidth()), math.floor(container:GetHeight()),
            tostring(container:GetFrameStrata())))

        Print(string.format("settings: onlyAtMe=%s bgAlpha=%s locked=%s previewing=%s",
            tostring(db.onlyAtMe), tostring(db.bgAlpha), tostring(db.locked), tostring(previewing)))


        local inInst, instType = IsInInstance()
        Print(string.format("zone: inInstance=%s type=%s specs=%s",
            tostring(inInst), tostring(instType),
            tostring(GetNumArenaOpponentSpecs and GetNumArenaOpponentSpecs())))

        Print(string.format("target casting: %s", tostring(UnitCastingInfo("target") ~= nil)))
        Print("---- end ----")

    elseif msg == "status" then
        Print("bars bound:")
        for i = 1, NUM_BARS do
            local bar = bars[i]
            Print(string.format("  %s  unit=%s  class=%s  shown=%s",
                UNITS[i], tostring(bar.unit),
                tostring(classCache[i] or "unresolved"), tostring(bar:IsShown())))
        end
        Print(string.format("onlyAtMe=%s bgAlpha=%s specs=%s",
            tostring(db.onlyAtMe), tostring(db.bgAlpha),
            tostring(GetNumArenaOpponentSpecs and GetNumArenaOpponentSpecs())))

    elseif msg == "reset" then
        db.point = nil
        ApplyPosition()
        Print("position reset")

    else
        if settingsCategory then
            Settings.OpenToCategory(settingsCategory:GetID())
        end
    end
end
