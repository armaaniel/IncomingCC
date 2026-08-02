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

local WIDTH, HEIGHT, GAP = 220, 22, 4
local COLOR     = { 1.00, 0.70, 0.00 }
local CC_COLOR  = { 0.90, 0.20, 0.20 }
local TEXTURE   = "Interface\\TargetingFrame\\UI-StatusBar"

-- Cast timestamps are secret, so real progress is unavailable. The bar fills
-- against this assumed duration instead. The elapsed counter beside it is
-- exact - it comes from GetTime(), which is not secret - so trust the number
-- over the bar when they disagree.
local ASSUMED_CAST = 1.5

-- Channels are the aftermath, not the warning. Seduction is cast first and
-- channels once it has landed - by then you are already crowd controlled and
-- the bar tells you nothing you can act on. A channel also runs far longer
-- than ASSUMED_CAST, so its bar would empty immediately and then sit at zero.
-- Set true if you want them anyway.
local SHOW_CHANNELS = false

local bars, visible, classCache = {}, {}, {}
local container, db

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
    bar:SetSize(WIDTH, HEIGHT)
    bar:SetStatusBarTexture(TEXTURE)
    bar:SetStatusBarColor(COLOR[1], COLOR[2], COLOR[3])
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    bar:Hide()

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.5)

    local icon = bar:CreateTexture(nil, "ARTWORK")
    icon:SetSize(HEIGHT, HEIGHT)
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

-- Visible bars stack from the top with no gaps.
local function Restack()
    local n = 0
    for i, bar in ipairs(bars) do
        if visible[i] then
            bar:ClearAllPoints()
            bar:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -n * (HEIGHT + GAP))
            n = n + 1
        end
    end
end

local testUnit  -- set by /apc testunit; bypasses the warlock filter

local ticker = CreateFrame("Frame")
ticker:Hide()
ticker:SetScript("OnUpdate", function()
    local any = false
    for i, bar in ipairs(bars) do
        if visible[i] and bar.startedAt then
            local elapsed = GetTime() - bar.startedAt
            local progress = math.min(elapsed / ASSUMED_CAST, 1)
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
    if unit ~= testUnit and not IsWarlock(index) then return end

    local channeling = false
    local name, _, texture, _, _, _, _, _, spellID = UnitCastingInfo(unit)
    if not name then
        if not SHOW_CHANNELS then return end
        channeling = true
        name, _, texture, _, _, _, _, spellID = UnitChannelInfo(unit)
    end
    if not name then return end   -- nil tests on secrets are permitted

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
                CreateColor(CC_COLOR[1], CC_COLOR[2], CC_COLOR[3]),
                CreateColor(COLOR[1], COLOR[2], COLOR[3]))
        end
    end
    if not coloured then
        bar:SetStatusBarColor(COLOR[1], COLOR[2], COLOR[3])
    end

    -- Alpha carries "is it aimed at me". Two conditions, two properties, so
    -- they never have to be combined in Lua - which isn't possible anyway.
    local dimmed = false
    if PlayerIsSpellTarget then
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

        ArenaPetCastsDB = ArenaPetCastsDB or { locked = true }
        db = ArenaPetCastsDB

        container = CreateFrame("Frame", "ArenaPetCastsAnchor", UIParent)
        container:SetSize(WIDTH, #UNITS * (HEIGHT + GAP))
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
        bg:SetColorTexture(COLOR[1], COLOR[2], COLOR[3], 0.2)
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

        SetLocked(db.locked ~= false)
        return
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

    elseif msg == "reset" then
        db.point = nil
        container:ClearAllPoints()
        container:SetPoint("CENTER", UIParent, "CENTER", 0, 150)
        print("|cffffb300ArenaPetCasts|r position reset")
    else
        print("|cffffb300ArenaPetCasts|r  /apc unlock  |  /apc lock  |  /apc reset  |  /apc testunit target")
    end
end
