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

local db
local debugging = false
local MAX_LOG = 500

-- Writes to saved variables so a session can be reviewed afterwards. Testing
-- this live is impractical - it needs an arena, an enemy pet, and a cast aimed
-- at you all at once - so the addon records its own reasoning instead.
local function Debug(fmt, ...)
    local line = date("%H:%M:%S") .. "  " .. string.format(fmt, ...)
    if debugging then print("|cff66ccffAPC|r " .. line) end
    if not db then return end
    db.log = db.log or {}
    db.log[#db.log + 1] = line
    while #db.log > MAX_LOG do table.remove(db.log, 1) end
end

local bars, visible, classCache = {}, {}, {}
local container, settingsCategory
local ApplyLayout, ApplyStyle, OpenColorPicker, Restack, ApplyTargetAlpha

--------------------------------------------------------------------------------
-- Owner class
--------------------------------------------------------------------------------

-- Resolved once per match. Spec data lands during prep and stays valid, so
-- re-deriving it on every roster event risks a lookup that worked at prep
-- failing later and hiding a bar mid-game.
-- Resolves and caches an opponent's class token. Class tokens ("WARLOCK") are
-- identical in every locale, unlike creature family names.
--
-- Called eagerly on prep and roster events rather than lazily at cast time:
-- GetNumArenaOpponentSpecs only answers once spec data has arrived, and by the
-- time a pet is casting mid-match that window may have closed. sArena resolves
-- on ARENA_PREP_OPPONENT_SPECIALIZATIONS for the same reason.
local function ResolveClasses()
    for i = 1, #UNITS do
        if not classCache[i] then
            if GetNumArenaOpponentSpecs and GetNumArenaOpponentSpecs() >= i then
                local specID = GetArenaOpponentSpec(i) or 0
                if specID > 0 then
                    local _, _, _, _, _, classFile = GetSpecializationInfoByID(specID)
                    if classFile then
                        classCache[i] = classFile
                        Debug("arena%d resolved as %s (spec)", i, classFile)
                    end
                end
            end

            if not classCache[i] and UnitClassBase then
                local class = UnitClassBase("arena" .. i)
                if class and not issecretvalue(class) then
                    classCache[i] = class
                    Debug("arena%d resolved as %s (unit)", i, class)
                end
            end
        end
    end
end

local function IsWarlock(index)
    local class = classCache[index]
    if class then return class == "WARLOCK" end

    -- One last attempt in case the pet cast before prep data landed.
    ResolveClasses()
    class = classCache[index]
    if class then return class == "WARLOCK" end

    -- Still unknown: show it. A stray bar beats silently showing nothing.
    Debug("arena%d class unresolved - showing anyway", index)
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
    bar.regions = { bar:GetStatusBarTexture(), icon, text, timer, bg }
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

local RegisterPetEvents
local testUnit  -- set by /apc testunit; bypasses the warlock filter

-- sArena re-evaluates this on every castbar event rather than once, because the
-- cast's target is not necessarily resolved the instant the cast begins. This
-- runs on the same tick that drives the timer.
function ApplyTargetAlpha(bar, unit)
    local function fallback()
        for _, region in ipairs(bar.regions) do
            region:SetAlpha(region == bar.bg and db.bgAlpha or 1)
        end
    end

    if not (db.onlyAtMe and PlayerIsSpellTarget) then
        return fallback()
    end

    local ok, isTarget = pcall(PlayerIsSpellTarget, unit)
    if not ok then
        Debug("%s: PlayerIsSpellTarget errored - showing regardless", unit)
        return fallback()
    end
    if not bar.loggedTarget then
        bar.loggedTarget = true
        Debug("%s: target check ok, secret=%s", unit, tostring(issecretvalue(isTarget)))
    end

    for _, region in ipairs(bar.regions) do
        local on = (region == bar.bg) and db.bgAlpha or 1
        -- A missing setter is a failure, not something to skip. Skipping left
        -- the alpha untouched, so every bar stayed visible.
        if not region.SetAlphaFromBoolean then
            Debug("%s: SetAlphaFromBoolean missing - showing regardless", unit)
            return fallback()
        end
        if not pcall(region.SetAlphaFromBoolean, region, isTarget, on, 0) then
            return fallback()
        end
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
            if bar.unitToken then ApplyTargetAlpha(bar, bar.unitToken) end
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

    ApplyTargetAlpha(bar, unit)

    -- GetTime() is not secret, so elapsed time can be measured even though the
    -- cast's own start and end stamps cannot be read.
    bar.startedAt = GetTime()
    bar.unitToken = unit
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
    bars[index].loggedTarget = nil
    bars[index].startedAt = nil
    bars[index].unitToken = nil
    bars[index].channeling = nil
    bars[index]:Hide()
    Restack()
end

-- Hides only bars whose unit has genuinely stopped casting. Roster events fire
-- constantly mid-match, and blanket-hiding on them kills bars for casts that
-- are still in progress. Nil tests on secrets are permitted, so this can ask
-- whether a cast exists without reading it.
local function PruneStale()
    for i, unit in ipairs(UNITS) do
        if visible[i] and not UnitCastingInfo(unit) and not UnitChannelInfo(unit) then
            Debug("%s: pruned, no longer casting", unit)
            HideCast(i)
        end
    end
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

-- Re-run whenever the arena roster changes. RegisterUnitEvent appears to bind
-- against the unit as it exists at registration time, so registering once at
-- load - out in the world, where no arenapet token resolves - leaves the
-- filter attached to nothing. sArena re-registers from its per-frame setup for
-- the same reason, and additionally watches UNIT_PET on each owner to catch
-- the moment an opponent's pet appears.
-- Registered unfiltered. RegisterUnitEvent's filter appears to resolve against
-- whether the unit currently exists, and arena opponents read as non-existent
-- whenever they are out of visual range - which is most of a match. Comparing
-- the token here instead removes that dependency; the cost is a table lookup
-- per cast in the world.
function RegisterPetEvents()
    for event in pairs(START) do f:RegisterEvent(event) end
    for event in pairs(STOP)  do f:RegisterEvent(event) end
    for i = 1, #UNITS do
        f:RegisterUnitEvent("UNIT_PET", "arena" .. i)
    end
end
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ARENA_OPPONENT_UPDATE")
f:RegisterEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS")

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
        end
        RegisterPetEvents()

        ApplyLayout()
        ApplyStyle()
        BuildSettings()
        SetLocked(db.locked ~= false)
        return
    end

    if START[event] or STOP[event] then
        -- Log every unit the game reports a cast for while in an arena. If an
        -- arenapet token never appears here, the game is not reporting pet
        -- casts at all and no amount of filtering will help.
        local _, instanceType = IsInInstance()
        if instanceType == "arena" and arg1 ~= "player" then
            Debug("CAST %s unit=%s mapped=%s", event, tostring(arg1),
                tostring(indexOf[arg1] or "-"))
        end

        -- Not one of ours: nothing further to do.
        if not indexOf[arg1] then return end
    end

    if START[event] then
        local i = indexOf[arg1]
        if i and db.locked then ShowCast(i, arg1) end
    elseif STOP[event] then
        local i = indexOf[arg1]
        if i and db.locked then HideCast(i) end
    elseif event == "UNIT_PET" then
        Debug("UNIT_PET for %s - rebinding", tostring(arg1))
        if not testUnit then RegisterPetEvents() end

    else
        -- Rebind on every roster change: the tokens only resolve once the
        -- units actually exist.
        if not testUnit and not debugging then RegisterPetEvents() end

        for i, u in ipairs(UNITS) do
            Debug("%s: pet exists=%s  owner exists=%s  class=%s",
                u, tostring(UnitExists(u)), tostring(UnitExists("arena" .. i)),
                tostring(classCache[i]))
        end

        if event == "PLAYER_ENTERING_WORLD" then
            local _, it = IsInInstance()
            Debug("=== PLAYER_ENTERING_WORLD  instanceType=%s ===", tostring(it))
            wipe(classCache)

            -- Being unlocked suppresses every cast bar. Leaving an arena in
            -- that state would silently disable the addon for a whole game,
            -- so entering an instance always re-locks.
            local _, instanceType = IsInInstance()
            if instanceType == "arena" and not db.locked then
                Debug("entered arena while unlocked - re-locking")
                SetLocked(true)
            end

            if db.locked then HideAll() end
            ResolveClasses()
        else
            if event == "ARENA_PREP_OPPONENT_SPECIALIZATIONS" then
                -- Solo shuffle rotates opponents between rounds without a zone
                -- change, so prep has to clear the cache as well as fill it.
                -- Otherwise round two filters against round one's classes.
                Debug("=== PREP  specs=%s ===",
                    tostring(GetNumArenaOpponentSpecs and GetNumArenaOpponentSpecs()))
                wipe(classCache)
                if db.locked then HideAll() end
            end

            -- Prep is when spec data arrives, so resolve here rather than
            -- waiting until a pet casts.
            ResolveClasses()

            -- ARENA_OPPONENT_UPDATE fires many times per match. Only drop bars
            -- whose cast has actually ended.
            if db.locked then PruneStale() end
        end
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
                testUnit = nil
                RegisterPetEvents()
                HideAll()
            end
            print("|cffffb300ArenaPetCasts|r test binding cleared")
            return
        end

        testUnit = unit
        indexOf[unit] = 1
        -- RegisterUnitEvent replaces the unit filter for that event, so the
        -- pet tokens go back on when the test is cleared.
        indexOf[unit] = 1
        for event in pairs(START) do f:RegisterEvent(event) end
        for event in pairs(STOP)  do f:RegisterEvent(event) end
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
            RegisterPetEvents()
            print("|cff66ccffAPC|r debug OFF")
        end

    elseif msg:match("^log") then
        db.log = db.log or {}
        if msg:match("clear") then
            wipe(db.log)
            print("|cff66ccffAPC|r log cleared")
            return
        end
        local n = #db.log
        print(string.format("|cff66ccffAPC|r %d entries (showing last 25)", n))
        for i = math.max(1, n - 24), n do print("  " .. db.log[i]) end
        print("|cff66ccffAPC|r full log is saved to:")
        print("  WTF\\Account\\<ACCOUNT>\\SavedVariables\\ArenaPetCasts.lua")
        print("  (log is written on logout or /reload)")

    elseif msg == "units" then
        for i, u in ipairs(UNITS) do
            print(string.format("|cff66ccffAPC|r %s exists=%s name=%s  owner arena%d exists=%s class=%s",
                u, tostring(UnitExists(u)), tostring(UnitName(u)), i,
                tostring(UnitExists("arena" .. i)), tostring(classCache[i])))
        end
        print(string.format("|cff66ccffAPC|r opponent specs = %s  locked = %s  onlyAtMe = %s",
            tostring(GetNumArenaOpponentSpecs and GetNumArenaOpponentSpecs()),
            tostring(db.locked), tostring(db.onlyAtMe)))

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
        print("  /apc log             show recent activity (saved to disk)")
        print("  /apc log clear       wipe the saved log")
    else
        if settingsCategory then Settings.OpenToCategory(settingsCategory:GetID()) end
    end
end
