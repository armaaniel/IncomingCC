local ADDON_NAME = ...

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

-- Every enemy unit that can cast at you in an arena. Retail arena caps at three
-- opponents, and a unit can only cast one thing at a time, so six is a hard
-- ceiling on simultaneous bars.
local UNITS = {
    "arena1", "arena2", "arena3",
    "arenapet1", "arenapet2", "arenapet3",
}

local MAX_SLOTS = #UNITS
local POLL_INTERVAL = 0.05

local BAR_TEXTURE   = "Interface\\TargetingFrame\\UI-StatusBar"
local SPARK_TEXTURE = "Interface\\CastingBar\\UI-CastingBar-Spark"

-- Spells to force ON even if Blizzard's classifier doesn't call them crowd
-- control. Silences and interrupt-lockouts are the likely gaps.
local EXTRA_CC = {
    -- [19647] = true, -- Spell Lock
}

-- Spells to force OFF even if the classifier says they are crowd control.
local IGNORED = {
}

local defaults = {
    barWidth   = 220,
    barHeight  = 20,
    barGap     = 4,
    barColor   = { 1.0, 0.7, 0.0 },  -- classic sArena gold
    showCaster = true,
    showSpark  = true,
    locked     = true,
    point      = { "CENTER", "CENTER", 0, 150 },
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local bars = {}         -- [slotIndex] = StatusBar
local slotKey = {}      -- [slotIndex] = cast key, or nil when free
local keySlot = {}      -- [cast key] = slotIndex

local container
local settingsCategory
local elapsed = 0
local inArena = false
local previewing = false

local db  -- shorthand for IncomingCCDB, assigned in Initialize

local ApplyLayout, ApplyStyle, SetPreview  -- forward declarations

--------------------------------------------------------------------------------
-- Cast inspection
--------------------------------------------------------------------------------

-- PlayerIsSpellTarget replaced the older UnitIsSpellTarget, which Blizzard
-- removed. Kept behind one function so that if it changes again there is a
-- single place to fix. The UnitIsUnit path is the documented fallback other
-- addons used during the transition; it is less accurate because it reads the
-- caster's current target rather than the cast's bound target.
local function TargetsPlayer(unit)
    if PlayerIsSpellTarget then
        local ok, result = pcall(PlayerIsSpellTarget, unit)
        if ok then return result end
    end
    return UnitIsUnit(unit .. "target", "player")
end

local function IsCC(spellID)
    if IGNORED[spellID] then return false end
    if EXTRA_CC[spellID] then return true end
    if C_Spell and C_Spell.IsSpellCrowdControl then
        local ok, result = pcall(C_Spell.IsSpellCrowdControl, spellID)
        if ok then return result end
    end
    return false
end

-- Returns a table describing the unit's current cast if it is crowd control
-- aimed at us, otherwise nil.
local function GetIncomingCast(unit)
    if not UnitExists(unit) then return nil end

    local channeling = false
    local name, _, texture, startMS, endMS, _, _, _, spellID = UnitCastingInfo(unit)
    if not name then
        name, _, texture, startMS, endMS, _, _, spellID = UnitChannelInfo(unit)
        channeling = true
    end

    if not name or not spellID or not startMS or not endMS then return nil end
    if not IsCC(spellID) then return nil end
    if not TargetsPlayer(unit) then return nil end

    return {
        -- Identity is per-cast, not per-unit. A Felhunter that finishes one
        -- Devour Magic and immediately starts another is two casts; keying on
        -- unit alone would render them as one continuous bar. Start time
        -- distinguishes them, and unlike castID it also exists for channels.
        key        = unit .. ":" .. startMS,
        unit       = unit,
        spellID    = spellID,
        name       = name,
        texture    = texture,
        startMS    = startMS,
        endMS      = endMS,
        channeling = channeling,
    }
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

    -- Icon hangs off the left edge of the bar rather than sitting inside it.
    local icon = bar:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("RIGHT", bar, "LEFT", -5, 0)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    bar.icon = icon

    -- Additive spark riding the leading edge of the fill. This is the detail
    -- that makes it read as the old-style bar.
    local spark = bar:CreateTexture(nil, "OVERLAY")
    spark:SetTexture(SPARK_TEXTURE)
    spark:SetBlendMode("ADD")
    bar.spark = spark

    -- Spell name is centred across the bar. The symmetric left/right insets
    -- keep it centred while stopping long names from running under the timer.
    local spellText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    spellText:SetJustifyH("CENTER")
    spellText:SetWordWrap(false)
    bar.spellText = spellText

    local timerText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    timerText:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
    timerText:SetJustifyH("RIGHT")
    bar.timerText = timerText

    return bar
end

-- Re-applies size and stacking to the container and every bar. Called on load
-- and whenever a size slider changes, so the sliders update live.
function ApplyLayout()
    local w, h, gap = db.barWidth, db.barHeight, db.barGap

    container:SetSize(w, MAX_SLOTS * (h + gap))

    for i = 1, MAX_SLOTS do
        local bar = bars[i]
        bar:SetSize(w, h)
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -((i - 1) * (h + gap)))

        bar.icon:SetSize(h, h)

        -- Spark stands slightly taller than the bar, as on the classic frame.
        bar.spark:SetSize(16, h + 10)

        bar.spellText:ClearAllPoints()
        bar.spellText:SetPoint("LEFT", bar, "LEFT", 42, 0)
        bar.spellText:SetPoint("RIGHT", bar, "RIGHT", -42, 0)
    end
end

function ApplyStyle()
    local c = db.barColor
    for i = 1, MAX_SLOTS do
        bars[i]:SetStatusBarColor(c[1], c[2], c[3])
        bars[i].spark:SetShown(db.showSpark)
    end
end

local function FillBar(bar, info)
    bar.icon:SetTexture(info.texture)

    if db.showCaster then
        local caster = UnitName(info.unit) or info.unit
        bar.spellText:SetFormattedText("%s |cff999999- %s|r", info.name, caster)
    else
        bar.spellText:SetText(info.name)
    end
end

local function SetProgress(bar, progress)
    progress = math.max(0, math.min(1, progress))
    bar:SetValue(progress)

    if db.showSpark then
        bar.spark:ClearAllPoints()
        bar.spark:SetPoint("CENTER", bar, "LEFT", progress * db.barWidth, 0)
    end
end

local function UpdateBar(bar, info)
    local now = GetTime() * 1000
    local duration = info.endMS - info.startMS
    local progress

    if duration <= 0 then
        progress = 1
    elseif info.channeling then
        -- Channels drain rather than fill.
        progress = (info.endMS - now) / duration
    else
        progress = (now - info.startMS) / duration
    end

    SetProgress(bar, progress)
    bar.timerText:SetFormattedText("%.1f", math.max(0, (info.endMS - now) / 1000))
end

local function ReleaseSlot(index)
    local key = slotKey[index]
    if key then keySlot[key] = nil end
    slotKey[index] = nil
    bars[index]:Hide()
end

local function ReleaseAll()
    for i = 1, MAX_SLOTS do
        ReleaseSlot(i)
    end
end

--------------------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------------------

local activeList = {}

local function Poll()
    wipe(activeList)

    for _, unit in ipairs(UNITS) do
        local info = GetIncomingCast(unit)
        if info then
            activeList[#activeList + 1] = info
        end
    end

    -- Sort by start time so that when two casts begin on the same tick, the one
    -- that actually started first takes the higher slot.
    table.sort(activeList, function(a, b) return a.startMS < b.startMS end)

    local stillActive = {}
    for _, info in ipairs(activeList) do
        stillActive[info.key] = info
    end

    -- Free slots whose cast has ended, stopped being crowd control, or stopped
    -- pointing at us. Slots are not compacted: a surviving bar keeps its
    -- position rather than sliding up into the gap.
    for i = 1, MAX_SLOTS do
        local key = slotKey[i]
        if key and not stillActive[key] then
            ReleaseSlot(i)
        end
    end

    -- Assign new casts to the lowest free slot.
    for _, info in ipairs(activeList) do
        if not keySlot[info.key] then
            for i = 1, MAX_SLOTS do
                if not slotKey[i] then
                    slotKey[i] = info.key
                    keySlot[info.key] = i
                    FillBar(bars[i], info)
                    bars[i]:Show()
                    break
                end
            end
        end
    end

    for _, info in ipairs(activeList) do
        local index = keySlot[info.key]
        if index then
            UpdateBar(bars[index], info)
        end
    end
end

local function OnUpdate(self, delta)
    if previewing then return end
    if not inArena then return end

    elapsed = elapsed + delta
    if elapsed < POLL_INTERVAL then return end
    elapsed = 0

    Poll()
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

local PREVIEW_SAMPLES = {
    { name = "Polymorph", caster = "Enemy Mage",    texture = 136071, fill = 0.65, timer = 0.8 },
    { name = "Seduction", caster = "Sayaad",        texture = 136206, fill = 0.40, timer = 1.1 },
    { name = "Fear",      caster = "Enemy Warlock", texture = 136183, fill = 0.15, timer = 1.4 },
}

function SetPreview(enabled)
    previewing = enabled
    ReleaseAll()
    if not enabled then return end

    for i = 1, math.min(#PREVIEW_SAMPLES, MAX_SLOTS) do
        local s = PREVIEW_SAMPLES[i]
        local bar = bars[i]
        bar.icon:SetTexture(s.texture)
        if db.showCaster then
            bar.spellText:SetFormattedText("%s |cff999999- %s|r", s.name, s.caster)
        else
            bar.spellText:SetText(s.name)
        end
        bar.timerText:SetFormattedText("%.1f", s.timer)
        SetProgress(bar, s.fill)
        bar:Show()
    end
end

-- Refresh whatever is currently on screen after a cosmetic setting changes.
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
        category,
        ADDON_NAME .. "_" .. key,   -- globally unique variable id
        key,                        -- key written inside the table below
        db,                         -- values are saved straight into our DB
        "number",
        name,
        defaults[key]
    )
    local options = Settings.CreateSliderOptions(minV, maxV, step)
    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
    Settings.CreateSlider(category, setting, options, tooltip)
    setting:SetValueChangedCallback(RefreshVisuals)
    return setting
end

local function AddCheckbox(category, key, name, tooltip, onChanged)
    local setting = Settings.RegisterAddOnSetting(
        category, ADDON_NAME .. "_" .. key, key, db, "boolean", name, defaults[key]
    )
    Settings.CreateCheckbox(category, setting, tooltip)
    setting:SetValueChangedCallback(onChanged)
    return setting
end

local function BuildSettings()
    local category, layout = Settings.RegisterVerticalLayoutCategory("IncomingCC")
    settingsCategory = category

    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Size"))
    AddSlider(category, "barWidth",  "Bar Width",   "Width of each cast bar.",            120, 400, 5)
    AddSlider(category, "barHeight", "Bar Height",  "Height of each cast bar.",           14,  50,  1)
    AddSlider(category, "barGap",    "Bar Spacing", "Vertical gap between stacked bars.", 0,   20,  1)

    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Appearance"))
    AddCheckbox(category, "showSpark",  "Show Spark",       "Show the moving spark on the leading edge of the fill.", RefreshVisuals)
    AddCheckbox(category, "showCaster", "Show Caster Name", "Append the caster's name after the spell name.",         RefreshVisuals)

    -- Blizzard's settings layout has no built-in colour swatch, so this is a
    -- plain button that opens the shared ColorPickerFrame. Guarded because the
    -- button initializer is not present on every client build; /icc color
    -- always works regardless.
    if CreateSettingsButtonInitializer then
        layout:AddInitializer(CreateSettingsButtonInitializer(
            "Bar Colour", "Choose...", OpenColorPicker,
            "Pick the fill colour for the cast bars.", true
        ))
    end

    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Position"))
    AddCheckbox(category, "locked", "Lock Position", "Prevent the bars from being dragged.", ApplyLock)

    -- Preview is runtime-only state, so it uses a proxy setting rather than
    -- being written into saved variables.
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

local function UpdateZone()
    local _, instanceType = IsInInstance()
    inArena = (instanceType == "arena")
    if not inArena and not previewing then
        ReleaseAll()
    end
end

local function Initialize()
    IncomingCCDB = IncomingCCDB or {}
    db = IncomingCCDB
    for k, v in pairs(defaults) do
        if db[k] == nil then db[k] = v end
    end

    container = CreateFrame("Frame", "IncomingCCAnchor", UIParent)
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
    dragText:SetText("IncomingCC - drag to move")
    dragText:Hide()
    container.dragText = dragText

    for i = 1, MAX_SLOTS do
        bars[i] = CreateBar(i)
    end

    ApplyLayout()
    ApplyStyle()
    ApplyPosition()
    ApplyLock()
    UpdateZone()
    BuildSettings()

    container:SetScript("OnUpdate", OnUpdate)
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("ARENA_OPPONENT_UPDATE")
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            Initialize()
            self:UnregisterEvent("ADDON_LOADED")
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        UpdateZone()
    elseif event == "ARENA_OPPONENT_UPDATE" then
        -- An opponent dying or leaving does not always end their cast cleanly,
        -- so drop everything and let the next poll rebuild from live state.
        if not previewing then ReleaseAll() end
    end
end)

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

local function Print(msg)
    print("|cffffb300IncomingCC|r " .. msg)
end

SLASH_INCOMINGCC1 = "/icc"
SLASH_INCOMINGCC2 = "/incomingcc"
SlashCmdList.INCOMINGCC = function(msg)
    msg = strlower(strtrim(msg or ""))

    if msg == "unlock" then
        db.locked = false
        ApplyLock()
        SetPreview(true)
        Print("unlocked with preview bars. /icc lock when done")

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
