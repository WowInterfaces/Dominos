--------------------------------------------------------------------------------
-- Action Bar
-- A pool of action bars
--------------------------------------------------------------------------------
local AddonName, Addon = ...

local L = LibStub('AceLocale-3.0'):GetLocale(AddonName)

local ACTION_BUTTON_COUNT = Addon.ACTION_BUTTON_COUNT
local ACTION_BUTTON_SHOW_GRID_REASON_ADDON = 1024
local ACTION_BUTTON_SHOW_GRID_REASON_KEYBOUND = 2048

local ActionBar = Addon:CreateClass('Frame', Addon.ButtonBar)

ActionBar.class = UnitClassBase('player')

-- Metatable magic. Basically this says, "create a new table for this index"
-- I do this so that I only create page tables for classes the user is actually
-- playing
ActionBar.defaultOffsets = {
    __index = function(t, i)
        t[i] = {}
        return t[i]
    end
}

-- Metatable magic.  Basically this says, 'create a new table for this index,
-- with these defaults. I do this so that I only create page tables for classes
-- the user is actually playing
ActionBar.mainbarOffsets = {
    __index = function(t, i)
        local pages = {
            page2 = 1,
            page3 = 2,
            page4 = 3,
            page5 = 4,
            page6 = 5
        }

        if i == 'DRUID' then
            pages.cat = 6
            pages.bear = 8
            pages.moonkin = 9
            pages.tree = 7
        elseif i == 'ROGUE' then
            pages.stealth = 6
            pages.shadowdance = 6
        elseif i == 'WARRIOR' and not Addon:IsBuild('retail') then
            pages.battle = 6
            pages.defensive = 7
            pages.berserker = 8
        elseif i == 'PRIEST' and not Addon:IsBuild('retail') then
            pages.shadowform = 6
        end

        t[i] = pages
        return pages
    end
}

ActionBar:Extend('OnLoadSettings', function(self)
    if self.id == 1 then
        setmetatable(self.sets.pages, self.mainbarOffsets)
    else
        setmetatable(self.sets.pages, self.defaultOffsets)
    end

    self.pages = self.sets.pages[self.class]
end)

ActionBar:Extend('OnAcquire', function(self)
    self:LoadStateController()
    self:LoadShowGridController()
    self:UpdateStateDriver()
    self:SetUnit(self:GetUnit())
    self:SetRightClickUnit(self:GetRightClickUnit())
    self:UpdateGrid(true)
    self:UpdateTransparent(true)
    self:UpdateFlyoutDirection()
end)

-- TODO: change the position code to be based more on the number of action bars
function ActionBar:GetDefaults()
    return {
        point = 'BOTTOM',
        x = 0,
        y = (ActionButton1:GetHeight() + 4) * (self.id - 1),
        pages = {},
        spacing = 2,
        padW = 2,
        padH = 2,
        numButtons = self:MaxLength(),
        showEmptyButtons = false,
        unit = "none",
        rightClickUnit = "none"
    }
end

function ActionBar:GetDisplayName()
    return L.ActionBarDisplayName:format(self.id)
end

-- returns the maximum possible size for a given bar
function ActionBar:MaxLength()
    return floor(ACTION_BUTTON_COUNT / Addon:NumBars())
end

function ActionBar:AcquireButton(index)
    local id = index + (self.id - 1) * self:MaxLength()
    local button = Addon.ActionButtons[id]

    button:SetAttribute('index', index)
    button:SetAttribute('statehidden', false)

    return button
end

function ActionBar:ReleaseButton(button)
    button:SetAttribute('statehidden', true)
    button:Hide()
end

function ActionBar:OnAttachButton(button)
    button:SetActionOffsetInsecure(self:GetAttribute('actionOffset') or 0)

    button:SetFlyoutDirection(self:GetFlyoutDirection())
    button:SetShowCountText(Addon:ShowCounts())
    button:SetShowMacroText(Addon:ShowMacroText())
    button:SetShowEquippedItemBorders(Addon:ShowEquippedItemBorders())
    button:SetShowCooldowns(self:GetAlpha() > 0)
    button:UpdateHotkeys()

    -- button:SetAttribute("showgrid", self:GetAttribute("showgrid"))
    -- button:UpdateShownInsecure()

    Addon:GetModule('ButtonThemer'):Register(button, self:GetDisplayName())
    Addon:GetModule('Tooltips'):Register(button)
end

function ActionBar:OnDetachButton(button)
    Addon:GetModule('ButtonThemer'):Unregister(button, self:GetDisplayName())
    Addon:GetModule('Tooltips'):Unregister(button)
end

-- paging
function ActionBar:SetOffset(stateId, page)
    self.pages[stateId] = page
    self:UpdateStateDriver()
end

function ActionBar:GetOffset(stateId)
    return self.pages[stateId]
end

function ActionBar:UpdateStateDriver()
    local conditions

    for _, state in Addon.BarStates:getAll() do
        local offset = self:GetOffset(state.id)

        if offset then
            local condition

            if type(state.value) == 'function' then
                condition = state.value()
            else
                condition = state.value
            end

            if condition then
                local page = Wrap(self.id + offset, Addon:NumBars())

                if conditions then
                    conditions = strjoin(';', conditions, (condition .. page))
                else
                    conditions = (condition .. page)
                end
            end
        end
    end

    if conditions then
        RegisterStateDriver(self, 'page', strjoin(';', conditions, self.id))
    else
        UnregisterStateDriver(self, 'page')
        self:SetAttribute('state-page', self.id)
    end
end

function ActionBar:LoadStateController()
    self:SetAttribute('barLength', self:MaxLength())
    self:SetAttribute('overrideBarLength', NUM_ACTIONBAR_BUTTONS)

    self:SetAttribute('_onstate-overridebar', [[ self:RunAttribute('UpdateOffset') ]])
    self:SetAttribute('_onstate-overridepage', [[ self:RunAttribute('UpdateOffset') ]])
    self:SetAttribute('_onstate-page', [[ self:RunAttribute('UpdateOffset') ]])

    self:SetAttribute('UpdateOffset', [[
        local offset = 0

        local overridePage = self:GetAttribute('state-overridepage') or 0
        if overridePage > 10 and self:GetAttribute('state-overridebar') then
            offset = (overridePage - 1) * self:GetAttribute('overrideBarLength')
        else
            local page = self:GetAttribute('state-page') or 1
            offset = (page - 1) * self:GetAttribute('barLength')
        end

        self:SetAttribute('actionOffset', offset)
        control:ChildUpdate('offset', offset)
    ]])

    self:UpdateOverrideBar()
end

-- watch for cursor changes, so that we can control action button visibility
-- on pickup
function ActionBar:LoadShowGridController()
    self:SetAttribute("showgrid", 0)

    self:SetAttribute("UpdateGrid", [[
        control:ChildUpdate('showgrid', self:GetAttribute("showgrid") or 0)
    ]])

    self:SetAttribute('_onstate-cursor', [[
        local reason = 2
        local old = self:GetAttribute("showgrid") or 0
        local new = old

        if newstate > 0 then
            if new % (2 * reason) < reason then
                new = new + reason
            end
        else
            if new % (2 * reason) >= reason then
                new = new - reason
            end
        end

        if old ~= new then
            self:SetAttribute("showgrid", new)
            self:RunAttribute("UpdateGrid")
        end
    ]])

    RegisterStateDriver(self, "cursor", "[cursor]2;0")
end

function ActionBar:UpdateOverrideBar()
    self:SetAttribute('state-overridebar', self:IsOverrideBar())
end

function ActionBar:IsOverrideBar()
    -- TODO: make overrideBar a property of the bar itself instead of a global
    -- setting
    return Addon.db.profile.possessBar == self.id
end

-- Empty button display
function ActionBar:ShowGrid(reason, force)
    if InCombatLockdown() then return end

    local old = self:GetAttribute("showgrid") or 0
    local new = bit.bor(old, reason)

    if (old ~= new) or force then
        self:SetAttribute("showgrid", new)
        self:Execute([[ self:RunAttribute("UpdateGrid") ]])
    end
end

function ActionBar:HideGrid(reason, force)
    if InCombatLockdown() then return end

    local old = self:GetAttribute("showgrid") or 0
    local new = bit.band(old, bit.bnot(reason))

    if (old ~= new) or force then
        self:SetAttribute("showgrid", new)
        self:Execute([[ self:RunAttribute("UpdateGrid") ]])
    end
end

function ActionBar:UpdateGrid(force)
    if Addon:ShowGrid() then
        self:ShowGrid(ACTION_BUTTON_SHOW_GRID_REASON_ADDON, force)
    else
        self:HideGrid(ACTION_BUTTON_SHOW_GRID_REASON_ADDON, force)
    end
end

-- keybound support
function ActionBar:KEYBOUND_ENABLED()
    self:ShowGrid(ACTION_BUTTON_SHOW_GRID_REASON_KEYBOUND)
end

function ActionBar:KEYBOUND_DISABLED()
    self:HideGrid(ACTION_BUTTON_SHOW_GRID_REASON_KEYBOUND)
end

-- right click targeting support
function ActionBar:SetUnit(unit)
    unit = unit or 'none'

    if unit == 'none' then
        self:SetAttribute('*unit*', nil)
    else
        self:SetAttribute('*unit*', unit)
    end

    self.sets.unit = unit
end

function ActionBar:GetUnit()
    return self.sets.unit or 'none'
end

function ActionBar:SetRightClickUnit(unit)
    unit = unit or 'none'

    if unit == 'none' then
        self:SetAttribute('*unit2', nil)
    else
        self:SetAttribute('*unit2', unit)
    end

    self.sets.rightClickUnit = unit
end

function ActionBar:GetRightClickUnit()
    local unit = self.sets.rightClickUnit

    if unit ~= "none" then
        return unit
    end

    return Addon:GetRightClickUnit() or "none"
end

function ActionBar:OnSetAlpha(_alpha)
    self:UpdateTransparent()
end

function ActionBar:UpdateTransparent(force)
    local isTransparent = self:GetAlpha() == 0

    if (self.__transparent ~= isTransparent) or force then
        self.__transparent = isTransparent

        self:ForButtons('SetShowCooldowns', not isTransparent)
    end
end

-- flyout direction calculations
function ActionBar:GetFlyoutDirection()
    local direction = self.sets.flyoutDirection or 'auto'

    if direction == 'auto' then
        return self:GetCalculatedFlyoutDirection()
    end

    return direction
end

function ActionBar:GetCalculatedFlyoutDirection()
    local width, height = self:GetSize()
    local _, relPoint = self:GetRelativePosition()

    if width < height then
        if relPoint:match('RIGHT') then
            return 'LEFT'
        end

        return 'RIGHT'
    end

    if relPoint and relPoint:match('TOP') then
        return 'DOWN'
    end
    return 'UP'
end

function ActionBar:SetFlyoutDirection(direction)
    local oldDirection = self.sets.flyoutDirection or 'auto'
    local newDirection = direction or 'auto'

    if oldDirection ~= newDirection then
        self.sets.flyoutDirection = newDirection
        self:UpdateFlyoutDirection()
    end
end

function ActionBar:UpdateFlyoutDirection()
    self:ForButtons('SetFlyoutDirection', self:GetFlyoutDirection())
end

ActionBar:Extend("Layout", ActionBar.UpdateFlyoutDirection)
ActionBar:Extend("Stick", ActionBar.UpdateFlyoutDirection)

-- exports
Addon.ActionBar = ActionBar
