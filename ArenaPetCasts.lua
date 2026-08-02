local ADDON_NAME = ...

-- Enemy warlock pets casting at you, in arena.
--
-- Cast timestamps are secret in Midnight, so no addon can animate a fill.
-- Blizzard's CastingBarMixin can, but only from untainted code - every attempt
-- to drive it from an addon dies on secret access. So these are solid bars:
-- they appear for the duration of the cast and vanish when it ends.
--
-- The only secrets this file touches are handed straight to Blizzard setters
-- that resolve them in C. Nothing is compared, indexed, or tested in Lua.

local UNITS = { "arenapet1", "arenapet2", "arenapet3" }

local TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"

local defaults = {
    width       = 220,
    height      = 22,
    gap         = 4,
    bgAlpha     = 0.5,
    color       = { 1.00, 0.70, 0.00 },
    ccColor     = { 0.90, 0.20, 0.20 },

    -- Real progress is unavailable, so the bar fills against this assumed
    -- duration. The elapsed counter beside it is exact, from GetTime(), so
    -- trust the number over the bar when they disagree.
    assumedCast = 1.5,

    -- Channels are the aftermath, not the warning: Seduction is cast first and
    -- channels once it has landed, by which point you are already crowd
    -- controlled. A channel also runs far longer than assumedCast, so its bar
    -- would empty immediately and sit at zero.
    showChannels = false,

    onlyAtMe    = true,
    locked      = true,
}

local bars, visible, classCache = {}, {}, {}
local container, db, settingsCategory
local ApplyLayout, ApplyStyle, OpenColorPicker, Restack

--------------------------------------------------------------------------------
-- Owner class
--------------------------------------------------------------------------------

-- Resolved once per match. Spec data lands during prep and stays valid, so
-- re-deriving it on every roster event risks a lookup that worked at prep
-- failing later and hiding a bar mid-game.
local function IsWarlock(index)
    local cached = classCache[index]
    if cached ~= nil then return cached == "WARLOCK" end

    if GetNumArenaOpponentSpecs and GetNumArenaOpponentSpecs() >= index then
        local specID = GetArenaOpponentSpec(index) or 0
        if specID > 0 then
            local _, _, _, _, _, classFile = GetSpecializationInfoByID(specID)
            if classFile then
                classCache[index] = classFile
                return classFile == "WARLOCK"
            end
        end
    end

    local class = UnitClassBase and UnitClassBase("arena" .. index)
    if class and not issecretvalue(class) then
        classCache[index] = class
        return class == "WARLOCK"
    end

    -- Unresolved: show it. A stray bar beats silently showing nothing, and the
    -- class usually resolves a moment later.
    return true
end

--------------------------------------------------------------------------------
-- Bars
--------------------------------------------------------------------------------

local function CreateBar()
    local bar = CreateFrame("StatusBar", nil, container)
    bar:SetStatusBarTexture(TEXTURE)
    bar:SetStatusBarColor(db.color[1], db.color[2], db.color[3])
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    bar:Hide()

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 1)
    bar.bg = bg

    local icon = bar:CreateTexture(nil, "ARTWORK")
    icon:SetSize(db.height, db.height)
    icon:SetPoint("RIGHT", bar, "LEFT", -4, 0)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    bar.icon = icon

    local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", bar, "LEFT", 5, 0)
    text:SetPoint("RIGHT", bar, "RIGHT", -5, 0)
    text:SetJustifyH("LEFT")
    bar.text = text

    local timer = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    timer:SetPoint("RIGHT", bar, "RIGHT", -5, 0)
    timer:SetJustifyH("RIGHT")
    bar.timer = timer
    text:SetPoint("RIGHT", bar, "RIGHT", -42, 0)

    -- Dimmed together when the cast is not aimed at us.
    bar.regions = { bar:GetStatusBarTexture(), icon, text, timer }
    return bar
end

function ApplyLayout()
    container:SetWidth(db.width)
    for _, bar in ipairs(bars) do
        bar:SetSize(db.width, db.height)
        bar.icon:SetSize(db.height, db.height)
        bar.text:ClearAllPoints()
        bar.text:SetPoint("LEFT", bar, "LEFT", 5, 0)
        bar.text:SetPoint("RIGHT", bar, "RIGHT", -42, 0)
    end
    Restack()
end

function ApplyStyle()
    for _, bar in ipairs(bars) do
        bar:SetStatusBarColor(db.color[1], db.color[2], db.color[3])
        bar.bg:SetAlpha(db.bgAlpha)
    end
    if container and container.bg then
        container.bg:SetColorTexture(db.color[1], db.color[2], db.color[3], 0.2)
    end
end

-- Visible bars stack from the top with no gaps.
function Restack()
    local n = 0
    for i, bar in ipairs(bars) do
        if visible[i] then
            bar:ClearAllPoints()
            bar:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -n * (db.height + db.gap))
            n = n + 1
        end
    end
end

local testUnit  -- set by /apc testunit; bypasses the warlock filter
local debugging = false

local function Debug(fmt, ...)
    if debugging then
        print("|cff66ccffAPC|r " .. string.format(fmt, ...))
    end
end

local ticker = CreateFrame("Frame")
ticker:Hide()
ticker:SetScript("OnUpdate", function()
    local any = false
    for i, bar in ipairs(bars) do
        if visible[i] and bar.startedAt then
            local elapsed = GetTime() - bar.startedAt
            local progress = math.min(elapsed / db.assumedCast, 1)
            -- Channels drain rather than fill. Seduction is a channel, so this
            -- covers the spell the addon mostly exists for.
            bar:SetValue(bar.channeling and (1 - progress) or progress)
            bar.timer:SetFormattedText("%.1f", elapsed)
            any = true
        end
    end
    if not any then ticker:Hide() end
end)

local function ShowCast(index, unit)
    if unit ~= testUnit and not IsWarlock(index) then
        Debug("%s: blocked by class filter (saw %s)", unit, tostring(classCache[index]))
        return
    end

    local channeling = false
    local name, _, texture, _, _, _, _, _, spellID = UnitCastingInfo(unit)
    if not name then
        if not db.showChannels then return end
        channeling = true
        name, _, texture, _, _, _, _, spellID = UnitChannelInfo(unit)
    end
    if not name then
        Debug("%s: event fired but no cast info", unit)
        return
    end
    Debug("%s: showing (channel=%s)", unit, tostring(channeling))

    local bar = bars[index]
    bar.icon:SetTexture(texture)
    bar.text:SetText(UnitName(unit) or unit)   -- pet name is not secret

    -- Colour carries "is this crowd control". The secret boolean goes straight
    -- into the C-side setter and is never read here.
    local tex = bar:GetStatusBarTexture()
    local coloured = false
    if C_Spell and C_Spell.IsSpellCrowdControl and tex.SetVertexColorFromBoolean and spellID ~= nil then
        local ok, isCC = pcall(C_Spell.IsSpellCrowdControl, spellID)
        if ok then
            coloured = pcall(tex.SetVertexColorFromBoolean, tex, isCC,
                CreateColor(db.ccColor[1], db.ccColor[2], db.ccColor[3]),
                CreateColor(db.color[1], db.color[2], db.color[3]))
        end
    end
    if not coloured then
        bar:SetStatusBarColor(db.color[1], db.color[2], db.color[3])
    end

    -- Alpha carries "is it aimed at me". Two conditions, two properties, so
    -- they never have to be combined in Lua - which isn't possible anyway.
    local dimmed = false
    if db.onlyAtMe and PlayerIsSpellTarget then
        local ok, isTarget = pcall(PlayerIsSpellTarget, unit)
        if ok then
            dimmed = true
            for _, region in ipairs(bar.regions) do
                if region.SetAlphaFromBoolean then
                    if not pcall(region.SetAlphaFromBoolean, region, isTarget, 1, 0) then
                        dimmed = false
                    end
                end
            end
        end
    end
    if not dimmed then
        for _, region in ipairs(bar.regions) do region:SetAlpha(1) end
    end

    -- GetTime() is not secret, so elapsed time can be measured even though the
    -- cast's own start and end stamps cannot be read.
    bar.startedAt = GetTime()
    bar.channeling = channeling
    bar:SetValue(channeling and 1 or 0)
    bar.timer:SetText("0.0")

    visible[index] = true
    bar:Show()
    Restack()
    ticker:Show()
end

local function HideCast(index)
    visible[index] = false
    bars[index].startedAt = nil
    bars[index].channeling = nil
    bars[index]:Hide()
    Restack()
end

local function HideAll()
    for i = 1, #bars do HideCast(i) end
end

--------------------------------------------------------------------------------
-- Colour picker
--------------------------------------------------------------------------------

function OpenColorPicker(key)
    local c = db[key]
    local function changed()
        local r, g, b = ColorPickerFrame:GetColorRGB()
        db[key] = { r, g, b }
        ApplyStyle()
    end
    local function cancelled()
        local r, g, b = ColorPickerFrame:GetPreviousValues()
        db[key] = { r, g, b }
        ApplyStyle()
    end
    ColorPickerFrame:SetupColorPickerAndShow({
        swatchFunc = changed, cancelFunc = cancelled,
        hasOpacity = false, r = c[1], g = c[2], b = c[3],
    })
end

--------------------------------------------------------------------------------
-- Settings panel
--------------------------------------------------------------------------------

local function Refresh()
    ApplyLayout()
    ApplyStyle()
end

local function AddSlider(cat, key, name, tip, lo, hi, step)
    local setting = Settings.RegisterAddOnSetting(
        cat, ADDON_NAME .. "_" .. key, key, db, "number", name, defaults[key])
    local opts = Settings.CreateSliderOptions(lo, hi, step)
    opts:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
    Settings.CreateSlider(cat, setting, opts, tip)
    setting:SetValueChangedCallback(Refresh)
end

local function AddCheck(cat, key, name, tip, fn)
    local setting = Settings.RegisterAddOnSetting(
        cat, ADDON_NAME .. "_" .. key, key, db, "boolean", name, defaults[key])
    Settings.CreateCheckbox(cat, setting, tip)
    setting:SetValueChangedCallback(fn or Refresh)
end

local function BuildSettings()
    local cat, layout = Settings.RegisterVerticalLayoutCategory("ArenaPetCasts")
    settingsCategory = cat

    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Size"))
    AddSlider(cat, "width",   "Bar Width",   "Width of each bar.",                    120, 400, 5)
    AddSlider(cat, "height",  "Bar Height",  "Height of each bar.",                   14,  50,  1)
    AddSlider(cat, "gap",     "Bar Spacing", "Gap between stacked bars.",             0,   20,  1)
    AddSlider(cat, "bgAlpha", "Background",  "Opacity behind the fill.",              0,   1,   0.05)

    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Timing"))
    AddSlider(cat, "assumedCast", "Assumed Cast Time",
        "Cast time the bar fills against. Real progress is unreadable, so this is an estimate - the number beside the bar is exact.",
        0.5, 4, 0.1)

    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Behaviour"))
    AddCheck(cat, "onlyAtMe", "Only Casts At Me",
        "Hide bars for pet casts aimed at someone else.")
    AddCheck(cat, "showChannels", "Show Channels",
        "Show bars while a pet is channelling. Off by default: the channel begins after the crowd control has already landed.")

    if CreateSettingsButtonInitializer then
        layout:AddInitializer(CreateSettingsButtonInitializer("Bar Colour", "Choose...",
            function() OpenColorPicker("color") end, "Fill colour for ordinary casts.", true))
        layout:AddInitializer(CreateSettingsButtonInitializer("Crowd Control Colour", "Choose...",
            function() OpenColorPicker("ccColor") end, "Fill colour when the cast is crowd control.", true))
    end

    Settings.RegisterAddOnCategory(cat)
end

--------------------------------------------------------------------------------
-- Anchor
--------------------------------------------------------------------------------

local function SetLocked(locked)
    db.locked = locked
    container:EnableMouse(not locked)
    container.bg:SetShown(not locked)
    for i, bar in ipairs(bars) do
        if not locked then
            bar.icon:SetTexture(136174)
            bar.text:SetText("Preview " .. i)
            bar.timer:SetText("0.8")
            bar.startedAt = nil
            bar:SetValue(0.55)
            for _, r in ipairs(bar.regions) do r:SetAlpha(1) end
            visible[i] = true
            bar:Show()
        elseif not UnitCastingInfo(UNITS[i]) then
            visible[i] = false
            bar:Hide()
        end
    end
    Restack()
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local START = { UNIT_SPELLCAST_START = true, UNIT_SPELLCAST_CHANNEL_START = true }
local STOP  = {
    UNIT_SPELLCAST_STOP = true, UNIT_SPELLCAST_CHANNEL_STOP = true,
    UNIT_SPELLCAST_SUCCEEDED = true, UNIT_SPELLCAST_INTERRUPTED = true,
    UNIT_SPELLCAST_FAILED = true,
}

local indexOf = {}

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ARENA_OPPONENT_UPDATE")

f:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        self:UnregisterEvent("ADDON_LOADED")

        ArenaPetCastsDB = ArenaPetCastsDB or {}
        db = ArenaPetCastsDB
        for k, v in pairs(defaults) do
            if db[k] == nil then db[k] = v end
        end

        container = CreateFrame("Frame", "ArenaPetCastsAnchor", UIParent)
        container:SetSize(db.width, #UNITS * (db.height + db.gap))
        container:SetFrameStrata("HIGH")
        container:SetMovable(true)
        container:RegisterForDrag("LeftButton")
        container:SetScript("OnDragStart", container.StartMoving)
        container:SetScript("OnDragStop", function(c)
            c:StopMovingOrSizing()
            local p, _, rp, x, y = c:GetPoint()
            db.point = { p, rp, x, y }
        end)

        local bg = container:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(db.color[1], db.color[2], db.color[3], 0.2)
        bg:Hide()
        container.bg = bg

        local p = db.point or { "CENTER", "CENTER", 0, 150 }
        container:SetPoint(p[1], UIParent, p[2], p[3], p[4])

        for i, unit in ipairs(UNITS) do
            bars[i] = CreateBar()
            indexOf[unit] = i
            for event in pairs(START) do self:RegisterUnitEvent(event, unit) end
            for event in pairs(STOP)  do self:RegisterUnitEvent(event, unit) end
        end

        ApplyLayout()
        ApplyStyle()
        BuildSettings()
        SetLocked(db.locked ~= false)
        return
    end

    if START[event] or STOP[event] then
        Debug("event %s unit=%s", event, tostring(arg1))
    end

    if START[event] then
        local i = indexOf[arg1]
        if i and db.locked then ShowCast(i, arg1) end
    elseif STOP[event] then
        local i = indexOf[arg1]
        if i and db.locked then HideCast(i) end
    else
        if event == "PLAYER_ENTERING_WORLD" then wipe(classCache) end
        if db.locked then HideAll() end
    end
end)

--------------------------------------------------------------------------------
-- Slash
--------------------------------------------------------------------------------

SLASH_ARENAPETCASTS1 = "/apc"
SlashCmdList.ARENAPETCASTS = function(msg)
    msg = strlower(strtrim(msg or ""))
    if msg == "unlock" then
        SetLocked(false)
        print("|cffffb300ArenaPetCasts|r unlocked - drag to move, /apc lock when done")
    elseif msg == "lock" then
        SetLocked(true)
        print("|cffffb300ArenaPetCasts|r locked")
    elseif msg:match("^testunit") then
        local unit = msg:match("^testunit%s+(%S+)")
        if not unit then
            print("|cffffb300ArenaPetCasts|r usage: /apc testunit target")
            print("  binds bar 1 to that unit so you can test outside arena")
            print("  /apc testunit off  to stop")
            return
        end
        if unit == "off" then
            if testUnit then
                f:UnregisterEvent("UNIT_SPELLCAST_START")
                f:UnregisterEvent("UNIT_SPELLCAST_CHANNEL_START")
                for event in pairs(START) do
                    for _, u in ipairs(UNITS) do f:RegisterUnitEvent(event, u) end
                end
                testUnit = nil
                HideAll()
            end
            print("|cffffb300ArenaPetCasts|r test binding cleared")
            return
        end

        testUnit = unit
        indexOf[unit] = 1
        -- RegisterUnitEvent replaces the unit filter for that event, so the
        -- pet tokens go back on when the test is cleared.
        for event in pairs(START) do f:RegisterUnitEvent(event, unit) end
        for event in pairs(STOP)  do f:RegisterUnitEvent(event, unit) end
        print("|cffffb300ArenaPetCasts|r bar 1 bound to " .. unit
            .. " - find something casting. /apc testunit off to undo")

    elseif msg == "debug" then
        debugging = not debugging
        for event in pairs(START) do f:UnregisterEvent(event) end
        for event in pairs(STOP)  do f:UnregisterEvent(event) end
        if debugging then
            -- Unfiltered: logs every unit the game reports, which reveals
            -- whether arenapet tokens ever appear in these events.
            for event in pairs(START) do f:RegisterEvent(event) end
            for event in pairs(STOP)  do f:RegisterEvent(event) end
            print("|cff66ccffAPC|r debug ON - all spellcast units will be logged")
            print("  run an arena, then /apc debug again to turn it off")
        else
            for event in pairs(START) do
                for _, u in ipairs(UNITS) do f:RegisterUnitEvent(event, u) end
            end
            for event in pairs(STOP) do
                for _, u in ipairs(UNITS) do f:RegisterUnitEvent(event, u) end
            end
            print("|cff66ccffAPC|r debug OFF")
        end

    elseif msg == "units" then
        for i, u in ipairs(UNITS) do
            print(string.format("|cff66ccffAPC|r %s exists=%s name=%s  owner arena%d exists=%s class=%s",
                u, tostring(UnitExists(u)), tostring(UnitName(u)), i,
                tostring(UnitExists("arena" .. i)), tostring(classCache[i])))
        end
        print(string.format("|cff66ccffAPC|r opponent specs = %s",
            tostring(GetNumArenaOpponentSpecs and GetNumArenaOpponentSpecs())))

    elseif msg == "reset" then
        db.point = nil
        container:ClearAllPoints()
        container:SetPoint("CENTER", UIParent, "CENTER", 0, 150)
        print("|cffffb300ArenaPetCasts|r position reset")
    elseif msg == "help" or msg == "?" then
        print("|cffffb300ArenaPetCasts|r commands:")
        print("  /apc                 open settings")
        print("  /apc unlock / lock   move the bars")
        print("  /apc reset           recentre")
        print("  /apc testunit target bind bar 1 to your target (test outside arena)")
        print("  /apc testunit off    undo the test binding")
        print("  /apc debug           log every spellcast unit (for arena issues)")
        print("  /apc units           check whether arenapet tokens exist")
    else
        if settingsCategory then Settings.OpenToCategory(settingsCategory:GetID()) end
    end
end
