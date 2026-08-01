local ADDON_NAME = ...

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

local UNITS = { "arenapet1", "arenapet2", "arenapet3" }
local NUM_BARS = #UNITS

local BAR_TEXTURE   = "Interface\\TargetingFrame\\UI-StatusBar"
local SPARK_TEXTURE = "Interface\\CastingBar\\UI-CastingBar-Spark"

local defaults = {
    barWidth   = 220,
    barHeight  = 20,
    barGap     = 4,
    barColor   = { 1.0, 0.7, 0.0 },
    showCaster = true,
    showSpark  = true,
    onlyAtMe   = true,
    locked     = true,
    point      = { "CENTER", "CENTER", 0, 150 },
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local bars = {}            -- [index] = StatusBar, one per unit, fixed position
local unitToBar = {}       -- [unitToken] = index
local container
local settingsCategory
local previewing = false
local db

local ApplyLayout, ApplyStyle, SetPreview

--------------------------------------------------------------------------------
-- Secret-value helpers
--------------------------------------------------------------------------------

-- Midnight forbids arithmetic, comparison and boolean tests on secret values.
-- Everything in this section hands secrets straight to Blizzard APIs that are
-- allowed to open them, and never inspects a value in Lua.

local function Try(fn, ...)
    if not fn then return false end
    local ok, result = pcall(fn, ...)
    return ok, result
end

-- Sets the visibility of every region on a bar from a secret boolean. Frames
-- have no confirmed SetAlphaFromBoolean, but textures and font strings do, so
-- the bar is dimmed region by region rather than hidden outright.
local function SetBarVisibleFromSecret(bar, secretBool)
    for _, region in ipairs(bar.regions) do
        if region.SetAlphaFromBoolean then
            pcall(region.SetAlphaFromBoolean, region, secretBool, 1, 0)
        end
    end
end

local function SetBarVisiblePlain(bar, visible)
    local alpha = visible and 1 or 0
    for _, region in ipairs(bar.regions) do
        region:SetAlpha(alpha)
    end
end

-- Drives the bar's fill from a duration object so the bar animates itself.
-- No timestamps are ever read into Lua. The exact CreateDuration signature is
-- not something I could verify, so both plausible shapes are attempted and the
-- working one is remembered.
local durationStyle

local function ApplyTimer(bar, startMS, endMS)
    if not (C_DurationUtil and C_DurationUtil.CreateDuration and bar.SetTimerDuration) then
        return false
    end

    local function attempt(style)
        local ok, duration
        if style == "range" then
            ok, duration = Try(C_DurationUtil.CreateDuration, startMS, endMS)
        else
            ok, duration = Try(C_DurationUtil.CreateDuration, endMS)
        end
        if not ok or not duration then return false end
        return (Try(bar.SetTimerDuration, bar, duration))
    end

    if durationStyle then return attempt(durationStyle) end

    if attempt("range") then
        durationStyle = "range"
        return true
    elseif attempt("single") then
        durationStyle = "single"
        return true
    end
    return false
end

--------------------------------------------------------------------------------
-- Bars
--------------------------------------------------------------------------------

local function CreateBar(index)
    local bar = CreateFrame("StatusBar", nil, container)
    bar:SetStatusBarTexture(BAR_TEXTURE)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    bar:Hide()

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.5)
    bar.bg = bg

    local icon = bar:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("RIGHT", bar, "LEFT", -5, 0)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    bar.icon = icon

    -- The spark is anchored to the fill texture's right edge rather than
    -- positioned by hand. The bar moves that edge internally, so the spark
    -- tracks the fill without any Lua ever reading the progress value.
    local spark = bar:CreateTexture(nil, "OVERLAY")
    spark:SetTexture(SPARK_TEXTURE)
    spark:SetBlendMode("ADD")
    spark:SetPoint("CENTER", bar:GetStatusBarTexture(), "RIGHT", 0, 0)
    bar.spark = spark

    local spellText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    spellText:SetJustifyH("CENTER")
    spellText:SetWordWrap(false)
    bar.spellText = spellText

    -- Regions whose alpha is driven from the secret target check.
    bar.regions = { bar:GetStatusBarTexture(), bg, icon, spark, spellText }

    return bar
end

function ApplyLayout()
    local w, h, gap = db.barWidth, db.barHeight, db.barGap
    container:SetSize(w, NUM_BARS * (h + gap))

    for i = 1, NUM_BARS do
        local bar = bars[i]
        bar:SetSize(w, h)
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -((i - 1) * (h + gap)))
        bar.icon:SetSize(h, h)
        bar.spark:SetSize(16, h + 10)
        bar.spellText:ClearAllPoints()
        bar.spellText:SetPoint("LEFT", bar, "LEFT", 6, 0)
        bar.spellText:SetPoint("RIGHT", bar, "RIGHT", -6, 0)
    end
end

function ApplyStyle()
    local c = db.barColor
    for i = 1, NUM_BARS do
        bars[i]:SetStatusBarColor(c[1], c[2], c[3])
        bars[i].spark:SetShown(db.showSpark)
    end
end

--------------------------------------------------------------------------------
-- Cast display
--------------------------------------------------------------------------------

local function ShowCast(unit)
    local index = unitToBar[unit]
    if not index then return end
    local bar = bars[index]

    local name, _, texture, startMS, endMS = UnitCastingInfo(unit)
    if not name then
        name, _, texture, startMS, endMS = UnitChannelInfo(unit)
    end

    -- Truthiness tests on non-boolean secrets are permitted, since nil-ness
    -- itself is not secret. This tells us a cast exists without reading it.
    if not name then
        bar:Hide()
        return
    end

    pcall(bar.icon.SetTexture, bar.icon, texture)

    -- Spell names may be rejected as secret strings. The caster name is a
    -- normal string, so it is set separately and survives either way.
    local label = ""
    if db.showCaster then
        label = UnitName(unit) or unit
    end
    local okName = false
    if not db.showCaster then
        okName = pcall(bar.spellText.SetText, bar.spellText, name)
    end
    if not okName then
        bar.spellText:SetText(label)
    end

    if not ApplyTimer(bar, startMS, endMS) then
        bar:SetValue(1)  -- no animation available; at least show the bar
    end

    bar:Show()

    if db.onlyAtMe and PlayerIsSpellTarget then
        local ok, targeted = pcall(PlayerIsSpellTarget, unit)
        if ok then
            SetBarVisibleFromSecret(bar, targeted)
        else
            SetBarVisiblePlain(bar, true)
        end
    else
        SetBarVisiblePlain(bar, true)
    end
end

local function HideCast(unit)
    local index = unitToBar[unit]
    if not index then return end
    bars[index]:Hide()
end

local function HideAll()
    for i = 1, NUM_BARS do
        bars[i]:Hide()
    end
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
    { label = "Felhunter",   texture = 136174, fill = 0.65 },
    { label = "Sayaad",      texture = 136206, fill = 0.40 },
    { label = "Voidwalker",  texture = 136221, fill = 0.15 },
}

function SetPreview(enabled)
    previewing = enabled
    HideAll()
    if not enabled then return end

    for i = 1, NUM_BARS do
        local s = PREVIEW[i]
        local bar = bars[i]
        bar.icon:SetTexture(s.texture)
        bar.spellText:SetText(s.label)
        bar:SetValue(s.fill)
        SetBarVisiblePlain(bar, true)
        bar:Show()
    end
end

local function RefreshVisuals()
    ApplyLayout()
    ApplyStyle()
    if previewing then SetPreview(true) end
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
    AddSlider(category, "barWidth",  "Bar Width",   "Width of each cast bar.",            120, 400, 5)
    AddSlider(category, "barHeight", "Bar Height",  "Height of each cast bar.",           14,  50,  1)
    AddSlider(category, "barGap",    "Bar Spacing", "Vertical gap between stacked bars.", 0,   20,  1)

    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Appearance"))
    AddCheckbox(category, "showSpark",  "Show Spark",       "Show the moving spark on the leading edge of the fill.", RefreshVisuals)
    AddCheckbox(category, "showCaster", "Show Pet Name",    "Label bars with the pet's name instead of the spell.",   RefreshVisuals)
    AddCheckbox(category, "onlyAtMe",   "Only Casts At Me", "Hide bars for pet casts aimed at someone else.",         RefreshVisuals)

    if CreateSettingsButtonInitializer then
        layout:AddInitializer(CreateSettingsButtonInitializer(
            "Bar Colour", "Choose...", OpenColorPicker,
            "Pick the fill colour for the cast bars.", true
        ))
    end

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

local START_EVENTS = {
    UNIT_SPELLCAST_START      = true,
    UNIT_SPELLCAST_CHANNEL_START = true,
}

local STOP_EVENTS = {
    UNIT_SPELLCAST_STOP           = true,
    UNIT_SPELLCAST_SUCCEEDED      = true,
    UNIT_SPELLCAST_FAILED         = true,
    UNIT_SPELLCAST_INTERRUPTED    = true,
    UNIT_SPELLCAST_CHANNEL_STOP   = true,
}

local function RegisterUnitEvents(frame)
    -- Unit tokens are never secret, so cast start and stop can be driven
    -- entirely by events. No polling and no timestamp arithmetic.
    for event in pairs(START_EVENTS) do
        for _, unit in ipairs(UNITS) do
            frame:RegisterUnitEvent(event, unit)
        end
    end
    for event in pairs(STOP_EVENTS) do
        for _, unit in ipairs(UNITS) do
            frame:RegisterUnitEvent(event, unit)
        end
    end
end

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
        unitToBar[UNITS[i]] = i
    end

    ApplyLayout()
    ApplyStyle()
    ApplyPosition()
    ApplyLock()
    BuildSettings()
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("ARENA_OPPONENT_UPDATE")
events:SetScript("OnEvent", function(self, event, unit)
    if event == "ADDON_LOADED" then
        if unit == ADDON_NAME then
            Initialize()
            RegisterUnitEvents(self)
            self:UnregisterEvent("ADDON_LOADED")
        end
        return
    end

    if previewing then return end

    if START_EVENTS[event] then
        ShowCast(unit)
    elseif STOP_EVENTS[event] then
        HideCast(unit)
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ARENA_OPPONENT_UPDATE" then
        HideAll()
    end
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
