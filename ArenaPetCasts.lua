local ADDON_NAME = ...

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

local UNITS = { "arenapet1", "arenapet2", "arenapet3" }
local NUM_BARS = #UNITS

local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"

-- Blizzard's template ships a lot of art we don't want. These are hidden if
-- present; the list is defensive because region names change between builds.
local ART_REGIONS = {
    "Background", "BaseGlow", "Border", "BorderMask", "ChannelShadow",
    "CraftGlow", "CraftingMask", "DropShadow", "EnergyGlow", "EnergyMask",
    "Shine", "StandardGlow", "TextBorder", "WispGlow", "WispMask",
}

local defaults = {
    barWidth    = 220,
    barHeight   = 20,
    barGap      = 4,
    barColor    = { 1.0, 0.7, 0.0 },
    bgAlpha     = 0,
    onlyAtMe    = true,
    warlockOnly = true,
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

--------------------------------------------------------------------------------
-- Bars
--------------------------------------------------------------------------------

-- Blizzard's CastingBarMixin does all the work: it registers its own spellcast
-- events, drives the fill and the spark, handles channels and interrupts, and
-- resolves PlayerIsSpellTarget internally. It runs untainted, so it is allowed
-- to read secret values that addon code cannot touch. We only restyle it.
local function CreateBar(index)
    local bar = CreateFrame(
        "StatusBar",
        "ArenaPetCastBar" .. index,
        container,
        "CastingBarFrameTemplate"
    )

    for _, key in ipairs(ART_REGIONS) do
        local region = bar[key]
        if region and region.Hide then region:Hide() end
    end

    bar:SetStatusBarTexture(BAR_TEXTURE)

    -- Our own flat background behind the fill.
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 1)
    bar.ourBG = bg

    -- Regions dimmed together when the cast is not aimed at us. The background
    -- is deliberately excluded so its own opacity setting still applies.
    bar.dimRegions = { bar:GetStatusBarTexture() }
    for _, key in ipairs({ "Icon", "Spark", "Text", "CastTimeText", "BorderShield" }) do
        if bar[key] then bar.dimRegions[#bar.dimRegions + 1] = bar[key] end
    end

    -- Blizzard sets this from PlayerIsSpellTarget on its own schedule. Hooking
    -- it lets us mirror that secret boolean into alpha without ever reading it.
    if bar.SetIsHighlightedCastTarget then
        hooksecurefunc(bar, "SetIsHighlightedCastTarget", function(self, isTarget)
            if previewing or not db.onlyAtMe then return end
            for _, region in ipairs(self.dimRegions) do
                if region.SetAlphaFromBoolean then
                    pcall(region.SetAlphaFromBoolean, region, isTarget, 1, 0)
                end
            end
        end)
    end

    return bar
end

-- Anchors a list of bars consecutively from the top of the container. Bars are
-- positioned by how many are actually in use, not by their arena index, so a
-- lone warlock pet always renders in the top slot rather than leaving gaps.
local function PositionBars(active)
    local h, gap = db.barHeight, db.barGap
    for i, bar in ipairs(active) do
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -((i - 1) * (h + gap)))
    end
    container:SetHeight(math.max(1, #active) * (h + gap))
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
        bar.ourBG:SetAlpha(db.bgAlpha)

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
local function IsWarlockPet(index)
    local owner = "arena" .. index

    local class = UnitClassBase and UnitClassBase(owner)
    if class and not issecretvalue(class) then
        return class == "WARLOCK"
    end

    if GetArenaOpponentSpec and GetSpecializationInfoByID then
        local specID = GetArenaOpponentSpec(index)
        if specID and specID > 0 then
            local _, _, _, _, _, classFile = GetSpecializationInfoByID(specID)
            return classFile == "WARLOCK"
        end
    end

    return false
end

-- Binding a bar to nil unregisters its events, which is how a non-warlock pet
-- gets filtered out: the bar simply never has a unit to watch.
local function RefreshUnits()
    if previewing then return end

    local active = {}

    for i = 1, NUM_BARS do
        local bar = bars[i]
        local wanted = UNITS[i]

        if db.warlockOnly and not IsWarlockPet(i) then
            wanted = nil
        end

        bar:SetUnit(wanted, false, true)
        if wanted then
            if bar.SetHighlightWhenCastTarget then
                bar:SetHighlightWhenCastTarget(db.onlyAtMe)
            end
            active[#active + 1] = bar
        else
            bar:Hide()
        end
    end

    PositionBars(active)
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
        PositionBars(bars)
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
    AddCheckbox(category, "warlockOnly", "Warlock Pets Only", "Ignore hunter, mage, death knight and other pets.", RefreshVisuals)

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

    -- Opponent classes aren't known until prep, so rebind whenever the roster
    -- or the zone changes.
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
