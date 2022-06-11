--[[
	███████ ██      ██ ██████  
	██      ██      ██ ██   ██ 
	███████ ██      ██ ██████  
		 ██ ██      ██ ██   ██ 
	███████ ███████ ██ ██████                                                  
]]

--#region SLIB

local filepath = _G.GetCurrentFilePath()
local localVersionPath = "lol\\Modules\\Common\\LocalSLib"
if not filepath:find(localVersionPath) and io.exists(localVersionPath .. ".lua") then
    require(localVersionPath)
    return
end

local Script = {
    Name = "SLib",
    Version = "1.0.1",
    LastUpdate = "03/01/2022",
}

local Common = {}

module(Script.Name, package.seeall, log.setup)
clean.module(Script.Name, clean.seeall, log.setup)

--#endregion

--[[
     █████  ██████  ██ 
    ██   ██ ██   ██ ██ 
    ███████ ██████  ██ 
    ██   ██ ██      ██ 
    ██   ██ ██      ██                                  
]]

--#region API

local SDK = _G.CoreEx
local Player = _G.Player

local DamageLib, CollisionLib, DashLib, HealthPred, ImmobileLib, Menu, Orbwalker, Prediction, Profiler, Spell, TS =
_G.Libs.DamageLib, _G.Libs.CollisionLib, _G.Libs.DashLib, _G.Libs.HealthPred, _G.Libs.ImmobileLib, _G.Libs.NewMenu,
_G.Libs.Orbwalker, _G.Libs.Prediction, _G.Libs.Profiler, _G.Libs.Spell, _G.Libs.TargetSelector()

local AutoUpdate, Enums, EvadeAPI, EventManager, Game, Geometry, Input, Nav, ObjectManager, Renderer =
SDK.AutoUpdate, SDK.Enums, SDK.EvadeAPI, SDK.EventManager, SDK.Game, SDK.Geometry, SDK.Input, SDK.Nav, SDK.ObjectManager, SDK.Renderer

local AbilityResourceTypes, BuffType, DamageTypes, Events, GameMaps, GameObjectOrders, HitChance, ItemSlots, 
ObjectTypeFlags, PerkIDs, QueueTypes, SpellSlots, SpellStates, Teams = 
Enums.AbilityResourceTypes, Enums.BuffTypes, Enums.DamageTypes, Enums.Events, Enums.GameMaps, Enums.GameObjectOrders,
Enums.HitChance, Enums.ItemSlots, Enums.ObjectTypeFlags, Enums.PerkIDs, Enums.QueueTypes, Enums.SpellSlots, Enums.SpellStates,
Enums.Teams

local Vector, BestCoveringCircle, BestCoveringCone, BestCoveringRectangle, Circle, CircleCircleIntersection,
Cone, LineCircleIntersection, Path, Polygon, Rectangle, Ring =
Geometry.Vector, Geometry.BestCoveringCircle, Geometry.BestCoveringCone, Geometry.BestCoveringRectangle, Geometry.Circle,
Geometry.CircleCircleIntersection, Geometry.Cone, Geometry.LineCircleIntersection, Geometry.Path, Geometry.Polygon,
Geometry.Rectangle, Geometry.Ring

local abs, acos, asin, atan, ceil, cos, deg, exp, floor, fmod, huge, log, max, min, modf, pi, rad, random, randomseed, sin,
sqrt, tan, type, ult = 
_G.math.abs, _G.math.acos, _G.math.asin, _G.math.atan, _G.math.ceil, _G.math.cos, _G.math.deg, _G.math.exp,
_G.math.floor, _G.math.fmod, _G.math.huge, _G.math.log, _G.math.max, _G.math.min, _G.math.modf, _G.math.pi, _G.math.rad,
_G.math.random, _G.math.randomseed, _G.math.sin, _G.math.sqrt, _G.math.tan, _G.math.type, _G.math.ult

local byte, char, dump, ends_with, find, format, gmatch, gsub, len, lower, match, pack, packsize, rep, reverse,
starts_with, sub, unpack, upper = 
_G.string.byte, _G.string.char, _G.string.dump, _G.string.ends_with, _G.string.find, _G.string.format,
_G.string.gmatch, _G.string.gsub, _G.string.len, _G.string.lower, _G.string.match, _G.string.pack, _G.string.packsize,
_G.string.rep, _G.string.reverse, _G.string.starts_with, _G.string.sub, _G.string.unpack, _G.string.upper

local clock, date, difftime, execute, exit, getenv, remove, rename, setlocale, time, tmpname = 
_G.os.clock, _G.os.date, _G.os.difftime, _G.os.execute, _G.os.exit, _G.os.getenv, _G.os.remove, _G.os.rename, _G.os.setlocale,
_G.os.time, _G.os.tmpname

local Resolution = Renderer.GetResolution()

---@type ItemIDs
local ItemID = require("lol\\Modules\\Common\\ItemID")

--#endregion

--[[
     ██████  ██████  ███    ███ ███    ███  ██████  ███    ██ 
    ██      ██    ██ ████  ████ ████  ████ ██    ██ ████   ██ 
    ██      ██    ██ ██ ████ ██ ██ ████ ██ ██    ██ ██ ██  ██ 
    ██      ██    ██ ██  ██  ██ ██  ██  ██ ██    ██ ██  ██ ██ 
     ██████  ██████  ██      ██ ██      ██  ██████  ██   ████                                                                                                              
]]

--#region Common

---@class SLib.Common
local Common = {
    MenuData = {},
    ShiftPressed = false,
    LMBPressed = false,
    LMBPosition = nil,
    LastClickT = 0,
    YellowTrinketDuration = 0,
}

function Common.CreateClass(name)
    if name then Script[name] = {} end
    local __class = name and Script[name] or {}
    __class.__index = __class
    return setmetatable(__class, {
        __call = function(self, ...)
            local obj = setmetatable({}, self)
            return obj:Initialize(...) or obj
        end
    })
end

function Common.GetHash(arg)
    return (floor(arg) % 1000)
end

function Common.Contains(t, e)
    for i, v in pairs(t) do
        if v == e then
            return i
        end
    end
    return false
end

local basePositions = {
    [100] = Vector(14302, 172, 14387),
    [200] = Vector(415, 182, 415),
}
function Common.GetBasePosition()
    return basePositions[Player.TeamId]
end

function Common.CalculateTravelTime(delay, speed, position)
    return (delay + Player:EdgeDistance(position) / speed) - (Game.GetLatency() / 1000)
end

function Common.SlotToString(slot)
    return ({ [0] = "Q", [1] = "W", [2] = "E", [3] = "R" })[slot]
end

function Common.ToHex(value)
    return tonumber("0x" .. format("%x", value):sub(1, 6) .. "00")
end

local decimalsT = {}
function Common.Round(number, decimals, n, method)
    decimals = decimals or 0    
    if method and math[method] then
        local factor = 10 ^ decimals
        return math[method](number * factor) / factor
    else
        if not decimalsT[decimals] then
            decimalsT[decimals] = "%."..decimals.."f"
        end
        local res = format(decimalsT[decimals], number)
        return (n and res) or tonumber(res)
    end
end

function Common.DecToMin(num)
    return format("%02d:%02d", floor(num / 60), num % 60)
end

function Common.DecToMin2(num)
    return format("%02d%02d", floor(num / 60), num % 60)
end

function Common.DecToMin3(num)
    local m = floor(num / 60)
    return (m < 1 and format("%d", num % 60)) or format("%dm", m)
end

function Common.CursorIsUnder(x, y, sizeX, sizeY, realMousePos)
    local mousePos = realMousePos and Renderer.GetCursorPos() or Common.LMBPosition
    if not mousePos then
        return false
    end
    local posX, posY = mousePos.x, mousePos.y
    if sizeY == nil then
        sizeY = sizeX
    end
    if sizeX < 0 then
        x = x + sizeX
        sizeX = -sizeX
    end
    if sizeY < 0 then
        y = y + sizeY
        sizeY = -sizeY
    end
    return posX >= x and posX <= x + sizeX and posY >= y and posY <= y + sizeY
end

local function __genOrderedIndex(t)
    local orderedIndex = {}
    for key in pairs(t) do
        table.insert(orderedIndex, key)
    end
    table.sort(orderedIndex)
    return orderedIndex
end

function Common.OrderedNext(t, state)
    local key = nil
    if state == nil then
        t.__orderedIndex = __genOrderedIndex(t)
        key = t.__orderedIndex[1]
    else
        for i = 1, table.getn(t.__orderedIndex) do
            if t.__orderedIndex[i] == state then
                key = t.__orderedIndex[i + 1]
            end
        end
    end
    if key then 
        return key, t[key] 
    end
    t.__orderedIndex = nil
    return
end

function Common.OrderedPairs(t)
    return Common.OrderedNext, t, nil
end

function Common.CreateCheckbox(id, displayText, defaultValue)
    Common.MenuData[id] = {
        id = id, 
        displayText = displayText, 
        defaultValue = defaultValue
    }
    Menu.Checkbox(id, displayText, defaultValue)
end

function Common.CreateSlider(id, displayText, defaultValue, minValue, maxValue, step)
    Common.MenuData[id] = {
        displayText = displayText, 
        defaultValue = defaultValue, 
        minValue = minValue, 
        maxValue = maxValue, 
        step = step
    }
    Menu.Slider(id, displayText, defaultValue, minValue, maxValue, step)
end

function Common.CreateDropdown(id, displayText, defaultValue, list)
    Common.MenuData[id] = {
        id = id,
        displayText = displayText,
        defaultValue = defaultValue,
        list = list,
    }
    Menu.Dropdown(id, displayText, defaultValue, list)
end

function Common.CreateColorPicker(id, displayText, defaultValue)
    Common.MenuData[id] = {
        id = id, 
        displayText = displayText, 
        defaultValue = defaultValue,
    }
    Menu.ColorPicker(id, displayText, defaultValue)
end

function Common.CreateResetButton(module)
    Menu.SmallButton("SAwareness." .. module .. ".Reset", "    Reset Module Settings    ", function()
        for menuID, item in pairs(Common.MenuData) do
            if string.starts_with(menuID, "SAwareness." .. module) then
                Menu.Set(menuID, item.defaultValue, true)
            end
        end
     end)
end

EventManager.RegisterCallback(Events.OnKey, function(e, message, wparam, lparam)
    if wparam == 16 then
        Common.ShiftPressed = message == 256
    end
end)

EventManager.RegisterCallback(Events.OnMouseEvent, function(e, message, wparam, lparam)
    Common.LMBPressed = e == 513
    if Common.LMBPressed then
        Common.LMBPosition = Renderer.GetCursorPos()
    end
    if e == 514 then
        Common.LastClickT = 0
        Common.LMBPosition = nil
    end
end)

function Common.DrawRectOutline(pos, thickness, color, rounding)
    local thickness = thickness or 1
    local color = color or 0xFFFFFFFF
    local rounding = rounding or 0
    return Renderer.DrawRectOutline(
        Vector(pos[1] or pos.x, pos[2] or pos.y),
        Vector(pos[3] or pos.z, pos[4] or pos.w),
        rounding,
        thickness,
        color
    )
end

function Common.DrawFilledRect(pos, color, rounding)
    local color = color or 0xFFFFFFFF
    local rounding = rounding or 0
    return Renderer.DrawFilledRect(
        Vector(pos[1] or pos.x, pos[2] or pos.y),
        Vector(pos[3] or pos.z, pos[4] or pos.w),
        rounding,
        color
    )
end

--#endregion

--[[
    ███████  ██████  ███    ██ ████████     ███████ ██   ██ ████████ ███████ ███    ██ ███████ ██  ██████  ███    ██ ███████ 
    ██      ██    ██ ████   ██    ██        ██       ██ ██     ██    ██      ████   ██ ██      ██ ██    ██ ████   ██ ██      
    █████   ██    ██ ██ ██  ██    ██        █████     ███      ██    █████   ██ ██  ██ ███████ ██ ██    ██ ██ ██  ██ ███████ 
    ██      ██    ██ ██  ██ ██    ██        ██       ██ ██     ██    ██      ██  ██ ██      ██ ██ ██    ██ ██  ██ ██      ██ 
    ██       ██████  ██   ████    ██        ███████ ██   ██    ██    ███████ ██   ████ ███████ ██  ██████  ██   ████ ███████                                                                                                                                                                                                                                            
]]

--#region Font Class

---@class SLib.Font
local Font = Class()

function Font:__init(fontName, size, color)
    self.FontName = fontName
    self.Size = size
    self.Color = color
    self.Font = Renderer.CreateFont(self.FontName, self.Size)
    self.TextSize = {}
    self.TextSizeUpdateT = 0.5
end

function Font:SetFont(fontName)
    if fontName and self.FontName ~= fontName then
        self.Font = Renderer.CreateFont(fontName, self.Size)
        self.FontName = fontName
    end
    return self
end

function Font:SetSize(size)
    if size and self.Size ~= size then
        self.Font = Renderer.CreateFont(self.FontName, size)
        self.Size = size
    end
    return self
end

function Font:SetColor(color)
    if color and self.Color ~= color then
        self.Color = color
    end
    return self
end

function Font:Draw(position, text, handle)
    if handle then
        local time = Game.GetTime()

        if not self.TextSize[handle] then
            self.TextSize[handle] = {
                self.Font:CalcTextSize(text),
                time
            }
        end

        if self.TextSize[handle] and self.TextSize[handle][2] + self.TextSizeUpdateT < time then
            self.TextSize[handle][1] = self.Font:CalcTextSize(text)
            self.TextSize[handle][2] = time
        end
    end
    self.Font:DrawText(position, text, self.Color)
    return self
end

--#endregion

--#region Font Data

Common.FontData = {
    FontFamily = {
        "Arial",
        "Arial Black",
        "Bahnschrift",
        "Calibri",
    },
    FontNames = {
        --// Arial //--
        {
            "Arial.ttf",
            "Ariali.ttf",
            "Arialbd.ttf",
            "Arialbi.ttf",
        },
        --// Arial Black //--
        {
            "Ariblk.ttf",
        },
        --// Bahnschrift //--
        {
            "Bahnschrift.ttf",
        },
        --// Calibri //--
        {
            "Calibril.ttf",
            "Calibrili.ttf",
            "Calibri.ttf",
            "Calibrii.ttf",
            "Calibrib.ttf",
            "Calibriz.ttf"
        },
    },
    FontDisplayNames = {
        --// Arial //--
        {
            "Arial",
            "Arial Italic",
            "Arial Bold",
            "Arial Bold Italic",
        },
        --// Arial Black //--
        {
            "Arial Black",
        },
        --// Bahnschrift //--
        {
            "Bahnschrift",
        },
        --// Calibri //--
        {
            "Calibri Light",
            "Calibri Light Italic",
            "Calibri",
            "Calibri Italic",
            "Calibri Bold",
            "Calibri Bold Italic"
        },
    }
}

--#endregion

--[[
    ███████ ██████  ██████  ██ ████████ ███████     ███████ ██   ██ ████████ ███████ ███    ██ ███████ ██  ██████  ███    ██ ███████ 
    ██      ██   ██ ██   ██ ██    ██    ██          ██       ██ ██     ██    ██      ████   ██ ██      ██ ██    ██ ████   ██ ██      
    ███████ ██████  ██████  ██    ██    █████       █████     ███      ██    █████   ██ ██  ██ ███████ ██ ██    ██ ██ ██  ██ ███████ 
         ██ ██      ██   ██ ██    ██    ██          ██       ██ ██     ██    ██      ██  ██ ██      ██ ██ ██    ██ ██  ██ ██      ██ 
    ███████ ██      ██   ██ ██    ██    ███████     ███████ ██   ██    ██    ███████ ██   ████ ███████ ██  ██████  ██   ████ ███████                                                                                                                                                                                                                                                             
]]

--#region Sprite Class

local Sprite = Class()

function Sprite:__init(path, x, y, color)
    self.Sprite = Renderer.CreateSprite(path, x, y)
    self.X = x
    self.Y = y
    self.ScaleX = x
    self.ScaleY = y
    self.Color = color
    return self
end

function Sprite:SetScale(x, y)
    if self.ScaleX ~= x or self.ScaleY ~= y then
        self.Sprite:SetSize(x, y)
        self.ScaleX = x
        self.ScaleY = y
    end
    return self
end

function Sprite:SetColor(color)
    if self.Sprite and self.Color ~= color then
        self.Sprite:SetColor(color)
        self.Color = color
    end
    return self
end

function Sprite:Draw(vec, rad, centered)
    if self.Sprite then
        self.Sprite:Draw(vec, rad, centered)
    end
    return self
end

--#endregion

--#region Item Manager

---@class SLib.ItemManager
local ItemManager = Class()

function ItemManager:__init()
    self.Items = {}
end

function ItemManager:Update(obj)
    local hero = obj.AsHero
    if not hero then return end

    local res = {}
    for slot, item in pairs(hero.Items) do
        local id = item.ItemId
        res[id] = item
    end
    self.Items[hero.Handle] = res
end

function ItemManager:GetItems(obj)
    local hero = obj.AsHero
    if hero and not self.Items[obj.Handle] then
        self:Update(obj)
    end
    return self.Items[obj.Handle] or {}
end

function ItemManager:HasItem(obj, itemId)
    return self:GetItems(obj)[itemId] ~= nil
end

local ItemManager = ItemManager()

--#endregion

--[[
    ███████ ██████  ███████ ██      ██          ███    ███  █████  ███    ██  █████   ██████  ███████ ██████  
    ██      ██   ██ ██      ██      ██          ████  ████ ██   ██ ████   ██ ██   ██ ██       ██      ██   ██ 
    ███████ ██████  █████   ██      ██          ██ ████ ██ ███████ ██ ██  ██ ███████ ██   ███ █████   ██████  
         ██ ██      ██      ██      ██          ██  ██  ██ ██   ██ ██  ██ ██ ██   ██ ██    ██ ██      ██   ██ 
    ███████ ██      ███████ ███████ ███████     ██      ██ ██   ██ ██   ████ ██   ██  ██████  ███████ ██   ██                                                                                                        
]]

--#region Spell Manager Class

local SpellManager = Class()

function SpellManager:__init()
    self.SpellData = {}

    for handle, object in pairs(ObjectManager.Get("all", "heroes")) do
        local hero = object.AsHero
        if hero.CharName == "PracticeTool_TargetDummy" then
            goto skip
        end
        for slot = 0, 5 do
            self:Update(slot, hero)
        end
        ::skip::
    end

    EventManager.RegisterCallback(Events.OnSpellCast, function(...) return self:OnSpellCast(...) end)
    EventManager.RegisterCallback(Events.OnVisionGain, function(...) return self:OnVisionGain(...) end)
end

function SpellManager:Get(unit, slot)
    return self.SpellData[unit.Handle][slot]
end

function SpellManager:Update(slot, unit)
    if not self.SpellData[unit.Handle] then
        self.SpellData[unit.Handle] = {}
    end

    local spell = unit:GetSpell(slot, unit)
    if not spell then return end

    self.SpellData[unit.Handle][slot] = {
        Name = spell.Name,
        Level = spell.Level,
        CooldownExpireTime = Game.GetTime() + spell.RemainingCooldown,
        TotalAmmoRechargeTime = spell.TotalAmmoRechargeTime,
        TotalCooldown = spell.TotalCooldown,
    }
end

function SpellManager:OnSpellCast(unit, spell)
    if not unit.IsHero then
        return
    end

    if not spell.SpellData then
        return
    end

    local slot = spell.Slot
    if slot >= 0 and slot < 6 then
        delay(50, function() self:Update(slot, unit) end)
    end
end

function SpellManager:OnVisionGain(unit)
    for slot = 0, 5 do
        self:Update(slot, unit)
    end
end

local SpellManager = SpellManager()

--#endregion

--[[
     ██████ ██   ██  █████  ███    ███ ██████  ██  ██████  ███    ██     ███    ███  █████  ███    ██  █████   ██████  ███████ ██████  
    ██      ██   ██ ██   ██ ████  ████ ██   ██ ██ ██    ██ ████   ██     ████  ████ ██   ██ ████   ██ ██   ██ ██       ██      ██   ██ 
    ██      ███████ ███████ ██ ████ ██ ██████  ██ ██    ██ ██ ██  ██     ██ ████ ██ ███████ ██ ██  ██ ███████ ██   ███ █████   ██████  
    ██      ██   ██ ██   ██ ██  ██  ██ ██      ██ ██    ██ ██  ██ ██     ██  ██  ██ ██   ██ ██  ██ ██ ██   ██ ██    ██ ██      ██   ██ 
     ██████ ██   ██ ██   ██ ██      ██ ██      ██  ██████  ██   ████     ██      ██ ██   ██ ██   ████ ██   ██  ██████  ███████ ██   ██                                                                                                                                                                                                                                                                  
]]

--#region Champion Manager Class

---@class SLib.HeroManager
local HeroManager = Class()

function HeroManager:__init()
    self.Heroes = {}
    self.SpellDataUpdateT = 0
    self.ItemDataUpdateT = 0

    for handle, object in pairs(ObjectManager.Get("all", "heroes")) do
        local hero = object.AsHero
        if hero.CharName == "PracticeTool_TargetDummy" then
            goto skip
        end
        self.Heroes[handle] = {
            --// Static Values //--
            ["Handle"] = handle,
            ["Object"] = hero,
            ["CharName"] = hero.CharName,
            ["IsAlly"] = hero.IsAlly,
            ["IsEnemy"] = hero.IsEnemy,
            ["IsMe"] = hero.IsMe,
    
            --// Dynamic Values //--
            ["Position"] = {
                Value = Vector(0, 0, 0),
                UpdateInterval = 0.25,
                LastUpdate = 0,
            },
            ["IsDead"] = {
                Value = false,
                UpdateInterval = 1,
                LastUpdate = 0,
            },
            ["IsVisible"] = {
                Value = false,
                UpdateInterval = 1,
                LastUpdate = 0,
            },
            ["IsOnScreen"] = {
                Value = false,
                UpdateInterval = 0,
                LastUpdate = 0,
            },
            ["IsTargetable"] = {
                Value = false,
                UpdateInterval = 0.25,
                LastUpdate = 0,
            },
            ["Health"] = {
                Value = 0,
                UpdateInterval = 0.15,
                LastUpdate = 0,
            },
            ["HealthPercent"] = {
                Value = 0,
                UpdateInterval = 0.15,
                LastUpdate = 0,
            },
            ["Mana"] = {
                Value = 0,
                UpdateInterval = 0.15,
                LastUpdate = 0,
            },
            ["ManaPercent"] = {
                Value = 0,
                UpdateInterval = 0.15,
                LastUpdate = 0,
            },
            ["MaxHealth"] = {
                Value = 0,
                UpdateInterval = 0.5,
                LastUpdate = 0,
            },
            ["MaxMana"] = {
                Value = 0,
                UpdateInterval = 0.5,
                LastUpdate = 0,
            },
            ["MoveSpeed"] = {
                Value = 0,
                UpdateInterval = 0.25,
                LastUpdate = 0,
            },
            ["IsZombie"] = {
                Value = false,
                UpdateInterval = 0.5,
                LastUpdate = 0,
            },
            ["TimeUntilRespawn"] = {
                Value = 0,
                UpdateInterval = 1,
                LastUpdate = 0,
            },
            ["Level"] = {
                Value = 0,
                UpdateInterval = 1,
                LastUpdate = 0,
            },
            ["IsMoving"] = {
                Value = 0,
                UpdateInterval = 0.5,
                LastUpdate = 0,
            },
            ["BoundingRadius"] = {
                Value = 0,
                UpdateInterval = 5,
                LastUpdate = 0,
            },
            ["Experience"] = {
                Value = 0,
                UpdateInterval = 1,
                LastUpdate = 0,
            },
            ["ExpPercent"] = 0,
            ["TimeSinceLastDeath"] = 0,
            ["__IsDead"] = true,
        }
        ::skip::
    end

    EventManager.RegisterCallback(Events.OnTick, function() return self:OnTick() end)
    EventManager.RegisterCallback(Events.OnVisionGain, function(...) return self:OnVisionGain(...) end)
    EventManager.RegisterCallback(Events.OnVisionLost, function(...) return self:OnVisionLost(...) end)

    return self
end

local function UpdateProperty(property, data, hero, tick)
    local d = data[property]
    if d.LastUpdate + d.UpdateInterval < tick then
        d.Value = hero[property]
        d.LastUpdate = tick
    end
end
function HeroManager:OnTick()
    local heroLvlSum, heroCount = 0, 0
    local tick = Game.GetTime()

    for handle, hero in pairs(ObjectManager.Get("all", "heroes")) do
        if hero.CharName == "PracticeTool_TargetDummy" then
            goto skip
        end
        if self.Heroes[handle] then
            heroCount = heroCount + 1
            local data = self.Heroes[handle]
            UpdateProperty("Position", data, hero, tick)
            UpdateProperty("IsDead", data, hero, tick)
            UpdateProperty("IsVisible", data, hero, tick)
            UpdateProperty("IsOnScreen", data, hero, tick)
            UpdateProperty("IsTargetable", data, hero, tick)
            UpdateProperty("Health", data, hero, tick)
            UpdateProperty("HealthPercent", data, hero, tick)
            UpdateProperty("Mana", data, hero, tick)
            UpdateProperty("ManaPercent", data, hero, tick)
            UpdateProperty("MaxHealth", data, hero, tick)
            UpdateProperty("MaxMana", data, hero, tick)
            UpdateProperty("MoveSpeed", data, hero, tick)
            UpdateProperty("IsZombie", data, hero, tick)
            UpdateProperty("TimeUntilRespawn", data, hero, tick)
            UpdateProperty("Level", data, hero, tick)
            UpdateProperty("IsMoving", data, hero, tick)
            UpdateProperty("BoundingRadius", data, hero, tick)
            UpdateProperty("Experience", data, hero, tick)
            
            local isDead = data["IsDead"].Value
            if isDead and data["__IsDead"] then
                delay(50, function()
                    data["TimeSinceLastDeath"] = tick + data["TimeUntilRespawn"].Value
                end)
                data["__IsDead"] = false
            end

            if not isDead and not data["__IsDead"] then
                data["__IsDead"] = true
            end

            heroLvlSum = heroLvlSum + data.Level.Value
            
            if not isDead then
                local isVisible = data["IsVisible"].Value
                local isOnScreen = data["IsOnScreen"].Value
                if isVisible and isOnScreen then
                    self:UpdateProperty(data.Handle, "Position", 0)
                    self:UpdateProperty(data.Handle, "Health", 0)
                    self:UpdateProperty(data.Handle, "HealthPercent", 0)
                    self:UpdateProperty(data.Handle, "MoveSpeed", 0)
                    self:UpdateProperty(data.Handle, "IsMoving", 0)
                    self:UpdateProperty(data.Handle, "Experience", 0)
                    self:UpdateProperty(data.Handle, "Level", 0)
                    
                    if SpellManager then
                        if self.SpellDataUpdateT + 1 < tick then
                            for slot = 0, 5 do
                                SpellManager:Update(slot, hero)
                            end
                            self.SpellDataUpdateT = tick
                        end
                    end

                    if ItemManager then
                        if self.ItemDataUpdateT + 5 < tick then
                            ItemManager:Update(hero)
                            self.ItemDataUpdateT = tick
                        end
                    end

                    do --// Hero Exp //--
                        local level = data.Level.Value
                        local actualExp = data.Experience.Value
                        local neededExp = 180 + 100 * level
                        if level then
                            actualExp = actualExp - (280 + 80 + 100 * level) / 2 * (level - 1)
                        end
                        local expPercent = (actualExp / neededExp * 100) / 100
                        if level == 18 then
                            expPercent = 1
                        end
                        if data.ExpPercent ~= expPercent then
                            data.ExpPercent = expPercent
                        end
                    end
                end
            end
        end
        ::skip::
    end

    local averageChampLevel = heroLvlSum / heroCount
    Common.YellowTrinketDuration = 88.235 + 1.765 * averageChampLevel
end

function HeroManager:OnVisionGain(unit)
    if ItemManager then
        ItemManager:Update(unit)
    end

    if not unit.IsEnemy then
        return
    end

    self:UpdateProperty(unit.Handle, "IsVisible", 0)
    self:UpdateProperty(unit.Handle, "IsOnScreen", 0)
end

function HeroManager:OnVisionLost(unit)
    self:UpdateProperty(unit.Handle, "IsVisible", 0)
    self:UpdateProperty(unit.Handle, "IsOnScreen", 0)
end

function HeroManager:Get()
    return self.Heroes
end

function HeroManager:UpdateProperty(handle, property, value)
    if self.Heroes[handle] and self.Heroes[handle][property] then
        self.Heroes[handle][property].LastUpdate = value
    end
end

local HeroManager = HeroManager()

--#endregion

_G.Libs.SLib = {
    Common = Common,
    CreateFont = Font,
    CreateSprite = Sprite,
    HeroManager = HeroManager,
    SpellManager = SpellManager,
    ItemManager = ItemManager,
    Heroes = HeroManager:Get()
}