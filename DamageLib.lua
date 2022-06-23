--[[
    Last Update By Shulepin @ 02.03.2022

    [_G.Libs.DamageLib]
        .CalculatePhysicalDamage(source, target, rawDmg)
        .CalculateMagicalDamage(source, target, rawDmg)
        .GetAutoAttackDamage(source, target, checkPassives, staticDamage, dmgMultiplier)
        .GetStaticAutoAttackDamage(source, isMinionTarget)
        .GetSpellDamage(source, target, slot, stage)
        .GetBuffDamage(source, target, buff, stage)
]]

local filepath = _G.GetCurrentFilePath()
local localVersionPath = "lol\\Modules\\Common\\DamageLibTest"
if not filepath:find(localVersionPath) and io.exists(localVersionPath .. ".lua") then
    require(localVersionPath)
    return
end

module("dmgLib", package.seeall, log.setup)
clean.module("dmgLib", clean.seeall, log.setup)

if not rawget(_G, "Libs") then _G.Libs = {} end
if rawget(_G.Libs, "DamageLib") then return _G.Libs.DamageLib end

local min, max, floor, ceil = math.min, math.max, math.floor, math.ceil
local insert = table.insert

---@type ItemIDs
local ItemID = require("lol\\Modules\\Common\\ItemID")

local _SDK = _G.CoreEx
local ObjectManager, EventManager, Renderer, Game, Input = _SDK.ObjectManager, _SDK.EventManager, _SDK.Renderer, _SDK.Game, _SDK.Input
local Events, ItemSlots, SpellSlots, BuffTypes, DamageTypes = _SDK.Enums.Events, _SDK.Enums.ItemSlots, _SDK.Enums.SpellSlots, _SDK.Enums.BuffTypes, _SDK.Enums.DamageTypes
local _Q, _W, _E, _R = SpellSlots.Q, SpellSlots.W, SpellSlots.E, SpellSlots.R

----------------------------------------------------------------------------------------------

local DamageLib = {}

local turretStacks = {}
local ItemsCache = {}
local LastItemUpdateT = 0

local spellDamages = {}
local spellData = {}
local staticItemDamages = {}
local dynamicItemDamages = {}
local staticPassiveDamages = {}
local dynamicPassiveDamages = {}

local JaxBuffData = {}
local MissFortuneAttackData = {}
local SettAttackData = {}
local GuinsooCount = 0

local SheenTracker = {}
local SheenBuffs = {
    ["sheen"] = true,
    ["3078trinityforce"] = true,
    ["6632buff"] = true,
    ["3508buff"] = true,
    ["lichbane"] = true
}

local IsInGame = {}

local Heroes = {}
local HeroCount = 0

for handle, hero in pairs(ObjectManager.Get("all", "heroes")) do
    HeroCount = HeroCount + 1
    Heroes[HeroCount] = hero
    IsInGame[hero.AsAI.CharName] = true
    SheenTracker[hero.Handle] = 0
end

----------------------------------------------------------------------------------------------

---@type fun(obj: GameObject):void
local function UpdateItemList(obj)
    local hero = obj.AsHero
    if not hero then return end

    local res = {}
    for slot, item in pairs(hero.Items) do
        local id = item.ItemId
        res[id] = item
    end
    ItemsCache[hero.Handle] = res
end

---@type fun(obj: GameObject):table
local function GetItems(obj)
    local hero = obj.AsHero
    if hero and not ItemsCache[obj.Handle] then
        UpdateItemList(obj)
    end
    return ItemsCache[obj.Handle] or {}
end

---@type fun(dmgTable: table, lvl: number):number
local function GetDamageByLvl(dmgTable, lvl)
    if lvl < 1 then return 0 end
    return dmgTable[min(#dmgTable, lvl)]
end

---@type fun(obj: GameObject, itemId: number):table
local function HasItem(obj, itemId)
    return GetItems(obj)[itemId] ~= nil
end

local function InfinityEdgeMod(obj, mod)
    return HasItem(obj, ItemID.InfinityEdge) and obj.CritChance >= 0.6 and mod or 0
end

---@type fun(obj: GameObject, spellcast: SpellCast):void
local function UpdateTurretBuff(obj, spellcast)
    local turret = obj.AsTurret
    if not turret then return end

    local gameTime = Game.GetTime()
    local data = turretStacks[obj.Handle]

    if not data or gameTime >= data.EndTime then
        turretStacks[obj.Handle] = {Stacks = 0, EndTime = gameTime + 3}
    else
        data.Stacks  = data.Stacks + 1
        data.EndTime = gameTime + 3
    end
end

---@type fun(obj: GameObject):number
local function GetTurretWarmingUpDamageMod(obj)
    local data = turretStacks[obj.Handle]
    if data and Game.GetTime() < data.EndTime then
        return 1 + (min(3, data.Stacks) * 0.4)
    end
    return 1
end

---@type fun(source: GameObject, isMinionTarget: boolean, spellProperties: table):table
local function GetStaticItemDamage(source,  isMinionTarget, spellProperties)
    local spellProperties = spellProperties or {}
    local res = {
        FlatPhysical    = 0.0,
        FlatMagical     = 0.0,
        FlatTrue        = 0.0,
        PercentPhysical = 1.0,
        PercentMagical  = 1.0,
        PercentTrue     = 1.0,
    }
    for itemId, _ in pairs(GetItems(source)) do
        local f = staticItemDamages[itemId]
        if f then
            f(res, source, isMinionTarget, spellProperties)
        end
    end
    return res
end

---@type fun(source: GameObject, target: GameObject, spellProperties: table):table
local function GetDynamicItemDamage(source, target, spellProperties)
    local spellProperties = spellProperties or {}
    local res = {
        FlatPhysical    = 0.0,
        FlatMagical     = 0.0,
        FlatTrue        = 0.0,
        PercentPhysical = 1.0,
        PercentMagical  = 1.0,
        PercentTrue     = 1.0,
    }
    for itemId, _ in pairs(GetItems(source)) do
        local f = dynamicItemDamages[itemId]
        if f then
            f(res, source, target, spellProperties)
        end
    end
    return res
end

---@type fun(source: GameObject, target: GameObject):table
local function ComputeItemDamage(source, target, spellProperties)
    local spellProperties = spellProperties or {}
    local res = GetStaticItemDamage(source, target.IsMinion, spellProperties)
    local tmp = GetDynamicItemDamage(source, target, spellProperties)

    res.FlatPhysical    = res.FlatPhysical + tmp.FlatPhysical
    res.FlatMagical     = res.FlatMagical  + tmp.FlatMagical
    res.FlatTrue        = res.FlatTrue     + tmp.FlatTrue
    res.PercentPhysical = res.PercentPhysical * tmp.PercentPhysical
    res.PercentMagical  = res.PercentMagical  * tmp.PercentMagical
    res.PercentTrue     = res.PercentTrue     * tmp.PercentTrue

    return res
end

---@type fun(source: GameObject, isMinionTarget: boolean):table
local function GetStaticPassiveDamage(source,  isMinionTarget)
    local res = {
        FlatPhysical    = 0.0,
        FlatMagical     = 0.0,
        FlatTrue        = 0.0,
        PercentPhysical = 1.0,
        PercentMagical  = 1.0,
        PercentTrue     = 1.0,
    }

    local charName = source.CharName
    for _, pData in ipairs(staticPassiveDamages) do
        if not pData.Name or pData.Name == charName then
            pData.Func(res, source, isMinionTarget)
        end
    end
    return res
end

---@type fun(source: GameObject, target: GameObject):table
local function GetDynamicPassiveDamage(source, target)
    local res = {
        FlatPhysical    = 0.0,
        FlatMagical     = 0.0,
        FlatTrue        = 0.0,
        PercentPhysical = 1.0,
        PercentMagical  = 1.0,
        PercentTrue     = 1.0,
    }
    local charName = source.CharName

    for _, pData in ipairs(dynamicPassiveDamages) do
        if not pData.Name or pData.Name == charName then
            pData.Func(res, source, target)
        end
    end
    return res
end

---@type fun(source: GameObject, target: GameObject):table
local function ComputePassiveDamage(source, target)
    local res = GetStaticPassiveDamage(source, target.IsMinion)
    local tmp = GetDynamicPassiveDamage(source, target)

    if tmp.CriticalHit      then res.CriticalHit = true end
    if tmp.ConvertTrue      then res.ConvertTrue = true end
    if tmp.ConvertPhysical  then res.ConvertPhysical = true end
    if tmp.ConvertMagical   then res.ConvertMagical = true end

    res.FlatPhysical    = res.FlatPhysical + tmp.FlatPhysical
    res.FlatMagical     = res.FlatMagical  + tmp.FlatMagical
    res.FlatTrue        = res.FlatTrue     + tmp.FlatTrue
    res.PercentPhysical = res.PercentPhysical * tmp.PercentPhysical
    res.PercentMagical  = res.PercentMagical  * tmp.PercentMagical
    res.PercentTrue     = res.PercentTrue     * tmp.PercentTrue

    return res
end

---@type fun(_source: GameObject, _target: GameObject, dmgType: number):number
local function GetPassivePercentMod(_source, _target, dmgType)
    local source, target = _source and _source.AsAI, _target and _target.AsAttackableUnit
    if not (source and target) then return 0 end

    local aiTarget = target.AsAI
    if not aiTarget then
        if target.IsInhibitor then
            return 100/(100 + 20) --Inhibitor Armor = 20
        end
        return 1
    end

    local dmgMod = 1
    local BaseResistance     = 0
    local BonusResistance    = 0
    local ReductionFlat      = 0
    local ReductionPercent   = 0
    local PenetrationFlat    = 0
    local PenetrationPercent = 0
    local BonusPenPercent    = 0

    if dmgType == DamageTypes.Physical then
        BonusResistance = aiTarget.BonusArmor
        BaseResistance = aiTarget.Armor - BonusResistance

        if source.IsTurret then
            PenetrationPercent = 0.3
            BonusPenPercent = 0
        elseif not source.IsMinion then
            PenetrationFlat     = source.FlatArmorPen
            PenetrationPercent  = 1.0 - source.PercentArmorPen
            BonusPenPercent     = 1.0 - source.PercentBonusArmorPen

            local heroSource = source.AsHero
            if heroSource then
                PenetrationFlat = PenetrationFlat + source.PhysicalLethality * (0.6 + 0.4 * (heroSource.Level / 18))
            end
        end
    elseif dmgType == DamageTypes.Magical then
        BonusResistance = aiTarget.BonusSpellBlock
        BaseResistance  = aiTarget.SpellBlock - BonusResistance

        ReductionFlat       = source.FlatMagicReduction
        ReductionPercent    = source.PercentMagicReduction
        PenetrationFlat     = source.FlatMagicPen
        PenetrationPercent  = 1.0 - source.PercentMagicPen
        BonusPenPercent     = 1.0 - source.PercentBonusMagicPen

        local heroSource = source.AsHero
        if heroSource then
            PenetrationFlat = PenetrationFlat + source.MagicalLethality * (0.6 + 0.4 * (heroSource.Level / 18))
        end
    else
        return 1
    end

    local TotalResistance = BaseResistance + BonusResistance
    local BasePercent  = (TotalResistance > 0 and BaseResistance / TotalResistance) or 0.5
    local BonusPercent = 1.0 - BasePercent

    BaseResistance  = BaseResistance  - ReductionFlat * BasePercent
    BonusResistance = BonusResistance - ReductionFlat * BonusPercent
    TotalResistance = BaseResistance + BonusResistance

    if TotalResistance >= 0 then
        BaseResistance  = BaseResistance  * (1.0 - ReductionPercent)
        BonusResistance = BonusResistance * (1.0 - ReductionPercent)
        TotalResistance = BaseResistance + BonusResistance
    end

    if TotalResistance >= 0 then
        BaseResistance  = BaseResistance  * (1.0 - PenetrationPercent)
        BonusResistance = BonusResistance * (1.0 - (PenetrationPercent + BonusPenPercent))
        TotalResistance = BaseResistance + BonusResistance
    end

    if TotalResistance >= 0 then
        TotalResistance = max(0, TotalResistance - PenetrationFlat)
    end

    if TotalResistance < 0 then
        dmgMod = 2.0 - (100.0 / (100.0 - TotalResistance))
    else
        dmgMod = (100.0 / (100.0 + TotalResistance))
    end

    if aiTarget.IsMinion and aiTarget:GetBuff("exaltedwithbaronnashorminion") then
        local minionTarget = aiTarget.AsMinion
        if not (minionTarget.IsSiegeMinion or minionTarget.IsSuperMinion) then
            if source.IsHero then
                local time = Game.GetTime()/60
                local mod = (time > 40 and 0.7) or (time > 30 and 0.58) or 0.5
                dmgMod = dmgMod * (1-mod)
            elseif source.IsMinion and aiTarget.IsMelee then
                dmgMod = dmgMod * 0.25
            end
        end
    elseif aiTarget.IsHero then
        local pta = aiTarget:GetBuff("ASSETS/Perks/Styles/Precision/PressTheAttack/PressTheAttackDamageAmp.lua")
        local caster = pta and pta.Source
        local heroCaster = caster and caster.AsHero
        if heroCaster then
            dmgMod = dmgMod * (1.0 + (0.0765 + 0.00235 * heroCaster.Level))
        end

        local heroSource = source and source.AsHero
        if heroSource and heroSource:HasPerk("CoupDeGrace") and aiTarget.HealthPercent < 0.4 then
            dmgMod = dmgMod * 1.08
        end
    elseif source.IsHero and aiTarget.IsMinion then
        if source:GetBuff("barontarget") and aiTarget.IsBaron then
            dmgMod = dmgMod * 0.5
        end
        local dragonBuff = source:GetBuff("dragonbuff_tooltipmanager")
        if dragonBuff and aiTarget:GetBuff("s5_dragonvengeance") and aiTarget.IsDragon then
            dmgMod = dmgMod * (1.0 - 0.07 * dragonBuff.Count)
        end
    end

    return dmgMod
end

function DamageLib.AdaptativeDamageIsPhysical(source) return source.BonusAD >= source.TotalAP end
function DamageLib.AdaptativeDamageIsMagical(source) return not DamageLib.AdaptativeDamageIsPhysical(source) end

function DamageLib.GetDarkHarvestDamage(source, target)
    local heroSource = source.AsHero
    if heroSource and target.IsHero and target.HealthPercent < 0.5 then
        local darkHarvest = source:GetBuff("ASSETS/Perks/Styles/Domination/DarkHarvest/DarkHarvest.lua")
        if darkHarvest and not source:GetBuff("ASSETS/Perks/Styles/Domination/DarkHarvest/DarkHarvestCooldown.lua") then
            local baseDmg = 20+40/17*(heroSource.Level-1)
            local bonusDmg = 5*darkHarvest.Count + 0.25 * source.BonusAD + 0.15 * source.TotalAP
            return baseDmg + bonusDmg
        end
    end
    return 0
end

---@type fun(_source: GameObject, _target: GameObject, rawDmg: number):number
function DamageLib.CalculatePhysicalDamage(_source, _target, rawDmg)
    local source, target = _source and _source.AsAI, _target and _target.AsAttackableUnit
    if not (source and target) or rawDmg < 0 then return 0 end

    if DamageLib.AdaptativeDamageIsPhysical(source) then
        rawDmg = rawDmg + DamageLib.GetDarkHarvestDamage(source, target)
    end

    return max(GetPassivePercentMod(source, target, DamageTypes.Physical) * rawDmg, 0)
end

---@type fun(_source: GameObject, _target: GameObject, rawDmg: number):number
function DamageLib.CalculateMagicalDamage(_source, _target, rawDmg)
    local source, target = _source and _source.AsAI, _target and _target.AsAttackableUnit
    if not (source and target) or rawDmg < 0 then return 0 end

    if DamageLib.AdaptativeDamageIsMagical(source) then
        rawDmg = rawDmg + DamageLib.GetDarkHarvestDamage(source, target)
    end

    local dmg = max(GetPassivePercentMod(source, target, DamageTypes.Magical) * rawDmg, 0)

    local aiTarget = target.AsAI
    if aiTarget then
        if aiTarget:GetBuff("cursedtouch")        then dmg = dmg * 1.10 end
        if aiTarget:GetBuff("abyssalscepteraura") then dmg = dmg * 1.15 end
    end
    return dmg
end

---@type fun(_source: GameObject, isMinionTarget: boolean):table
function DamageLib.GetStaticAutoAttackDamage(_source, isMinionTarget)
    local source = _source and _source.AsHero
    if not source then return 0 end

    local res = {
        RawPhysical = 0,
        RawMagical = 0,
        RawTrue = 0,
    }
    local _k = nil
    local pDmg = GetStaticPassiveDamage(source, isMinionTarget)
    if pDmg.ConvertPhysical then
        _k = "Physical"
    elseif pDmg.ConvertPhysical then
        _k = "Magical"
    elseif pDmg.ConvertTrue then
        _k = "True"
    end

    if _k then
        res["Convert" .. _k] = true
        _k = "Raw" .. _k
        res[_k] = res[_k] + (pDmg.FlatPhysical + source.TotalAD) * pDmg.PercentPhysical
        res[_k] = res[_k] + pDmg.FlatMagical * pDmg.PercentMagical
        res[_k] = res[_k] + pDmg.FlatTrue * pDmg.PercentTrue
    else
        res.RawPhysical = (pDmg.FlatPhysical + source.TotalAD) * pDmg.PercentPhysical
        res.RawMagical  = pDmg.FlatMagical * pDmg.PercentMagical
        res.RawTrue     = pDmg.FlatTrue * pDmg.PercentTrue
    end

    local iDmg = GetStaticItemDamage(source, isMinionTarget)
    res.RawPhysical = res.RawPhysical + (iDmg.FlatPhysical * iDmg.PercentPhysical)
    res.RawMagical  = res.RawMagical  + (iDmg.FlatMagical  * iDmg.PercentMagical)
    res.RawTrue     = res.RawTrue     + (iDmg.FlatTrue     * iDmg.PercentTrue)

    res.RawTotal = res.RawPhysical + res.RawMagical + res.RawTrue
    return res
end

---@type fun(_source: GameObject, _target: GameObject, checkPassives: boolean, staticDamage: table, dmgMultiplier: number):number
function DamageLib.GetAutoAttackDamage(_source, _target, checkPassives, staticDamage, dmgMultiplier)
    local source, target = _source and _source.AsAI, _target and _target.AsAttackableUnit
    if not (source and target) then return 0 end
    if target.MaxHealth < 10 then return 1 end

    local dmg = {
        Physical = (staticDamage and staticDamage.RawPhysical) or source.TotalAD,
        Magical  = (staticDamage and staticDamage.RawMagical)  or 0,
        True     = (staticDamage and staticDamage.RawTrue)     or 0
    }
    local dmgMultiplier = dmgMultiplier or 1.0

    local minionTarget = target.AsMinion
    local turretSource = source.AsTurret
    if turretSource and minionTarget then
        if minionTarget.IsMelee then
            return minionTarget.MaxHealth * 0.45
        else
            if minionTarget.IsSiegeMinion then
                local tier = turretSource.Tier
                if tier == "T1" then
                    return target.MaxHealth * 0.14
                elseif tier == "T2" then
                    return target.MaxHealth * 0.11
                else
                    return target.MaxHealth * 0.08
                end
            elseif minionTarget.IsSuperMinion then
                return target.MaxHealth * 0.07
            else
                return target.MaxHealth * 0.7
            end
        end
    end

    local heroSource = source.AsHero
    if heroSource then
        if heroSource.CharName == "Belveth" then
            dmg.Magical = dmg.Physical * 0.75
            dmg.Physical = dmg.Physical * 0.75
        end
        if heroSource.CharName == "Zeri" then
            local aaDmg = 0
            local charge = heroSource.SecondResource
            if charge < 100 then
                aaDmg = 10 + (15 / 17) * (heroSource.Level - 1) * (0.7025 + 0.0002 * (heroSource.Level - 1)) + 0.03 * heroSource.TotalAP
                if target.HealthPercent < 0.35 then
                    aaDmg = aaDmg * 6
                end
            else
                local dmgPerPct = 3 + (17 / 17) * (heroSource.Level - 1) * (0.7025 + 0.0002 * (heroSource.Level - 1))
                aaDmg = 90 + (110 / 17) * (heroSource.Level - 1) * (0.7025 + 0.0175 * (heroSource.Level - 1)) + 0.9 * heroSource.TotalAP + (dmgPerPct / 100 * target.MaxHealth)
            end
            dmg.Magical = aaDmg
            dmg.Physical = 0
        end
        if heroSource.CharName == "Corki" then
            dmg.Magical = dmg.Physical * 0.8
            dmg.Physical = dmg.Physical * 0.2
        end
        if heroSource.CharName == "DrMundo" and heroSource:GetBuff("DrMundoE") then
            if target.IsMonster then
                dmg.Physical = dmg.Physical * 2
            elseif target.IsLaneMinion then
                dmg.Physical = dmg.Physical * 1.4
            end
        end
        if checkPassives then
            local passiveDamage = staticDamage and GetDynamicPassiveDamage(heroSource, target) or ComputePassiveDamage(heroSource, target)

            if passiveDamage.CriticalHit then
                dmg.Physical = dmg.Physical * heroSource.CritDamageMultiplier
            end
            
            local _k = nil
            if (staticDamage or passiveDamage).ConvertPhysical then
                _k = "Physical"
            elseif (staticDamage or passiveDamage).ConvertMagical then
                _k = "Magical"
            elseif (staticDamage or passiveDamage).ConvertTrue then
                _k = "True"
            end

            if _k then
                dmg[_k] = dmg[_k] + passiveDamage.FlatPhysical
                dmg[_k] = dmg[_k] + passiveDamage.FlatMagical
                dmg[_k] = dmg[_k] + passiveDamage.FlatTrue
                dmg[_k] = dmg[_k] * passiveDamage.PercentPhysical
                dmg[_k] = dmg[_k] * passiveDamage.PercentMagical
                dmg[_k] = dmg[_k] * passiveDamage.PercentTrue
            else
                dmg.Physical = dmg.Physical + passiveDamage.FlatPhysical
                dmg.Magical  = dmg.Magical  + passiveDamage.FlatMagical
                dmg.True     = dmg.True     + passiveDamage.FlatTrue
                dmg.Physical = dmg.Physical * passiveDamage.PercentPhysical
                dmg.Magical  = dmg.Magical  * passiveDamage.PercentMagical
                dmg.True     = dmg.True     * passiveDamage.PercentTrue
            end
        end

        if heroSource.CharName ~= "Zeri" then
            local itemDamage = staticDamage and GetDynamicItemDamage(heroSource, target) or ComputeItemDamage(heroSource, target)
            local mod = ((itemDamage.ApplyOnHit or itemDamage.ApplyOnHit) and 2) or 1
            dmg.Physical = dmg.Physical + itemDamage.FlatPhysical * mod
            dmg.Magical  = dmg.Magical  + itemDamage.FlatMagical * mod
            dmg.True     = dmg.True     + itemDamage.FlatTrue * mod
        end
    end

    local heroTarget = target.AsHero
    if heroTarget then
        if turretSource then
            dmgMultiplier = dmgMultiplier * GetTurretWarmingUpDamageMod(turretSource)
        else
            if HasItem(heroTarget, ItemID.NinjaTabi) then
                dmgMultiplier = dmgMultiplier * 0.9
            end
        end
    end
    
    local minionSource = source.AsMinion
    if minionSource then
        if heroTarget then
            dmgMultiplier = dmgMultiplier * 0.5
        elseif target.IsTurret then
            dmgMultiplier = dmgMultiplier * ((minionSource.IsSiegeMinion and 0.75) or 0.5)
        elseif minionTarget then
            dmg.Physical = dmg.Physical - minionTarget.ReducedDamageFromMinions
            dmgMultiplier = dmgMultiplier * (1 + minionSource.BonusDamageToMinions)
        end
    end

    dmg.Physical = DamageLib.CalculatePhysicalDamage(source, target, dmg.Physical) * dmgMultiplier
    dmg.Magical  = DamageLib.CalculateMagicalDamage(source, target, dmg.Magical)

    local result = dmg.Physical + dmg.Magical + dmg.True
    return max(result, 0)
end

function DamageLib.GetSpellDamage(source, target, slot_or_spell, stage)
    local source, target = source and source.AsHero, target and target.AsAI
    if not source and target then return 0 end

    local dmg = {
        Physical = 0,
        Magical  = 0,
        True     = 0
    }

    local result = 0
    local stage = stage or "Default"
    local data = nil
    if type(slot_or_spell) == "number" then
        data = spellDamages[source.CharName]
    elseif type(slot_or_spell) == "string" then
        data = spellData[source.CharName]
    end

    if data and data[slot_or_spell] and data[slot_or_spell][stage] then
        local damageOut = data[slot_or_spell][stage](source, target)

        dmg.Physical    = DamageLib.CalculatePhysicalDamage(source, target, damageOut.RawPhysical or 0)
        dmg.Magical     = DamageLib.CalculateMagicalDamage(source, target, damageOut.RawMagical or 0)
        dmg.True        = damageOut.RawTrue or 0

        if damageOut.ApplyOnHit or damageOut.ApplyOnAttack then
            local mod = damageOut.ApplyOnHitPercent or 1
            local itemDamage = ComputeItemDamage(source, target, damageOut)
            dmg.Physical = dmg.Physical + (itemDamage.FlatPhysical * mod)
            dmg.Magical  = dmg.Magical  + (itemDamage.FlatMagical * mod)
            dmg.True     = dmg.True     + (itemDamage.FlatTrue * mod)

            local passiveDamage = ComputePassiveDamage(source, target)
            dmg.Physical = dmg.Physical + (passiveDamage.FlatPhysical * mod)
            dmg.Magical  = dmg.Magical  + (passiveDamage.FlatMagical * mod)
            dmg.True     = dmg.True     + (passiveDamage.FlatTrue * mod)
        end

        if damageOut.ApplyPassives then
            local passiveDamage = ComputePassiveDamage(source, target)
            dmg.Physical = dmg.Physical + passiveDamage.FlatPhysical
            dmg.Magical  = dmg.Magical  + passiveDamage.FlatMagical
            dmg.True     = dmg.True     + passiveDamage.FlatTrue
        end

        result = max(floor(dmg.Physical + dmg.Magical) + dmg.True, 0)
    end

    return result
end

function DamageLib.GetBuffDamage(source, target, buff, stage)
    local source, target = source and source.AsHero, target and target.AsAI
    if not source and target then return 0 end

    local dmg = {
        Physical = 0,
        Magical  = 0,
        True     = 0
    }

    local result = 0
    local stage = stage or "Default"
    local data = spellData[source.CharName]
    local buffName = buff.Name

    if data and data[buffName] and data[buffName][stage] then
        local damageOut = data[buffName][stage](source, target, buff)

        dmg.Physical    = DamageLib.CalculatePhysicalDamage(source, target, damageOut.RawPhysical or 0)
        dmg.Magical     = DamageLib.CalculateMagicalDamage(source, target, damageOut.RawMagical or 0)
        dmg.True        = damageOut.RawTrue or 0

        result = max(floor(dmg.Physical + dmg.Magical) + dmg.True, 0)
    end

    return result
end

---@type fun():void
local function Init()
    EventManager.RegisterCallback(Events.OnTick, function()
        local tick = os.clock()
        if tick > LastItemUpdateT then
            for i = 1, #Heroes do
                local hero = Heroes[i]
                if hero and hero.IsAlly then
                    UpdateItemList(hero)
                end
            end
            LastItemUpdateT = tick + 5
        end
    end)
    EventManager.RegisterCallback(Events.OnBuffGain, function(unit, buff)
        if unit.CharName == "Jax" then
            if buff.Name == "jaxrelentlessassaultas" and buff.Duration == 2.5 then
                JaxBuffData[unit.Handle] = 1
            end
        end
    end)
    EventManager.RegisterCallback(Events.OnBuffUpdate, function(unit, buff)
        if unit.CharName == "Jax" then
            if buff.Name == "jaxrelentlessassaultas" and JaxBuffData[unit.Handle] then
                JaxBuffData[unit.Handle] = JaxBuffData[unit.Handle] + 1
            end
        end
    end)

    EventManager.RegisterCallback(Events.OnBuffLost, function(unit, buff)
        if unit.CharName == "Jax" then
            if buff.Name == "jaxrelentlessassaultas" and JaxBuffData[unit.Handle] then
                JaxBuffData[unit.Handle] = 0
            end
        end
    end)
    EventManager.RegisterCallback(Events.OnDeleteObject, function(unit)
        if unit.Name == "Item_Devourer_Ghost_Particle.troy" then
            GuinsooCount = 0
        end
    end)
    EventManager.RegisterCallback(Events.OnSpellCast, function(unit, spell)
        if spell.IsBasicAttack or spell.IsSpecialAttack then
            GuinsooCount = (GuinsooCount + 1) % 3
        end
        if unit.CharName == "MissFortune" then
            if spell.SpellData and spell.Target then
                if spell.SpellData.Name:lower():find("passiveattack") then
                    MissFortuneAttackData[unit.Handle] = spell.Target.Handle
                end
            end
        end
        if unit.CharName == "Sett" then
            if spell.SpellData then
                SettAttackData[unit.Handle] = spell.SpellData.Name
            end
        end
    end)
    EventManager.RegisterCallback(Events.OnCastStop, function(sender, spellcast, bStopAnimation, bExecuteCastFrame, bDestroyMissile)
        if sender.CharName == "Sett" then
            if SettAttackData[sender.Handle] and spellcast.SpellData then
                if spellcast.SpellData.Name == "SettQAttack" then
                    SettAttackData[sender.Handle] = ""
                end
            end
        end
    end)
    EventManager.RegisterCallback(Events.OnBuffLost, function(unit, buff)
        if HasItem(unit, ItemID.Sheen) or
                HasItem(unit, ItemID.TrinityForce) or
                HasItem(unit, ItemID.DivineSunderer) or
                HasItem(unit, ItemID.EssenceReaver) or
                HasItem(unit, ItemID.LichBane)
        then
            if SheenBuffs[buff.Name] then
                SheenTracker[unit.Handle] = os.clock()
            end
        end
    end)
    EventManager.RegisterCallback(Events.OnVisionGain, UpdateItemList)
    EventManager.RegisterCallback(Events.OnBasicAttack, UpdateTurretBuff)

    local function ProcessDatabase(old, new)
        for _, passive in ipairs(old) do
            insert(new, passive)
        end
    end

    local newStatic, newDynamic = {}, {}
    ProcessDatabase(staticPassiveDamages["Common"] or {}, newStatic)
    ProcessDatabase(dynamicPassiveDamages["Common"] or {}, newDynamic)

    local processed = {}
    for k, obj in pairs(ObjectManager.Get("all", "heroes")) do
        local hero = obj.AsHero
        if hero then
            local charName = hero.CharName
            if not processed[charName] then
                processed[charName] = true
                ProcessDatabase(staticPassiveDamages[charName] or {}, newStatic)
                ProcessDatabase(dynamicPassiveDamages[charName] or {}, newDynamic)
            end
        end
    end
    staticPassiveDamages, dynamicPassiveDamages = newStatic, newDynamic
end

------------------------------------// ITEM DAMAGES //--------------------------------------

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.23] Doran's Ring                                                                   |
--| UNIQUE – FOCUS: Basic attacks deal 5 bonus physical damage on-hit against minions.     |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

dynamicItemDamages[ItemID.DoransRing] = function(res, source, target)
    if target.IsMinion and not target.IsNeutral then
        res.FlatPhysical = res.FlatPhysical + 5
    end
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.23] Doran's Shield                                                                 |
--| UNIQUE – FOCUS: Basic attacks deal 5 bonus physical damage on-hit against minions.     |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

dynamicItemDamages[ItemID.DoransShield] = function(res, source, target)
    if target.IsMinion and not target.IsNeutral then
        res.FlatPhysical = res.FlatPhysical + 5
    end
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.23] Tear of the Goddess                                                            |
--| UNIQUE – FOCUS: Basic attacks deal 5 bonus physical damage on-hit against minions.     |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\


dynamicItemDamages[ItemID.TearOftheGoddess] = function(res, source, target)
    if target.IsMinion and not target.IsNeutral then
        res.FlatPhysical = res.FlatPhysical + 5
    end
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.23] Noonquiver                                                                     |
--| Basic attacks deal 20 bonus physical damage on-hit against minions and monsters.       |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

staticItemDamages[ItemID.Noonquiver] = function(res, source, isMinionTarget)
    if isMinionTarget then
        res.FlatPhysical = res.FlatPhysical + 20
    end
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.6] Rageknife                                                                       |
--| Convert every 1% critical strike chance into 1.75 bonus physical damage on-hit, capped |
--| at 100% critical strike chance, for a maximum of 175 bonus physical damage on-hit.     |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

staticItemDamages[ItemID.Rageknife] = function(res, source, isMinionTarget)
    local total_crit = 0
    for id, item in pairs(GetItems(source)) do
        total_crit = total_crit + item.CritChance
    end
    if total_crit > 1 then total_crit = 1 end
    res.FlatPhysical = res.FlatPhysical + min(175, (total_crit * 100) * 1.75)
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.6] Guinsoo's Rageblade                                                             |
--| Convert every 1% critical strike chance into 2 bonus physical damage on-hit, capped    |
--| at 100% critical strike chance, for a maximum of 200 bonus physical damage on-hit.     |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

staticItemDamages[ItemID.GuinsoosRageblade] = function(res, source, isMinionTarget)
    local total_crit = 0
    for id, item in pairs(GetItems(source)) do
        total_crit = total_crit + item.CritChance
    end
    if total_crit > 1 then total_crit = 1 end
    res.FlatPhysical = res.FlatPhysical + min(200, (total_crit * 100) * 2)
    if GuinsooCount == 2 then res.ApplyOnHit = true end
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.23] Kircheis Shard                                                                 |
--| When fully Energized, your next basic attack deals 80 bonus magic damage on-hit.       |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

staticItemDamages[ItemID.KircheisShard] = function(res, source, isMinionTarget)
    local buff = source:GetBuff("itemstatikshankcharge")
    if buff and buff.Count == 100 then
        res.FlatMagical = res.FlatMagical + 80
    end
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.23] Rapid Firecannon                                                               |
--| When fully Energized, your next basic attack deals 120 bonus magic damage on-hit.      |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

staticItemDamages[ItemID.RapidFirecannon] = function(res, source, isMinionTarget)
    local buff = source:GetBuff("itemstatikshankcharge")
    if buff and buff.Count == 100 then
        res.FlatMagical = res.FlatMagical + 120
    end
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.23] Rapid Stormrazor                                                               |
--| When fully Energized, your next basic attack deals 120 bonus magic damage on-hit.      |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

staticItemDamages[ItemID.Stormrazor] = function(res, source, isMinionTarget)
    local buff = source:GetBuff("itemstatikshankcharge")
    if buff and buff.Count == 100 then
        res.FlatMagical = res.FlatMagical + 120
    end
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Nashor's Tooth                                                                 |
--| Basic attacks deal 15 (+ 20% AP) bonus magic damage on-hit.                            |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

staticItemDamages[ItemID.NashorsTooth] = function(res, source, isMinionTarget)
    res.FlatMagical = res.FlatMagical + (15 + 0.20 * source.TotalAP)
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.23] Recurve Bow                                                                    |
--| Basic attacks deal 15 bonus physical damage on-hit.                                    |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

staticItemDamages[ItemID.RecurveBow] = function(res, source, isMinionTarget)
    res.FlatPhysical = res.FlatPhysical + 15
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.23] Titanic Hydra                                                                  |
--| Basic attacks deal (Melee 5 / Ranged 3.75) (+ (Melee 1.5% / Ranged 1.125%)             |
--| maximum health) bonus physical damage on-hit                                           |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

staticItemDamages[ItemID.TitanicHydra] = function(res, source, isMinionTarget)
    if source.IsMelee then
        res.FlatPhysical = res.FlatPhysical + 5 + (source.MaxHealth * 0.015)
    else
        res.FlatPhysical = res.FlatPhysical + 3.75 + (source.MaxHealth * 0.01125)
    end
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.23] Sheen                                                                          |
--| After using an ability, your next basic attack within 10 seconds deals 100%            |
--| base AD bonus physical damage on-hit                                                   |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

staticItemDamages[ItemID.Sheen] = function(res, source, isMinionTarget, spellProperties)
    local lastSheenT = SheenTracker[source.Handle]
    local buff = source:GetBuff("sheen")
    if buff or (spellProperties and spellProperties.ApplyOnHit and lastSheenT and os.clock() >= lastSheenT + 1.5) then
        res.FlatPhysical = res.FlatPhysical + source.BaseAD
    end
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.23] Trinity Force                                                                  |
--| After using an ability, your next basic attack within 10 seconds deals 200%            |
--| base AD bonus physical damage on-hit                                                   |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

staticItemDamages[ItemID.TrinityForce] = function(res, source, isMinionTarget, spellProperties)
    local lastSheenT = SheenTracker[source.Handle]
    local buff = source:GetBuff("3078trinityforce")
    if buff or (spellProperties and spellProperties.ApplyOnHit and lastSheenT and os.clock() >= lastSheenT + 1.5) then
        res.FlatPhysical = res.FlatPhysical + (source.BaseAD * 2)
    end
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.17] Wit's End                                                                      |
--| Basic attacks deal 15 - 80 (based on level) bonus magic damage on-hit                  |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

staticItemDamages[ItemID.WitsEnd] = function(res, source, isMinionTarget)
    res.FlatMagical = res.FlatMagical + GetDamageByLvl({15, 15, 15, 15, 15, 15, 15, 15, 25, 35, 45, 55, 65, 75, 76.25, 77.5, 78.75, 80}, source.Level)
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.2] Lich Bane                                                                       |
--| After using an ability, your next basic attack within 10 seconds deals                 |
--| 75% base AD (+ 50% AP) bonus magic damage on-hit                                       |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

staticItemDamages[ItemID.LichBane] = function(res, source, isMinionTarget, spellProperties)
    local lastSheenT = SheenTracker[source.Handle]
    local buff = source:GetBuff("lichbane")
    if buff or (spellProperties and spellProperties.ApplyOnHit and lastSheenT and os.clock() >= lastSheenT + 2.5) then
        res.FlatMagical = res.FlatMagical + (source.BaseAD * 0.75) + (source.TotalAP * 0.5)
    end
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.23] Essence Reaver                                                                 |
--| After using an ability, deal 100% base attack damage (+ 40% bonus AD)                  |
--| physical damage on-hit                                                                 |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

staticItemDamages[ItemID.EssenceReaver] = function(res, source, isMinionTarget, spellProperties)
    local lastSheenT = SheenTracker[source.Handle]
    local buff = source:GetBuff("3508buff")
    if buff or (spellProperties and spellProperties.ApplyOnHit and lastSheenT and os.clock() >= lastSheenT + 1.5) then
        res.FlatPhysical = res.FlatMagical + source.BaseAD + (source.BonusAD * 0.4)
    end
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.11] Kraken Slayer                                                                  |
--| Basic attacks on-attack grant a stack for 3 seconds, up to 2 stacks.                   |
--| At 2 stacks, the next basic attack on-attack consumes all stacks to                    |
--| deal 50 (+ 40% bonus AD) bonus true damage on-hit.                                     |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

staticItemDamages[ItemID.KrakenSlayer] = function(res, source, isMinionTarget)
    local buff = source:GetBuff("6672buff")
    if buff and buff.Count > 1 then
        res.FlatTrue = res.FlatTrue + (50 + source.BonusAD * 0.4)
    end
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.23] Frostfire Gauntlet                                                                  |
--| UNIQUE – SNOWBIND: Basic attacks create a 250 radius frost field around the target     |
--| that lasts for 1.5 seconds and deals (20 − 100 /  10 − 50) (based on level) (+ (0.5%   |
--| / 0.25%) maximum health) magic damage to all enemies inside                            |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

staticItemDamages[ItemID.FrostfireGauntlet] = function(res, source, isMinionTarget)
    local lvl, dmg = source.Level, 12 + (0.01 * source.BonusHealth)
    if source.IsMelee then
        dmg = dmg + GetDamageByLvl({20, 24.71, 29.41, 34.12, 38.82, 43.53, 48.24, 52.94, 57.65, 62.35, 67.06, 71.76, 76.47, 81.18, 85.88, 90.59, 95.29, 100}, lvl)
        dmg = dmg + (0.5/100) * source.MaxHealth
    else
        dmg = dmg + GetDamageByLvl({10, 12.35, 14.71, 17.06, 19.41, 21.76, 24.12, 26.47, 28.82, 31.18, 33.53, 35.88, 38.24, 40.59, 42.94, 45.29, 47.65, 50}, lvl)
        dmg = dmg + (0.25/100) * source.MaxHealth
    end
    res.FlatMagical = res.FlatMagical + dmg
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.23] Lord Dominik's Regards                                                         |
--| Deal 0% − 15% (based on maximum health difference) bonus physical damage against       |
--| enemy champions.                                                                       |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

dynamicItemDamages[ItemID.LordDominiksRegards] = function(res, source, target)
    local target = target.AsHero
    if not target then return end

    local diff = min(2000, max(0, target.MaxHealth - source.MaxHealth))
    res.FlatPhysical = res.FlatPhysical + (diff/100*0.0075) * source.TotalAD
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.5] Muramana                                                                        |
--| Damaging basic attacks on-hit and abilities against champions deal 1.5% of               |
--| maximum mana bonus physical damage                                                     |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

dynamicItemDamages[ItemID.Muramana] = function(res, source, target)
    local target = target.AsAI
    if not target then return end

    if target.IsHero then
        res.FlatPhysical = res.FlatPhysical + (source.MaxMana * 0.015)
    end
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.23] Divine Sunderer                                                                |
--| After using an ability, your next basic attack within 10 seconds deals 10%             |
--| of target's maximum health as bonus physical damage on-hit, with a minimum             |
--| damage equal to 150% of base AD and a maximum damage against monsters equal            |
--| to 250% base AD                                                                        |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

dynamicItemDamages[ItemID.DivineSunderer] = function(res, source, target, spellProperties)
    local target = target.AsAI
    if not target then return end

    local lastSheenT = SheenTracker[source.Handle]
    local buff = source:GetBuff("6632buff")
    if buff or (spellProperties and spellProperties.ApplyOnHit and lastSheenT and os.clock() >= lastSheenT + 1.5) then
        local mod = source.IsMelee and 0.12 or 0.09
        local dmg = max(source.BaseAD * 1.5, target.MaxHealth * mod)
        dmg = (target.IsMonster and min(dmg, source.BaseAD * 2.5)) or dmg
        res.FlatPhysical = res.FlatPhysical + dmg
    end
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.3] Blade of the Ruined King                                                        |
--| MIST'S EDGE: Basic attacks deal (Melee 12% / Ranged 8%) of the target's current        |
--| health bonus physical damage on-hit, capped at 60 bonus damage against minions         |
--| and monsters.                                                                          |
--| SIPHON: Basic attacks on-hit apply a stack to enemy champions for 6 seconds,           |
--| up to 3 stacks. Attacking a champion with 2 stacks consumes them to deal 40 - 150      |
--| bonus magic damage on-hit                                                              |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

dynamicItemDamages[ItemID.BladeOftheRuinedKing] = function(res, source, target)
    local target = target.AsAI
    if not target then return end

    local dmg = (source.IsMelee and 0.12 or 0.08) * target.Health
    dmg = (target.IsMinion and min(dmg, 60)) or dmg
    res.FlatPhysical = res.FlatPhysical + dmg

    if target.IsHero then
        local activeBuff = target:GetBuff("item3153botrkstacks")
        if activeBuff and activeBuff.Count == 2 then
            local lvl = source.Level
            local rawActiveBotrkDamage = 40 + 110/17 * (lvl-1)
            res.FlatMagical = res.FlatMagical + rawActiveBotrkDamage
        end
    end
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.6] Liandry's Anguish                                                               |
--| UNIQUE – AGONY: Deal 0% − 12% (based on target's bonus health) bonus magic             |
--| damage against enemy champions.                                                        |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

dynamicItemDamages[ItemID.LiandrysAnguish] = function(res, source, target)
    local target = target.AsAI
    if not target then return end
    
    res.PercentMagical = res.PercentMagical + (0.012 * (target.BonusHealth/125))
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.23] Turbo Chemtank                                                                 |
--| At 100 stacks, your next basic attack deals 40 − 120 (based on level) (+ 1% maximum    |
--| health) (+ 3% movement speed) magic damage to all nearby enemies, increased by 25%     |
--| against minions and 175% against monsters.                                             |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

dynamicItemDamages[ItemID.TurboChemtank] = function(res, source, target, spellProperties)
    local target = target.AsAI
    if not target then return end

    local buff = source:GetBuff("item6664counter")
    if buff and buff.Count == 100 then
        local dmg = 40 + 80/17 * (source.Level - 1)
        dmg = dmg + (0.01 * source.MaxHealth) + (0.03 * source.MoveSpeed)
        if target.IsMinion then
            dmg = dmg * (1 + (target.IsNeutral and 1.75 or 0.25))
        end
        res.FlatMagical = res.FlatMagical + dmg
    end
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.23] Dead Man's Plate                                                               |
--| Basic attacks consume all stacks on-hit to deal 0 − 40 (based on Momentum)             |
--| (+ 0% − 100% (based on Momentum) base AD) bonus physical damage.                       |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

dynamicItemDamages[ItemID.DeadMansPlate] = function(res, source, target, spellProperties)
    local target = target.AsAI
    if not target then return end    

    local itemSlot
    for slot, item in pairs(source.Items) do
        if item.ItemId == ItemID.DeadMansPlate then
            local momentum = item.Charges
            res.FlatPhysical = res.FlatPhysical + (momentum * 2/5) + (momentum/100 * source.BaseAD)
            break
        end
    end
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.23] Duskblade of Draktharr                                                         |
--| Your next basic attack against an enemy champion deals (75 / 55) (+ (30% / 25%) bonus  |
--| AD) bonus physical damage on-hit                                                       |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

dynamicItemDamages[ItemID.DuskbladeOfDraktharr] = function(res, source, target, spellProperties)
    local target = target.AsHero
    if not target then return end    

    local itemSlot
    for slot, item in pairs(source.Items) do
        if item.ItemId == ItemID.DuskbladeOfDraktharr then
            itemSlot = slot
            break
        end
    end

    if itemSlot and source:GetSpellState(itemSlot+6) == 0 then
        local dmg = (source.IsMelee and (75 + 0.3 * source.BonusAD)) or (55 + 0.25 * source.BonusAD)          
        res.FlatPhysical = res.FlatPhysical + dmg
    end
end

--------------------------------------// PERK DAMAGES //------------------------------------

staticPassiveDamages["Common"] = {
    [1] = { -- Ardent Censer
        Name = nil,
        Func = function(res, source, isMinionTarget)
            local heroSource = source.AsHero
            if heroSource and heroSource:GetBuff("3504Buff") then
                local dmg = 5 + 15/17 * (heroSource.Level-1)
                res.FlatMagical = res.FlatMagical + dmg
            end
        end,
    },
}

dynamicPassiveDamages["Common"] = {
    [1] = { -- Press The Attack
        Name = nil,
        Func = function(res, source, target)
            local heroSource, aiTarget = source.AsHero, target.AsAI
            if not (heroSource and aiTarget) then return end

            local buff = aiTarget:GetBuff("ASSETS/Perks/Styles/Precision/PressTheAttack/PressTheAttackStack.lua")
            if buff and buff.Count == 2 then
                local dmg = 31.765 + 8.235 * heroSource.Level

                if source.BonusAP > source.BonusAD then
                    res.FlatMagical = res.FlatMagical + dmg
                else
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        end,
    },
    [2] = { -- Support Items (Execute Minions Below X % Health)
        Name = nil,
        Func = function(res, source, target)
            local hS, mT = source.AsHero, target.AsMinion
            if not (hS and mT) then return end

            if hS:GetBuff("talentreaperstacksone") or hS:GetBuff("talentreaperstackstwo") or hS:GetBuff("talentreaperstacksthree") then
                local allyNearby = false
                for k, v in pairs(ObjectManager.Get((source.IsAlly and "ally") or "enemy", "heroes")) do  
                    if v ~= source and v.IsTargetable and v:Distance(mT) <= 1050 then 
                        allyNearby = true 
                        break 
                    end
                end

                local executeThreshold = (source.IsMelee and 0.5 or 0.3)
                local healthRemaining = mT.Health - res.FlatPhysical - res.FlatMagical - res.FlatTrue
                if allyNearby and (healthRemaining/mT.MaxHealth) < executeThreshold then
                    res.FlatPhysical = 0
                    res.FlatMagical = 0
                    res.FlatTrue = mT.Health
                end
            end 
        end,
    },
    [3] = { -- Grasp Of The Undying
        Name = nil,
        Func = function(res, source, target)
            local heroSource = source.AsHero
            if not (heroSource and target and target.IsHero) then return end

            if heroSource:GetBuff("ASSETS/Perks/Styles/Resolve/GraspOfTheUndying/GraspOfTheUndyingONH.lua") then
                res.FlatMagical = res.FlatMagical + (source.IsMelee and 0.04 or 0.024) * source.MaxHealth
            end
        end,
    },
}

------------------------------------// CHAMPION DAMAGES //----------------------------------

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Aatrox                                                                         |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Aatrox"] then
    spellDamages["Aatrox"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({10, 30, 50, 70, 90}, lvl) + (0.55 + 0.05 * lvl) * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
            ["SecondCast"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({12.5, 37.5, 62.5, 87.5, 112.5}, lvl) + (0.6875 + 0.0625 * lvl) * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
            ["ThirdCast"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({15, 45, 75, 105, 135}, lvl) + (0.825 + 0.075 * lvl) * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({30, 40, 50, 60, 70}, lvl) + 0.4 * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Aatrox'] = {
        --// Spells //--
        ['AatroxQ'] = {
            ['Default'] = spellDamages['Aatrox'][SpellSlots.Q]['Default'],
        },
        ['AatroxQ2'] = {
            ['Default'] = spellDamages['Aatrox'][SpellSlots.Q]['SecondCast'],
        },
        ['AatroxQ3'] = {
            ['Default'] = spellDamages['Aatrox'][SpellSlots.Q]['ThirdCast'],
        },
        ['AatroxW'] = {
            ['Default'] = spellDamages['Aatrox'][SpellSlots.W]['Default'],
        },

         --// Buffs //--
        ['aatroxwchains'] = {
            ['Default'] = spellDamages['Aatrox'][SpellSlots.W]['Default'],
        }
    }

    dynamicPassiveDamages["Aatrox"] = {
        [1] = {
            Name = "Aatrox",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if aiTarget and source:GetBuff("aatroxpassiveready") then
                    local pct = 0.04588 + 0.00412 * source.Level
                    local dmg = aiTarget.MaxHealth * pct
                    if aiTarget.IsMonster then dmg = min(dmg, 100) end
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.5] Ahri                                                                            |
--| Last Update: 02.03.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Ahri"] then
    spellDamages["Ahri"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({40, 65, 90, 115, 140}, lvl) + 0.4 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["WayBack"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({40, 65, 90, 115, 140}, lvl) + 0.4 * source.TotalAP
                return { RawTrue = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({50, 75, 100, 125, 150}, lvl) + 0.3 * source.TotalAP
                if target.IsMinion and target.HealthPercent < 0.2 then
                    rawDmg = rawDmg * 2
                end
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({80, 110, 140, 170, 200}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({60, 90, 120}, lvl) + 0.35 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Ahri'] = {
        ['AhriSeduce'] = {
            ['Default'] = spellDamages['Ahri'][SpellSlots.E]['Default'],
        },
        ['AhriOrbofDeception'] = {
            ['WayBack'] = spellDamages['Ahri'][SpellSlots.Q]['WayBack'],
            ['Default'] = spellDamages['Ahri'][SpellSlots.Q]['Default'],
        },
        ['AhriOrbReturn'] = {
            ['WayBack'] = spellDamages['Ahri'][SpellSlots.Q]['WayBack'],
            ['Default'] = spellDamages['Ahri'][SpellSlots.Q]['WayBack'],
        },
        ['AhriFoxFireMissileTwo'] = {
            ['Default'] = spellDamages['Ahri'][SpellSlots.W]['Default'],
        },
        ['AhriTumbleMissile'] = {
            ['Default'] = spellDamages['Ahri'][SpellSlots.R]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.22] Akali                                                                          |
--| Last Update: 04.11.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Akali"] then --mark Q
    spellDamages["Akali"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({30, 55, 80, 105, 130}, lvl) + 0.65 * source.TotalAD + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({30, 56.25, 82.5, 108.75, 135}, lvl) + 0.255 * source.TotalAD + 0.36 * source.TotalAP
                return { RawMagical = rawDmg }
            end
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({80, 220, 360}, lvl) + 0.5 * source.BonusAD + 0.3 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
            ["SecondCast"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local missingHealth = min(1 - target.HealthPercent, 0.7)
                local addDamage = 2.86 * missingHealth
                local rawDmg = GetDamageByLvl({60, 130, 200}, lvl) + 0.3 * source.TotalAP
                local totalRawDmg = rawDmg + (rawDmg * addDamage)
                return { RawMagical = totalRawDmg }
            end
        },
    }

    spellData['Akali'] = {
        ['AkaliQMis3'] = {
            ['Default'] = spellDamages['Akali'][SpellSlots.Q]['Default'],
        },
        ['AkaliE'] = {
            ['Default'] = spellDamages['Akali'][SpellSlots.E]['Default'],
        },
        ['AkaliQMis2'] = {
            ['Default'] = spellDamages['Akali'][SpellSlots.Q]['Default'],
        },
        ['AkaliQMis5'] = {
            ['Default'] = spellDamages['Akali'][SpellSlots.Q]['Default'],
        },
        ['AkaliQMis'] = {
            ['Default'] = spellDamages['Akali'][SpellSlots.Q]['Default'],
        },
        ['AkaliQMis1'] = {
            ['Default'] = spellDamages['Akali'][SpellSlots.Q]['Default'],
        },
        ['AkaliQMis4'] = {
            ['Default'] = spellDamages['Akali'][SpellSlots.Q]['Default'],
        },
        ['AkaliQMis0'] = {
            ['Default'] = spellDamages['Akali'][SpellSlots.Q]['Default'],
        },
        ['AkaliR'] = {
            ['Default'] = spellDamages['Akali'][SpellSlots.R]['Default'],
        },
        ['AkaliRb'] = {
            ['Default'] = spellDamages['Akali'][SpellSlots.R]['SecondCast'],
        },
    }

    staticPassiveDamages["Akali"] = {
        [1] = {
            Name = "Akali",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("akalipweapon") then
                    local baseDmg = GetDamageByLvl({35, 38, 41, 44, 47, 50, 53, 62, 71, 80, 89, 98, 107, 122, 152, 167, 182}, source.Level)
                    res.FlatMagical = res.FlatMagical + (baseDmg + source.BonusAD * 0.6 + source.TotalAP * 0.55)
                end
            end
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.3] Akshan                                                                          |
--| Last Update: 08.02.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Akshan"] then
    spellDamages["Akshan"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({5, 25, 45, 65, 85},  lvl) + 0.8 * source.TotalAD
                return { RawPhysical = rawDmg }
            end
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local bonusAS = source.AttackSpeedMod - 1
                local rawDmg = GetDamageByLvl({30, 45, 60, 75, 90},  lvl) + 0.175 * source.BonusAD
                return { RawPhysical = rawDmg * (1 + bonusAS * 0.3), ApplyOnHit = true, ApplyOnHitPercent = 0.25 }
            end
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local missingHealthMod = ((target.MaxHealth - target.Health) * 0.001) * 3
                local rawDmg = GetDamageByLvl({20, 25, 30},  lvl) + 0.1 * source.TotalAD
                return { RawPhysical = rawDmg + rawDmg * missingHealthMod }
            end
        },
    }

    dynamicPassiveDamages["Akshan"] = {
        [1] = {
            Name = "Akshan",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if aiTarget and aiTarget:GetBuffCount("AkshanPassiveDebuff") > 1 then
                    local rawDmg = GetDamageByLvl({10, 15, 20, 25, 30, 35, 40, 45, 55, 65, 75, 85, 95, 105, 120, 135, 150, 165}, source.Level)
                    res.FlatMagical = res.FlatMagical + rawDmg
                end
            end
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.7] Alistar                                                                         |
--| Last Update: 31.03.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Alistar"] then --mark E
    spellDamages["Alistar"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({60, 100, 140, 180, 220},  lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({55, 110, 165, 220, 275}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local d = spellDamages.Alistar[SpellSlots.E].DamagePerSecond(source, target)
                local tickCount = d.Interval * d.Duration
                return { RawMagical = d.RawMagical * tickCount }
            end,
            ["DamagePerSecond"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({8, 11, 14, 17, 20}, lvl) + 0.04 * source.TotalAP
                local buff = source:GetBuff("alistare")
                local buffDuration = buff and buff.DurationLeft or 5
                return { RawMagical = rawDmg, Interval = 2, Duration = buffDuration }
            end,
        }
    }

    spellData['Alistar'] = {
        ['Pulverize'] = {
            ['Default'] = spellDamages['Alistar'][SpellSlots.Q]['Default'],
        },
        ['Headbutt'] = {
            ['Default'] = spellDamages['Alistar'][SpellSlots.W]['Default'],
        }
    }

    staticPassiveDamages["Alistar"] = {
        [1] = {
            Name = "Alistar",
            Func = function(res, source, isMinionTarget)
                if not isMinionTarget and source:GetBuff("alistareattack") then
                    res.FlatMagical = res.FlatMagical + (5 + 15 * source.Level)
                end
            end
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.12] Amumu                                                                          |
--| Last Update: 23.06.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Amumu"] then
    spellDamages["Amumu"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({70, 95, 120, 145, 170}, lvl) + 0.85 * source.TotalAP
                return { RawMagical = rawDmg }
            end
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({6, 8, 10, 12, 14}, lvl)
                local maxHP = (GetDamageByLvl({0.005, 0.00575, 0.0065, 0.00725, 0.008}, lvl) + 0.025 * (source.TotalAP / 100)) * target.MaxHealth
                local totalDmg = rawDmg + maxHP
                return { RawMagical = totalDmg }
            end
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({75, 100, 125, 150, 175}, lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({200, 300, 400}, lvl) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end
        },
    }

    spellData['Amumu'] = {
        ['BandageToss'] = {
            ['Default'] = spellDamages['Amumu'][SpellSlots.Q]['Default'],
        },
        ['Tantrum'] = {
            ['Default'] = spellDamages['Amumu'][SpellSlots.E]['Default'],
        },
        ['CurseoftheSadMummy'] = {
            ['Default'] = spellDamages['Amumu'][SpellSlots.R]['Default'],
        },
        ['Amumu_Base_W_Despair_buf'] = {
            ['Default'] = spellDamages['Amumu'][SpellSlots.W]['Default'],
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.10] Anivia                                                                         |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Anivia"] then
    spellDamages["Anivia"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({50, 70, 90, 110, 130}, lvl) + 0.25 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["Detonation"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({60, 95, 130, 165, 200}, lvl) + 0.45 * source.TotalAP
                return { RawMagical = rawDmg }
            end
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({50, 75, 100, 125, 150}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({100, 160, 220, 280, 340}, lvl) + 1.2 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({30, 45, 60}, lvl) + 0.125 * source.TotalAP
                return { RawMagical = rawDmg * 2 }
            end
        }
    }

    spellData['Anivia'] = {
        ['FlashFrostSpell'] = {
            ['Detonation'] = spellDamages['Anivia'][SpellSlots.Q]['Detonation'],
            ['Default'] = spellDamages['Anivia'][SpellSlots.Q]['Detonation'],
        },
        ['Frostbite'] = {
            ['Empowered'] = spellDamages['Anivia'][SpellSlots.E]['Empowered'],
            ['Default'] = function(source, target)
                local damage = spellDamages['Anivia'][SpellSlots.E]['Default'](source, target)
                if target:GetBuff("aniviachilled") then
                    damage = spellDamages['Anivia'][SpellSlots.E]['Empowered'](source, target)
                end
                return damage
            end
        },
        ['Anivia_Base_R_indicator_ring'] = {
            ['Default'] = spellDamages['Anivia'][SpellSlots.R]['Default'],
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.12] Annie                                                                          |
--| Last Update: 23.06.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Annie"] then
    spellDamages["Annie"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({80, 115, 150, 185, 220}, lvl) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({70, 115, 160, 205, 250}, lvl) + 0.85 * source.TotalAP
                return { RawMagical = rawDmg }
            end
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 275, 400}, lvl) + 0.75 * source.TotalAP
                return { RawMagical = rawDmg }
            end
        },
    }

    spellData['Annie'] = {
        ['AnnieQ'] = {
            ['Default'] = spellDamages['Annie'][SpellSlots.Q]['Default'],
        },
        ['AnnieW'] = {
            ['Default'] = spellDamages['Annie'][SpellSlots.W]['Default'],
        },
        ['AnnieR'] = {
            ['Default'] = spellDamages['Annie'][SpellSlots.R]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.12] Aphelios                                                                       |
--| Last Update: 13.06.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Aphelios"] then --mark
    spellDamages["Aphelios"] = {
        [SpellSlots.Q] = {
            ["Calibrum"] = function(source, target)
                local lvl = min(source.Level, 13)
                local adRatio = (0.42 + 0.03 * ceil(lvl / 2 - 1)) * source.BonusAD
                local rawDmg = 60 + 16.6 * ceil(lvl / 2 - 1) + adRatio + source.TotalAP
                return { RawPhysical = rawDmg }
            end,
            ["Severum"] = function(source, target)
                local lvl = min(source.Level, 13)
                local adRatio = (0.20 + 0.025 * ceil(lvl / 2 - 1)) * source.BonusAD
                local rawDmg = 10 + 5 * ceil(lvl / 2 - 1) + adRatio
                return { RawPhysical = rawDmg }
            end,
            ["Gravitum"] = function(source, target)
                local lvl = min(source.Level, 13)
                local adRatio = (0.26 + 0.015 * ceil(lvl / 2 - 1)) * source.BonusAD
                local rawDmg = 50 + 10 * ceil(lvl / 2 - 1) + adRatio + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["Infernum"] = function(source, target)
                local lvl = min(source.Level, 13)
                local adRatio = (0.56 + 0.04 * ceil(lvl / 2 - 1)) * source.BonusAD
                local rawDmg = 25 + 6.66 * ceil(lvl / 2 - 1) + adRatio + 0.7 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
            ["Crescendum"] = function(source, target)
                local lvl = min(source.Level, 13)
                local adRatio = (0.40 + 0.033 * ceil(lvl / 2 - 1)) * source.BonusAD
                local rawDmg = 31 + 11.5 * ceil(lvl / 2 - 1) + adRatio + 0.5 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = min(source.Level, 16)
                local rawDmg = 125 + 50 * ceil(lvl / 5 - 1) + 0.2 * source.BonusAD + source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Aphelios'] = {
        ['ApheliosCalibrumQ'] = {
            ['Default'] = spellDamages['Aphelios'][SpellSlots.Q]['Calibrum'],
            ['Calibrum'] = spellDamages['Aphelios'][SpellSlots.Q]['Calibrum'],
        },
        ['ApheliosInfernumQ'] = {
            ['Default'] = spellDamages['Aphelios'][SpellSlots.Q]['Infernum'],
            ['Infernum'] = spellDamages['Aphelios'][SpellSlots.Q]['Infernum'],
        },
        ['ApheliosR'] = {
            ['Default'] = spellDamages['Aphelios'][SpellSlots.R]['Default'],
        },
    }

    staticPassiveDamages["Aphelios"] = {
        [1] = {
            Name = "Aphelios",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("apheliosinfernummanager") then
                    res.FlatPhysical = res.FlatPhysical + .1 * source.TotalAD
                end
            end,
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Ashe                                                                           |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Ashe"] then --mark W
    spellDamages["Ashe"] = {
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({20, 35, 50, 65, 80}, lvl) + source.TotalAD
                return { RawPhysical = rawDmg }
            end
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({200, 400, 600}, lvl) + source.TotalAP
                return { RawMagical = rawDmg }
            end
        },
    }

    spellData['Ashe'] = {
        ['VolleyAttackWithSound'] = {
            ['Default'] = spellDamages['Ashe'][SpellSlots.W]['Default'],
        },
        ['VolleyAttack'] = {
            ['Default'] = spellDamages['Ashe'][SpellSlots.W]['Default'],
        },
        ['EnchantedCrystalArrow'] = {
            ['Default'] = spellDamages['Ashe'][SpellSlots.R]['Default'],
        },
    }

    dynamicPassiveDamages["Ashe"] = {
        [1] = {
            Name = "Ashe",
            Func = function(res, source, target)
                if source:GetBuff("AsheQAttack") then return end
                local aiTarget = target.AsAI
                if aiTarget and aiTarget:GetBuff("ashepassiveslow") then
                    local critMod = source.CritChance * (0.75 + InfinityEdgeMod(source, 0.35))
                    res.FlatPhysical = res.FlatPhysical + (0.1 + critMod) * source.TotalAD
                end
            end
        },
        [2] = {
            Name = "Ashe",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if source:GetBuff("AsheQAttack") then
                    local totalAD = source.TotalAD
                    local critMod = source.CritChance + (source.CritDamageMultiplier - 1)
                    local damagePerShot = totalAD * (0.2 + 0.01 * source:GetSpell(SpellSlots.Q).Level)
                    res.FlatPhysical = (res.FlatPhysical - totalAD) + 5 * damagePerShot * (1.1 + critMod)
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] AurelionSol                                                                    |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["AurelionSol"] then --mark W
    spellDamages["AurelionSol"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({70, 110, 150, 190, 230}, lvl) + 0.65 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local baseDmg = GetDamageByLvl({12, 14, 16, 18, 20, 23, 26, 32, 38, 44, 50, 60, 70, 80, 90, 100, 110, 120}, source.Level)
                local rawDmg = GetDamageByLvl({5, 10, 15, 20, 25}, lvl)
                local totalDmg = baseDmg + rawDmg + 0.25 * source.TotalAP
                return { RawMagical = totalDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local starDmg = spellDamages.AurelionSol[SpellSlots.W].Default(source, target)
                local totalDmg = starDmg.RawMagical + (starDmg.RawMagical * 0.4)
                return { RawMagical = totalDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 250, 350}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['AurelionSol'] = {
        ['AurelionSolRBeamMissile'] = {
            ['Default'] = spellDamages['AurelionSol'][SpellSlots.R]['Default'],
        },
        ['AurelionSolQMissile'] = {
            ['Default'] = spellDamages['AurelionSol'][SpellSlots.Q]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.5] Azir                                                                           |
--| Last Update: 11.03.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Azir"] then
    spellDamages["Azir"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({70, 90, 110, 130, 150}, lvl) + 0.3 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({50, 52, 54, 56, 58, 60, 62, 65, 70, 75, 80, 90, 100, 110, 120, 130, 140, 150}, source.Level) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({60, 90, 120, 150, 180}, lvl) + 0.4 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({175, 325, 475}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['AurelionSol'] = {
        ['AzirQWrapper'] = {
            ['Default'] = spellDamages['Azir'][SpellSlots.Q]['Default'],
        },
        ['AzirR'] = {
            ['Default'] = spellDamages['Azir'][SpellSlots.R]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.8] Bard                                                                           |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Bard"] then --mark
    spellDamages["Bard"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({80, 125, 170, 215, 260}, lvl) + 0.65 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
    }
    
    spellData['Bard'] = {
        ['BardQ'] = {
            ['Default'] = spellDamages['Bard'][SpellSlots.Q]['Default'],
        },
        ['BardQ2'] = {
            ['Default'] = spellDamages['Bard'][SpellSlots.Q]['Default'],
        },
    }

    staticPassiveDamages["Bard"] = {
        [1] = {
            Name = "Bard",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("bardpspiritammocount") then
                    local chimes = source:GetSpell(63).Ammo
                    if chimes > 0 then
                        local dmg = 35 + 14 * floor(chimes/5) + 0.3 * source.TotalAP
                        res.FlatMagical = res.FlatMagical + dmg
                    end
                end
            end
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.12] Blitzcrank                                                                     |
--| Last Update: 23.06.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Blitzcrank"] then
    spellDamages["Blitzcrank"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({105, 155, 205, 255, 305}, lvl) + 1.2 * source.TotalAP
                return { RawMagical = rawDmg, ApplyOnHit = true }
            end
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({275, 400, 525}, lvl) + source.TotalAP
                return { RawMagical = rawDmg }
            end
        },
    }

    spellData['Blitzcrank'] = {
        ['RocketGrab'] = {
            ['Default'] = spellDamages['Blitzcrank'][SpellSlots.Q]['Default'],
        },
        ['StaticField'] = {
            ['Default'] = spellDamages['Blitzcrank'][SpellSlots.R]['Default'],
        },
    }

    staticPassiveDamages["Blitzcrank"] = {
        [1] = {
            Name = "Blitzcrank",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("powerfist") then
                    res.FlatPhysical = res.FlatPhysical + source.TotalAD
                end
            end
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.11] Brand                                                                          |
--| Last Update: 23.06.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Brand"] then
    spellDamages["Brand"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({80, 110, 140, 170, 200}, lvl) + 0.55 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({75, 120, 165, 210, 255}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({93.75, 150, 206.25, 262.5, 318.75}, lvl) + 0.75 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({70, 95, 120, 145, 170}, lvl) + 0.45 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({100, 200, 300}, lvl) + 0.25 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Brand'] = {
        ['BrandQ'] = {
            ['Default'] = spellDamages['Brand'][SpellSlots.Q]['Default'],
        },
        ['BrandW'] = {
            ['Default'] = spellDamages['Brand'][SpellSlots.W]['Default'],
        },
        ['BrandR'] = {
            ['Default'] = spellDamages['Brand'][SpellSlots.R]['Default'],
        },
        ['BrandRMissile'] = {
            ['Default'] = spellDamages['Brand'][SpellSlots.R]['Default'],
        },
        ['BrandE'] = {
            ['Default'] = spellDamages['Brand'][SpellSlots.E]['Default'],
        },
        ['BrandAblaze'] = {
            ['Default'] = function(source, target, buff)
                local duration = buff.EndTime - Game.GetTime()
                local rawDmg = target.MaxHealth * 0.025
                return { RawMagical = rawDmg * duration }
            end
        },
        ['BrandAblazeDetonateMarker'] = {
            ['Default'] = function(source, target, buff)
                local rawDmg = (0.0875 + 0.0025 * source.Level) * target.MaxHealth + (0.02 / 100 * source.TotalAP)
                return { RawMagical = rawDmg }
            end
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Braum                                                                          |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Braum"] then --mark
    spellDamages["Braum"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({75, 125, 175, 225, 275}, lvl) + 0.025 * source.MaxHealth
                return { RawMagical = rawDmg, ApplyPassives = true }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 300, 450}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg, ApplyPassives = true }
            end,
        },
    }

    spellData['Braum'] = {
        ['BraumQ'] = {
            ['Default'] = spellDamages['Braum'][SpellSlots.Q]['Default'],
        },
        ['BraumRWrapper'] = {
            ['Default'] = spellDamages['Braum'][SpellSlots.R]['Default'],
        },
    }

    dynamicPassiveDamages["Braum"] = {
        [1] = {
            Name = "Braum",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                local buff = aiTarget and aiTarget:GetBuff("braummarkstunreduction")
                if buff then
                    local source = buff.Source
                    source = source and source.AsHero
                    if not source then return end
                    res.FlatMagical = res.FlatMagical + (16 + 10 * source.Level) * 0.2
                end
            end,
        },
        [2] = {
            Name = nil,
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end

                local buff = aiTarget:GetBuff("braummark")
                if buff and buff.Count == 3 then
                    local source = buff.Source
                    source = source and source.AsHero
                    if not source then return end
                    res.FlatMagical = res.FlatMagical + (16 + 10 * source.Level)
                end
            end,
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.11] Caitlyn                                                                        |
--| Last Update: 23.06.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Caitlyn"] then
    spellDamages["Caitlyn"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local adRatio = GetDamageByLvl({1.25, 1.45, 1.65, 1.85, 2.05}, lvl)
                local rawDmg = GetDamageByLvl({50, 90, 130, 170, 210}, lvl) + adRatio * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local adRatio = GetDamageByLvl({0.4, 0.55, 0.7, 0.85, 1}, lvl)
                local rawDmg = GetDamageByLvl({60, 105, 150, 195, 240}, lvl) + adRatio * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({80, 130, 180, 230, 280}, lvl) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({300, 525, 750}, lvl) + 2 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Caitlyn'] = {
        ['CaitlynQ'] = {
            ['Default'] = spellDamages['Caitlyn'][SpellSlots.Q]['Default'],
        },
        ['CaitlynQBehind'] = {
            ['Default'] = spellDamages['Caitlyn'][SpellSlots.Q]['Default'],
        },
        ['CaitlynE'] = {
            ['Default'] = spellDamages['Caitlyn'][SpellSlots.E]['Default'],
        },
        ['CaitlynR'] = {
            ['Default'] = spellDamages['Caitlyn'][SpellSlots.R]['Default'],
        }
    }

    dynamicPassiveDamages["Caitlyn"] = {
        [1] = {
            Name = "Caitlyn",
            Func = function(res, source, target)
                local heroSource, aiTarget = source.AsHero, target.AsAI
                if heroSource and aiTarget then
                    if not (heroSource:GetBuff("caitlynpassivedriver") or aiTarget:GetBuff("caitlynwsight") or aiTarget:GetBuff("CaitlynEMissile")) then return end

                    local lvl = (aiTarget.IsHero and heroSource.Level) or 18
                    local base = (lvl < 7 and 0.5) or (lvl < 13 and 0.75) or 1
                    local critMod = (1.09375 + InfinityEdgeMod(source, 0.21875)) * heroSource.CritChance
                    res.FlatPhysical = res.FlatPhysical + (base + critMod) * heroSource.TotalAD
                end
            end,
        },
        [2] = {
            Name = "Caitlyn",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if aiTarget and aiTarget:GetBuff("caitlynwsight") then
                    local wLvl = source:GetSpell(SpellSlots.W).Level
                    res.FlatPhysical = res.FlatPhysical + (15 + 45 * wLvl) + (0.25 + 0.15 * wLvl) * source.BonusAD
                end
            end,
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Camille                                                                        |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Camille"] then
    spellDamages["Camille"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = source.TotalAD * (0.15 + 0.05 * lvl)
                return { RawPhysical = source.TotalAD + rawDmg, ApplyOnHit = true }
            end,
            ["Empowered"] = function(source, target)
                local sLvl = min(source.Level, 16)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local dmg = source.TotalAD + (source.TotalAD * (0.15 + 0.05 * lvl)) * 2
                local trueDamagePct = 0.36 + (0.04 * sLvl)
                local physicalDamagePct = 1 - trueDamagePct
                local rawDmg = dmg * physicalDamagePct
                local rawTrueDmg = dmg * trueDamagePct
                return { RawPhysical = rawDmg, RawTrue = rawTrueDmg, ApplyOnHit = true }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({70, 100, 130, 160, 190}, lvl) + 0.6 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({60, 95, 130, 165, 200}, lvl) + 0.75 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Camille'] = {
        ['CamilleE'] = {
            ['Default'] = spellDamages['Camille'][SpellSlots.E]['Default'],
        },
        ['CamilleEDash2'] = {
            ['Default'] = spellDamages['Camille'][SpellSlots.E]['Default'],
        },
    }

    dynamicPassiveDamages["Camille"] = {
        [1] = {
            Name = "Camille",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if aiTarget and aiTarget:GetBuff("camillertether") then
                    local rLvl = source:GetSpell(SpellSlots.R).Level
                    local dmg = (0 + 5 * rLvl) + (aiTarget.MaxHealth * (0.02 + 0.02 * rLvl))
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end
        },
    }

    staticPassiveDamages["Camille"] = {
        [1] = {
            Name = "Camille",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("camilleq") then
                    local qLvl =  source:GetSpell(SpellSlots.Q).Level
                    local rawPhysical = spellDamages.Camille[SpellSlots.Q].Default(source).RawPhysical
                    res.FlatPhysical = res.FlatPhysical + (rawPhysical - source.TotalAD)
                end
            end
        },
        [2] = {
            Name = "Camille",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("camilleq2") then
                    if source:GetBuff("camilleqprimingcomplete") then
                        local dmg = spellDamages.Camille[SpellSlots.Q].Empowered(source)
                        res.FlatPhysical = res.FlatPhysical + (dmg.RawPhysical - source.TotalAD)
                        res.FlatTrue = res.FlatTrue + dmg.RawTrue
                    else
                        local dmg = spellDamages.Camille[SpellSlots.Q].Default(source)
                        res.FlatPhysical = res.FlatPhysical + (dmg.RawPhysical - source.TotalAD)
                    end
                end
            end
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.15] Cassiopeia                                                                     |
--| Last Update: 28.07.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Cassiopeia"] then
    spellDamages["Cassiopeia"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({25, 36.67, 48.33, 60, 71.67}, lvl) + 0.3 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({20, 25, 30, 35, 40}, lvl) + 0.15 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = 48 + 4 * lvl + 0.1 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = 48 + 4 * lvl + 0.1 * source.TotalAP
                local bonusDmg = 20 * lvl + 0.6 * source.TotalAP
                return { RawMagical = rawDmg + bonusDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 250, 350}, lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Cassiopeia'] = {
        ['CassiopeiaQ'] = {
            ['Default'] = spellDamages['Cassiopeia'][SpellSlots.Q]['Default'],
        },
        ['CassiopeiaE'] = {
            ['Default'] = spellDamages['Cassiopeia'][SpellSlots.E]['Empowered'],
        },
        ['CassiopeiaR'] = {
            ['Default'] = spellDamages['Cassiopeia'][SpellSlots.R]['Default'],
        },
        ['cassiopeiaqdebuff'] = {
            ['Default'] = function(source, target, buff)
                local duration = buff.EndTime - Game.GetTime()
                local rawDmg = spellDamages['Cassiopeia'][SpellSlots.Q]['Default'](source, target).RawMagical
                return { RawMagical = rawDmg * duration }
            end
        },
        ['cassiopeiawpoison'] = {
            ['Default'] = function(source, target, buff)
                local duration = buff.EndTime - Game.GetTime()
                local rawDmg = spellDamages['Cassiopeia'][SpellSlots.W]['Default'](source, target).RawMagical
                return { RawMagical = rawDmg * duration }
            end
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.3] Chogath                                                                        |
--| Last Update: 11.03.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Chogath"] then
    spellDamages["Chogath"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({80, 135, 190, 245, 300}, lvl) + source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({75, 125, 175, 225, 275}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local feastBuff = source:GetBuff("feast")
                local stacks = feastBuff and feastBuff.Count or 0
                local baseDmg = 10 + 12 * lvl + (source.TotalAP * 0.3)
                local pctDmg = 0.03 + (stacks > 0 and 0.005 * stacks or 0)
                local rawDmg = baseDmg + (pctDmg * target.MaxHealth)
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local baseDmg = target.IsMinion and 1000 or GetDamageByLvl({300, 475, 650}, lvl)
                local rawDmg = baseDmg + 0.5 * source.TotalAP + 0.1 * source.BonusHealth
                return { RawTrue = rawDmg }
            end,
        },
    }

    spellData['Chogath'] = {
        ['Rupture'] = {
            ['Default'] = spellDamages['Chogath'][SpellSlots.Q]['Default'],
        },
        ['FeralScream'] = {
            ['Default'] = spellDamages['Chogath'][SpellSlots.W]['Default'],
        },
        ['Feast'] = {
            ['Default'] = spellDamages['Chogath'][SpellSlots.R]['Default'],
        }
    }

    dynamicPassiveDamages["Chogath"] = {
        [1] = {
            Name = "Chogath",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if aiTarget and source:GetBuff("vorpalspikes") then
                    local totalDmg = spellDamages.Chogath[SpellSlots.E].Default(source, target).RawMagical
                    res.FlatMagical = res.FlatMagical + totalDmg
                end
            end
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Corki                                                                          |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Corki"] then
    spellDamages["Corki"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({75, 120, 165, 210, 255}, lvl) + 0.7 * source.BonusAD + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({15, 22.5, 30, 37.5, 45}, lvl) + 0.1 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({7.5, 10.625, 13.75, 16.875, 20}, lvl) + 0.1 * source.BonusAD
                local physicalDmg = rawDmg / 2
                local magicalDmg = rawDmg / 2
                return { RawPhysical = physicalDmg, RawMagical = magicalDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local adRatio = GetDamageByLvl({0.15, 0.45, 0.75}, lvl)
                local rawDmg = GetDamageByLvl({90, 125, 160}, lvl) + adRatio * source.TotalAD + 0.2 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local adRatio = GetDamageByLvl({0.3, 0.90, 1.5}, lvl)
                local rawDmg = GetDamageByLvl({180, 250, 320}, lvl) + adRatio * source.TotalAD + 0.4 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Corki'] = {
        ['PhosphorusBomb'] = {
            ['Default'] = spellDamages['Corki'][SpellSlots.Q]['Default'],
        },
        ['MissileBarrageMissile'] = {
            ['Default'] = spellDamages['Corki'][SpellSlots.R]['Default'],
        },
        ['MissileBarrageMissile2'] = {
            ['Default'] = spellDamages['Corki'][SpellSlots.R]['Empowered'],
        },
        ['Corki_Base_W_tar'] = {
            ['Default'] = spellDamages['Corki'][SpellSlots.W]['Default'],
        },
        ['Corki_Base_W_Loaded_tar'] = {
            ['Default'] = spellDamages['Corki'][SpellSlots.W]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.6] Darius                                                                          |
--| Last Update: 09.07.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Darius"] then
    spellDamages["Darius"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local adRatio = GetDamageByLvl({1, 1.1, 1.2, 1.3, 1.4}, lvl)
                local rawDmg = GetDamageByLvl({50, 80, 110, 140, 170}, lvl) + adRatio * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({1.4, 1.45, 1.5, 1.55, 1.6}, lvl)
                return { RawPhysical = source.TotalAD * rawDmg, ApplyOnHit = true }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local buff = target:GetBuff("dariushemo")
                local stacks = buff and buff.Count or 0
                local buffDamageMod = 0.2 * stacks
                local rawDmg = GetDamageByLvl({125, 250, 375}, lvl) + 0.75 * source.BonusAD
                return { RawTrue = rawDmg + (rawDmg * buffDamageMod) }
            end,
        },
    }

    spellData['Darius'] = {
        ['DariusCleave'] = {
            ['Default'] = spellDamages['Darius'][SpellSlots.Q]['Default'],
        },
        ['DariusExecute'] = {
            ['Default'] = spellDamages['Darius'][SpellSlots.R]['Default'],
        }
    }

    staticPassiveDamages["Darius"] = {
        [1] = {
            Name = "Darius",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("DariusNoxianTacticsONH") then
                    local wLvl = source:GetSpell(SpellSlots.W).Level
                    res.FlatPhysical = res.FlatPhysical + (0.35 + 0.05 * wLvl) * source.TotalAD
                end
            end,
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.10] Diana                                                                          |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Diana"] then
    spellDamages["Diana"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({60, 95, 130, 165, 200}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({18, 30, 42, 54, 66}, lvl) + 0.15 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({50, 760, 90, 110, 130}, lvl) + 0.45 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({200, 300, 400}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["DamagePerChampion"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({35, 60, 85}, lvl) + 0.15 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Diana'] = {
        ['DianaArc'] = {
            ['Default'] = spellDamages['Diana'][SpellSlots.Q]['Default'],
        },
        ['DianaQ'] = {
            ['Default'] = spellDamages['Diana'][SpellSlots.Q]['Default'],
        },
        ['DianaTeleport'] = {
            ['Default'] = spellDamages['Diana'][SpellSlots.E]['Default'],
        },
    }

    for i = 1, 5 do
        spellData['Diana']['Diana_Base_R_Hit_' .. i] = {
            ['Default'] = function(source, target)
                local baseDmg = spellDamages['Diana'][SpellSlots.R]['Default'](source, target).RawMagical
                local damagePerChampion = spellDamages['Diana'][SpellSlots.R]['DamagePerChampion'](source, target).RawMagical
                return { RawMagical = baseDmg + (damagePerChampion * i) }
            end
        }
    end

    staticPassiveDamages["Diana"] = {
        [1] = {
            Name = "Diana",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("dianaarcready") then
                    local baseDmg = GetDamageByLvl({20, 25, 30, 35, 40, 55, 65, 75, 85, 95, 120, 135, 150, 165, 180, 210, 230, 250}, source.Level)
                    res.FlatMagical = res.FlatMagical + (baseDmg + source.TotalAP * 0.5)
                end
            end,
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.10] Draven                                                                         |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Draven"] then
    spellDamages["Draven"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local baseDmg = 40 + 5 * lvl
                local adDmg = 0.65 + 0.10 * lvl
                local rawDmg = baseDmg + adDmg * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({75, 110, 145, 180, 215}, lvl) + 0.5 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local adRatio = GetDamageByLvl({1.1, 1.3, 1.5}, lvl)
                local rawDmg = GetDamageByLvl({175, 275, 375}, lvl) + adRatio * source.BonusAD
                local executionDmg = 0 -- //TODO: Get Threshold from Draven Passive buff
                if (rawDmg + executionDmg) >= source.Health then
                    return { RawPhysical = rawDmg + executionDmg }
                end
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Draven'] = {
        ['DravenDoubleShot'] = {
            ['Default'] = spellDamages['Draven'][SpellSlots.E]['Default'],
        },
        ['DravenRCast'] = {
            ['Default'] = spellDamages['Draven'][SpellSlots.R]['Default'],
        },
        ['DravenRDoublecast'] = {
            ['Default'] = spellDamages['Draven'][SpellSlots.R]['Default'],
        },
    }

    staticPassiveDamages["Draven"] = {
        [1] = {
            Name = "Draven",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("dravenspinningattack") then
                    local dmg = spellDamages.Draven[SpellSlots.Q].Default(source).RawPhysical
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.24] DrMundo                                                                         |
--| Last Update: 15.12.2021                                                                 |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["DrMundo"] then
    spellDamages["DrMundo"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local minDmg = GetDamageByLvl({80, 135, 190, 245, 300}, lvl)
                local hpDmg = GetDamageByLvl({0.20, 0.225, 0.25, 0.275, 0.30}, lvl) * target.Health
                local rawDmg = max(minDmg, hpDmg)
                if target.IsMonster then 
                    rawDmg = min(rawDmg, GetDamageByLvl({350, 425, 500, 575, 650}, lvl))
                end
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({20, 35, 50, 65, 80}, lvl)
                return { RawMagical = rawDmg + source.BonusHealth*0.07}
            end,
            ["DamagePerSecond"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({5, 8.75, 12.5, 16.25, 20}, lvl)
                return { RawMagical = rawDmg * 4 }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = -5 + 10 * lvl + 0.07 * source.BonusHealth
                local missingHealth = math.min(1 - source.HealthPercent, 0.4) * 1.5
                rawDmg = rawDmg + rawDmg * missingHealth
                if target.IsMonster then
                    rawDmg = rawDmg * 2
                elseif target.IsLaneMinion then
                    rawDmg = rawDmg * 1.4
                end
                return { RawPhysical = rawDmg, ApplyOnHit = true }
            end,
        }
    }

    spellData['DrMundo'] = {
        ['DrMundoQ'] = {
            ['Default'] = spellDamages['DrMundo'][SpellSlots.Q]['Default'],
        },  
    }

    dynamicPassiveDamages["DrMundo"] = {
        [1] = {
            Name = "DrMundo",
            Func = function(res, source, target)
                if source:GetBuff("DrMundoE") then
                    local dmg = spellDamages["DrMundo"][SpellSlots.E]["Default"](source, target).RawPhysical
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.17] Ekko                                                                           |
--| Last Update: 25.08.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Ekko"] then
    spellDamages["Ekko"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({60, 75, 90, 105, 120}, lvl) + 0.3 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["WayBack"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({40, 65, 90, 115, 140}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({50, 75, 100, 125, 150}, lvl) + 0.4 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 300, 450}, lvl) + 1.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    dynamicPassiveDamages["Ekko"] = {
        [1] = {
            Name = "Ekko",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end

                local buff = aiTarget:GetBuff("ekkostacks")
                if buff and buff.Count == 2 then
                    local dmg = GetDamageByLvl({30, 40, 50, 60, 70, 80, 85, 90, 95, 100, 105, 110, 115, 120, 125, 130, 135, 140}, source.Level)
                    local totalDmg = (dmg + 0.8 * source.TotalAP)
                    if target.IsMonster then
                        res.FlatMagical = res.FlatMagical + (totalDmg * 3)
                    else
                        res.FlatMagical = res.FlatMagical + totalDmg
                    end
                end
            end
        },
        [2] = {
            Name = "Ekko",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end

                local wLvl = source:GetSpell(SpellSlots.W).Level
                if wLvl > 0 and aiTarget.HealthPercent < 0.3 then
                    local missingHealth = aiTarget.MaxHealth - aiTarget.Health
                    local dmg = (0.03 + 0.03 * (source.TotalAP / 100)) * missingHealth
                    dmg = dmg < 15 and 15 or dmg
                    dmg = aiTarget.IsMinion and dmg > 150 and 150 or dmg
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end
        },
        [3] = {
            Name = "Ekko",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end

                if source:GetBuff("ekkoeattackbuff") then
                    local eLvl = source:GetSpell(SpellSlots.E).Level
                    res.FlatMagical = res.FlatMagical + (25 + 25 * eLvl + 0.4 * source.TotalAP)
                end
            end
        },
    }

    spellData['Ekko'] = {
        ['EkkoQ'] = {
            ['Default'] = spellDamages['Ekko'][SpellSlots.Q]['Default'],
        }, 
        ['EkkoQReturn'] = {
            ['Default'] = spellDamages['Ekko'][SpellSlots.Q]['WayBack'],
        },
        ['EkkoR'] = {
            ['Default'] = spellDamages['Ekko'][SpellSlots.R]['Default'],
        },   
        ['EkkoEAttack'] = {
            ['Default'] = function(source, target)
                local baseDmg = spellDamages['Ekko'][SpellSlots.E]['Default'](source, target).RawMagical
                local attackDmg = DamageLib.GetAutoAttackDamage(source, target, true)
                return { RawMagical = baseDmg + attackDmg }
            end,
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.11] Elise                                                                          |
--| Last Update: 13.06.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Elise"] then
    spellDamages["Elise"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local baseDmg = GetDamageByLvl({40, 70, 100, 130, 160}, lvl)
                local hpDmg = (0.04 + (0.03 * (source.TotalAP / 100))) * target.Health
                local rawDmg = baseDmg + hpDmg
                return { RawMagical = rawDmg }
            end,
            ["SpiderForm"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local baseDmg = GetDamageByLvl({70, 105, 140, 175, 210}, lvl)
                local hpDmg = (0.08 + (0.03 * (source.TotalAP / 100))) * (target.MaxHealth - target.Health)
                local rawDmg = baseDmg + hpDmg
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({60, 105, 150, 195, 240}, lvl) + 0.95 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }
    -- //TODO Add Elise Passive (Spider Form)

    spellData['Elise'] = {
        ['EliseHumanQ'] = {
            ['Default'] = spellDamages['Elise'][SpellSlots.Q]['Default'],
        }, 
        ['EliseSpiderQCast'] = {
            ['Default'] = spellDamages['Elise'][SpellSlots.Q]['SpiderForm'],
        }, 
        ['Elise_Base_W_volatile_cas'] = {
            ['Default'] = spellDamages['Elise'][SpellSlots.W]['Default'],
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.24] Evelynn                                                                        |
--| Last Update: 15.12.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Evelynn"] then
    spellDamages["Evelynn"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({25, 30, 35, 40, 45}, lvl) + 0.3 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["BonusDamage"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({10, 20, 30, 40, 50}, lvl) + 0.25 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["SecondCast"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({25, 30, 35, 40, 45}, lvl) + 0.3 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({250, 300, 350, 40, 450}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local baseDmg = GetDamageByLvl({55, 70, 85, 100, 115}, lvl)
                local hpDmg = (0.04 + (0.025 * (source.TotalAP / 100))) * target.MaxHealth
                local rawDmg = baseDmg + hpDmg
                return { RawMagical = rawDmg, ApplyOnHit = true }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local baseDmg = GetDamageByLvl({75, 100, 125, 150, 175}, lvl)
                local hpDmg = (0.03 + (0.015 * (source.TotalAP / 100))) * target.MaxHealth
                local rawDmg = baseDmg + hpDmg
                return { RawMagical = rawDmg, ApplyOnHit = true }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({125, 250, 375}, lvl) + 0.75 * source.TotalAP
                if target.HealthPercent < 0.3 then
                    rawDmg = rawDmg + (rawDmg * 1.4)
                end
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Evelynn'] = {
        ['EvelynnQ'] = {
            ['Default'] = spellDamages['Evelynn'][SpellSlots.Q]['Default'],
        }, 
        ['EvelynnQ2'] = {
            ['Default'] = spellDamages['Evelynn'][SpellSlots.Q]['SecondCast'],
        }, 
        ['EvelynnE'] = {
            ['Default'] = spellDamages['Evelynn'][SpellSlots.E]['Default'],
        }, 
        ['EvelynnE2'] = {
            ['Default'] = spellDamages['Evelynn'][SpellSlots.E]['Empowered'],
        }, 
        ['EvelynnR'] = {
            ['Default'] = spellDamages['Evelynn'][SpellSlots.R]['Default'],
        }, 
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.3] Ezreal                                                                         |
--| Last Update: 11.03.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Ezreal"] then
    spellDamages["Ezreal"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({20, 45, 70, 95, 120}, lvl) + 1.3 * source.TotalAD + 0.15 * source.TotalAP
                return { RawPhysical = rawDmg, ApplyOnHit = true, ApplyOnAttack = true }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local apRatio = GetDamageByLvl({0.7, 0.75, 0.8, 0.85, 0.9}, lvl)
                local rawDmg = GetDamageByLvl({80, 135, 190, 245, 300}, lvl) + 0.6 * source.BonusAD + apRatio * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({80, 130, 180, 230, 280}, lvl) + 0.5 * source.BonusAD + 0.75 * source.TotalAP
                return { RawMagical = rawDmg, ApplyPassives = true }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({350, 500, 650}, lvl) + source.BonusAD + 0.9 * source.TotalAP
                return { RawPhysical = rawDmg, ApplyPassives = true }
            end,
        },
    }

    spellData['Ezreal'] = {
        ['EzrealQ'] = {
            ['Default'] = spellDamages['Ezreal'][SpellSlots.Q]['Default'],
        },
        ['EzrealW'] = {
            ['Default'] = spellDamages['Ezreal'][SpellSlots.W]['Default'],
        },
        ['EzrealR'] = {
            ['Default'] = spellDamages['Ezreal'][SpellSlots.R]['Default'],
        },
        ['EzrealEMissile'] = {
            ['Default'] = spellDamages['Ezreal'][SpellSlots.E]['Default'],
        }
    }

    dynamicPassiveDamages["Ezreal"] = {
        [1] = {
            Name = "Ezreal",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if aiTarget and aiTarget:GetBuff("ezrealwattach") then
                    local lvl = source:GetSpell(SpellSlots.W).Level
                    local dmg = (25 + 55 * lvl) + 0.6 * source.BonusAD + (0.65 + 0.05 * lvl) * source.TotalAP
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end,
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] FiddleSticks                                                                   |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["FiddleSticks"] then
    spellDamages["FiddleSticks"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = (GetDamageByLvl({0.06, 0.07, 0.08, 0.09, 0.10}, lvl) + (0.02 * (source.TotalAP / 100))) * target.Health
                return { RawMagical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = (GetDamageByLvl({0.12, 0.14, 0.16, 0.18, 0.20}, lvl) + (0.04 * (source.TotalAP / 100))) * target.Health
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({15, 22.5, 30, 37.5, 45}, lvl) + 0.0875 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({70, 105, 140, 175, 210}, lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({31.25, 56.25, 81.25}, lvl) + 0.1125 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['FiddleSticks'] = {
        ['FiddleSticksQMissileNoFear'] = {
            ['Default'] = spellDamages['FiddleSticks'][SpellSlots.Q]['Default'],
        },
        ['FiddleSticksQMissileFear'] = {
            ['Default'] = spellDamages['FiddleSticks'][SpellSlots.Q]['Empowered'],
        },
        ['FiddleSticksWCosmeticMissileBig'] = {
            ['Default'] = spellDamages['FiddleSticks'][SpellSlots.W]['Default'],
        },
        ['FiddleSticks_Base_R_Tar'] = {
            ['Default'] = spellDamages['FiddleSticks'][SpellSlots.R]['Default'],
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Fiora                                                                          |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Fiora"] then
    spellDamages["Fiora"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local adRatio = GetDamageByLvl({0.95, 1, 1.05, 1.1, 1.15}, lvl)
                local rawDmg = GetDamageByLvl({70, 80, 90, 100, 110}, lvl) + adRatio * source.BonusAD
                return { RawPhysical = rawDmg, ApplyOnHit = true }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({110, 150, 190, 230, 270}, lvl) + source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = source.TotalAD + (source.TotalAD * (0.5 + 0.1 * lvl))
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Fiora'] = {
        ['FioraW'] = {
            ['Default'] = spellDamages['Fiora'][SpellSlots.W]['Default'],
        },
    }

    staticPassiveDamages["Fiora"] = {
        [1] = {
            Name = "Fiora",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("fiorae2") then
                    local eLvl = source:GetSpell(SpellSlots.E).Level
                    local dmg = spellDamages.Fiora[SpellSlots.E].Default(source).RawPhysical
                    res.FlatPhysical = res.FlatPhysical + (dmg - source.TotalAD)
                end
            end,
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.19] Fizz                                                                           |
--| Last Update: 22.09.2021                                                               |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Fizz"] then
    spellDamages["Fizz"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({10, 25, 40, 55, 70}, lvl) + 0.55 * source.TotalAP
                return { RawMagical = rawDmg + source.TotalAD, ApplyOnHit = true }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({50, 70, 90, 110, 130}, lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({70, 120, 170, 220, 270}, lvl) + 0.75 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 250, 350}, lvl) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["SecondForm"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({225, 325, 425}, lvl) + 1.00 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["ThirdForm"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({300, 400, 500}, lvl) + 1.2 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Fizz'] = {
        ['FizzQ'] = {
            ['Default'] = spellDamages['Fizz'][SpellSlots.Q]['Default'],
        },
        ['FizzR'] = {
            ['Default'] = spellDamages['Fizz'][SpellSlots.R]['ThirdForm'],
        },
        ['fizzwdot'] = {
            ['Default'] = function(source, target, buff)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local duration = buff.EndTime - Game.GetTime()
                local rawDmg = GetDamageByLvl({3.33, 5, 6.67, 8.33, 10}, lvl) + 0.0667 * source.TotalAP
                return { RawMagical = rawDmg * duration }
            end
        },
        ['fizzrbomb'] = {
            ['Default'] = spellDamages['Fizz'][SpellSlots.R]['ThirdForm'],
        },
    }

    staticPassiveDamages["Fizz"] = {
        [1] = {
            Name = "Fizz",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("fizzw") then
                    local wLvl = source:GetSpell(SpellSlots.W).Level
                    res.FlatMagical = res.FlatMagical + (30 + 20 * wLvl + 0.5 * source.TotalAP)
                end
            end
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Galio                                                                          |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Galio"] then
    spellDamages["Galio"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({70, 105, 140, 175, 210}, lvl) + 0.75 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["DamagePerSecond"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = (0.08 + (0.0266 * (source.TotalAP / 100)) * target.MaxHealth) * 2
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({20, 35, 50, 65, 80}, lvl) + 0.3 * source.TotalAP
                local buff = source:GetBuff("galiow")
                local duration = buff and (buff.Duration - (buff.DurationLeft - 1)) or 0
                local addDmg = min((0.25 * (duration / 0.25)), 2)
                return { RawMagical = rawDmg + (rawDmg * addDmg) }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({90, 130, 170, 210, 250}, lvl) + 0.9 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 250, 350}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Galio'] = {
        ['GalioQ'] = {
            ['Default'] = spellDamages['Galio'][SpellSlots.Q]['Default'],
        },
        ['GalioE'] = {
            ['Default'] = spellDamages['Galio'][SpellSlots.E]['Default'],
        },
        ['GalioR'] = {
            ['Default'] = spellDamages['Galio'][SpellSlots.R]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.7] Gangplank                                                                       |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Gangplank"] then
    spellDamages["Gangplank"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({20, 45, 70, 95, 120}, lvl) + source.TotalAD
                return { RawPhysical = rawDmg, ApplyOnHit = true, ApplyOnAttack = true }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({80, 105, 130, 155, 180}, lvl) + source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({40, 70, 100}, lvl) + 0.1 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Gangplank'] = {
        ['GangplankQProceed'] = {
            ['Default'] = spellDamages['Gangplank'][SpellSlots.Q]['Default'],
        },
        ['gangplankpassiveattackdot'] = {
            ['Default'] = function(source, target, buff)
                local lvl = source.Level
                local duration = buff.EndTime - Game.GetTime()
                local rawDmg = 4 + 1.5 * lvl + 0.1 * source.BonusAD
                return { RawTrue = rawDmg * duration }
            end
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.14] Garen                                                                          |
--| Last Update: 09.07.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Garen"] then
    spellDamages["Garen"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = source.TotalAD + (0 + 30 * lvl + 0.5 * source.TotalAD)
                return { RawPhysical = rawDmg, ApplyOnHit = true }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local adRatio = GetDamageByLvl({0.32, 0.34, 0.36, 0.38, 0.40}, lvl)
                local addDmg = GetDamageByLvl({0, 0.8, 1.6, 2.4, 3.2, 4, 4.8, 5.6, 6.4, 6.6, 6.8, 7, 7.2, 7.4, 7.6, 7.8, 8, 8.2}, source.Level)
                local rawDmg = GetDamageByLvl({4, 8, 12, 16, 20}, lvl) + addDmg + adRatio * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local hpDmg = GetDamageByLvl({0.25, 0.30, 0.35}, lvl) * (target.MaxHealth - target.Health)
                local rawDmg = GetDamageByLvl({150, 300, 450}, lvl) + hpDmg
                return { RawTrue = rawDmg }
            end,
        },
    }

    staticPassiveDamages["Garen"] = {
        [1] = {
            Name = "Garen",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("garenq") then
                    local dmg = spellDamages.Garen[SpellSlots.Q].Default(source)
                    res.FlatPhysical = res.FlatPhysical + (dmg.RawPhysical - source.TotalAD)
                end
            end
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.6] Gnar                                                                            |
--| Last Update: 19.03.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Gnar"] then
    spellDamages["Gnar"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({25, 70, 115, 160, 205}, lvl) + 1.15 * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = (-10 + 10 * lvl) + (source.TotalAP) + (0.04 + 0.02 * lvl) * target.MaxHealth
                if target.IsMonster then
                    local cappedDmg = 300 + source.TotalAP
                    rawDmg = min(rawDmg, cappedDmg)
                end
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({50, 85, 120, 155, 190}, lvl) + 0.06 * source.MaxHealth
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({200, 300, 400}, lvl) + 0.5 * source.BonusAD + source.TotalAP
                return { RawPhysical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({300, 450, 600}, lvl) + 0.75 * source.BonusAD + 1.5 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Gnar'] = {
        ['GnarQMissile'] = {
            ['Default'] = spellDamages['Gnar'][SpellSlots.Q]['Default'],
        },
        ['GnarQMissileReturn'] = {
            ['Default'] = spellDamages['Gnar'][SpellSlots.Q]['Default'],
        },
        ['GnarBigQMissile'] = {
            ['Default'] = spellDamages['Gnar'][SpellSlots.Q]['Default'],
        },
        ['GnarBigW'] = {
            ['Default'] = spellDamages['Gnar'][SpellSlots.W]['Default'],
        },
        ['GnarE'] = {
            ['Default'] = spellDamages['Gnar'][SpellSlots.E]['Default'],
        },
        ['GnarBigE'] = {
            ['Default'] = spellDamages['Gnar'][SpellSlots.E]['Default'],
        },
        ['GnarR'] = {
            ['Default'] = spellDamages['Gnar'][SpellSlots.R]['Empowered'],
        },
    }

    dynamicPassiveDamages["Gnar"] = {
        [1] = {
            Name = "Gnar",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end
                local buff = aiTarget:GetBuff("gnarwproc")
                if buff and buff.Count == 2 then
                    local dmg = spellDamages.Gnar[SpellSlots.W].Default(source, aiTarget)
                    res.FlatMagical = res.FlatMagical + dmg.RawMagical
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.11] Gragas                                                                          |
--| Last Update: 23.06.2022                                                                 |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Gragas"] then
    spellDamages["Gragas"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({80, 120, 160, 200, 240}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({20, 50, 80, 110, 140}, lvl) + 0.07 * target.MaxHealth + 0.8 * source.TotalAP
                if target.IsMonster then rawDmg = min(300, rawDmg) end
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({80, 125, 170, 215, 260}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({200, 300, 400}, lvl) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Gragas'] = {
        ['GragasQ'] = {
            ['Default'] = spellDamages['Gragas'][SpellSlots.Q]['Default'],
        },
        ['GragasE'] = {
            ['Default'] = spellDamages['Gragas'][SpellSlots.E]['Default'],
        },
        ['GragasR'] = {
            ['Default'] = spellDamages['Gragas'][SpellSlots.R]['Default'],
        },
    }

    dynamicPassiveDamages["Gragas"] = {
        [1] = {
            Name = "Gragas",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end

                if source:GetBuff("gragaswattackbuff") then
                    local dmg = spellDamages.Gragas[SpellSlots.W].Default(source, aiTarget)
                    res.FlatMagical = res.FlatMagical + dmg.RawMagical
                end
            end
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Graves                                                                         |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Graves"] then
    spellDamages["Graves"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({45, 60, 75, 90, 105}, lvl) + 0.8 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
            ["Detonation"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local adRatio = GetDamageByLvl({0.4, 0.7, 1, 1.3, 1.6}, lvl)
                local rawDmg = GetDamageByLvl({85, 120, 155, 190, 225}, lvl) + adRatio * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({60, 110, 160, 210, 260}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({250, 400, 550}, lvl) + 1.5 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Graves'] = {
        ['GravesQLineSpell'] = {
            ['Default'] = spellDamages['Graves'][SpellSlots.Q]['Default'],
        },
        ['GravesQReturn'] = {
            ['Default'] = spellDamages['Graves'][SpellSlots.Q]['Detonation'],
        },
        ['GravesSmokeGrenade'] = {
            ['Default'] = spellDamages['Graves'][SpellSlots.W]['Default'],
        },
        ['GravesChargeShot'] = {
            ['Default'] = spellDamages['Graves'][SpellSlots.R]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.5] Gwen                                                                           |
--| Last Update: 02.03.2022                                                               |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Gwen"] then
    spellDamages["Gwen"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local buff = source:GetBuff("GwenQ") 
                local count = buff and buff.Count or 1
                local normalScissor = GetDamageByLvl({8, 10.75, 13.5, 16.25, 19}, lvl) + 0.05 * source.TotalAP
                local lastScissor = GetDamageByLvl({40, 53.75, 67.5, 81.25, 95}, lvl) + 0.25 * source.TotalAP
                return { RawMagical = normalScissor * (count-1) + lastScissor }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local buff = source:GetBuff("GwenQ") 
                local count = buff and buff.Count or 1
                local normalScissor = GetDamageByLvl({8, 10.75, 13.5, 16.25, 19}, lvl) + 0.05 * source.TotalAP
                local lastScissor = GetDamageByLvl({40, 53.75, 67.5, 81.25, 95}, lvl) + 0.25 * source.TotalAP
                return { RawTrue = normalScissor * (count-1) + lastScissor }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local extraDmg = (0.01 + 0.008*(source.TotalAP/100)) * target.MaxHealth                
                local rawDmg = GetDamageByLvl({30, 55, 80}, lvl) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg + extraDmg }
            end,
            ["SecondCast"] = function(source, target)
                local rawDmg = spellDamages.Gwen[SpellSlots.R]["Default"](source, target)
                return { RawMagical = rawDmg.RawMagical*3 }
            end,
            ["ThirdCast"] = function(source, target)
                local rawDmg = spellDamages.Gwen[SpellSlots.R]["Default"](source, target)
                return { RawMagical = rawDmg.RawMagical*5 }
            end,
        },
    }

    staticPassiveDamages["Gwen"] = {
        [1] = {
            Name = "Gwen",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("GwenEAttackBuff") then
                    local lvl = source:GetSpell(SpellSlots.E).Level
                    local extraDmg = 5 + 5 * lvl + 0.08 * source.TotalAP
                    res.FlatPhysical = res.FlatPhysical + extraDmg
                end
            end
        }
    }

    dynamicPassiveDamages["Gwen"] = {
        [1] = {
            Name = "Gwen",
            Func = function(res, source, target)
                local extraDmg = (0.01 + 0.008*(source.TotalAP/100)) * target.MaxHealth
                if target.IsMinion then
                    if target.IsNeutral then
                        extraDmg = min(extraDmg, 10 + 0.15 * source.TotalAP)
                    elseif target.HealthPercent < 0.4 then
                        extraDmg = extraDmg + (8 + 22/17*(source.Level-1))
                    end
                end
                res.FlatMagical = res.FlatMagical + extraDmg
            end
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.9] Hecarim                                                                         |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Hecarim"] then
    spellDamages["Hecarim"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                -- //TODO: Add Rampage Bonus (Buff)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({60, 90, 120, 150, 180}, lvl) + 0.9 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({20, 30, 40, 50, 60}, lvl) + 0.2 * source.TotalAP
                return { RawMagical = rawDmg, ApplyOnHit = true }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 250, 350}, lvl) + source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Hecarim'] = {
        ['HecarimUlt'] = {
            ['Default'] = spellDamages['Hecarim'][SpellSlots.R]['Default'],
        },
    }

    staticPassiveDamages["Hecarim"] = {
        [1] = {
            Name = "Hecarim",
            Func = function(res, source, isMinionTarget)
                local buff = source:GetBuff("hecarimrampspeed")
                if buff then
                    local buffMult = buff.Count
                    local eLvl = source:GetSpell(SpellSlots.E).Level
                    local dmg = (15 + 15 * eLvl) + (0.55 * source.BonusAD)
                    res.FlatPhysical = res.FlatPhysical + (dmg * (buffMult / 100))
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.9] Heimerdinger                                                                    |
--| Last Update: 30.04.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Heimerdinger"] then
    spellDamages["Heimerdinger"] = {
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({50, 75, 100, 125, 150}, lvl) + 0.45 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({135, 180, 225}, lvl) + 0.45 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({60, 100, 140, 180, 220}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({100, 200, 300}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Heimerdinger'] = {
        --[[
        ['HeimerdingerQTurretBlast'] = {
            ['Default'] = spellDamages['Heimerdinger'][SpellSlots.Q]['Default'],
        },
        ['HeimerdingerQTurretBigBlast'] = {
            ['Default'] = spellDamages['Heimerdinger'][SpellSlots.Q]['Empowered'],
        },]]
        ['HeimerdingerE'] = {
            ['Default'] = spellDamages['Heimerdinger'][SpellSlots.E]['Default'],
        },
        ['HeimerdingerEUlt'] = {
            ['Default'] = spellDamages['Heimerdinger'][SpellSlots.E]['Empowered'],
        },
        ['HeimerdingerEUltBounce'] = {
            ['Default'] = spellDamages['Heimerdinger'][SpellSlots.E]['Empowered'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.4] Illaoi                                                                          |
--| Last Update: 16.02.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Illaoi"] then
    spellDamages["Illaoi"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = (GetDamageByLvl({0.1, 0.15, 0.2, 0.25, 0.3}, lvl) * source.TotalAD) + source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({0.03, 0.035, 0.04, 0.045, 0.05}, lvl) + (0.04 * (source.TotalAD / 100)) * target.MaxHealth
                return { RawPhysical = source.TotalAD + rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 250, 350}, lvl) + 0.5 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Illaoi'] = {
        ['IllaoiQ'] = {
            ['Default'] = spellDamages['Illaoi'][SpellSlots.Q]['Default'],
        },
        ['IllaoiR'] = {
            ['Default'] = spellDamages['Illaoi'][SpellSlots.R]['Default'],
        },
    }

    dynamicPassiveDamages["Illaoi"] = {
        [1] = {
            Name = "Illaoi",
            Func = function(res, source, target)
                if source:GetBuff("IllaoiW") then
                    local lvl = source:GetSpell(SpellSlots.W).Level
                    local bonusDmg = max(10+10*lvl, (0.025 + 0.005 * lvl + 0.0002 * source.TotalAD) * target.MaxHealth)
                    if not target.IsHero and bonusDmg > 300 then bonusDmg = 300 end
                    res.FlatMagical = res.FlatMagical + bonusDmg
                end
            end,
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.15] Irelia                                                                         |
--| Last Update: 28.07.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Irelia"] then
    spellDamages["Irelia"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({5, 25, 45, 65, 85}, lvl) + 0.6 * source.TotalAD
                if target.IsMinion then
                    local bonusDmg = 43 + 12*lvl
                    rawDmg = rawDmg + bonusDmg
                end
                return { RawPhysical = rawDmg, ApplyOnHit = true }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({10, 25, 40, 55, 70}, lvl) + 0.4 * source.TotalAD + 0.4 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({80, 125, 170, 215, 260}, lvl) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({125, 250, 375}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Irelia'] = {
        ['IreliaQ'] = {
            ['Default'] = spellDamages['Irelia'][SpellSlots.Q]['Default'],
        },
        ['IreliaR'] = {
            ['Default'] = spellDamages['Irelia'][SpellSlots.R]['Default'],
        },
    }

    staticPassiveDamages["Irelia"] = {
        [1] = {
            Name = "Irelia",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("ireliapassivestacksmax") then
                    res.FlatMagical = res.FlatMagical + (7 + 3 * source.Level) + source.BonusAD * 0.2
                end
            end,
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.7] Ivern                                                                           |
--| Last Update: 31.03.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Ivern"] then
    spellDamages["Ivern"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({80, 125, 170, 215, 260}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({30, 37.5, 45, 52.5, 60}, lvl) + 0.3 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({70, 90, 110, 130, 150}, lvl) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Ivern'] = {
        ['IvernQ'] = {
            ['Default'] = spellDamages['Ivern'][SpellSlots.Q]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.2] Janna                                                                           |
--| Last Update: 21.01.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Janna"] then
    spellDamages["Janna"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({60, 85, 110, 135, 160}, lvl) + 0.35 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local msRatio = source.Level <= 10 and 0.35 or 0.25
                local rawDmg = GetDamageByLvl({ 70, 100, 130, 160, 190}, lvl) + 0.5 * source.TotalAP + msRatio * source.MoveSpeed
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Janna'] = {
        ['HowlingGale'] = {
            ['Default'] = spellDamages['Janna'][SpellSlots.Q]['Default'],
        },
        ['SowTheWind'] = {
            ['Default'] = spellDamages['Janna'][SpellSlots.W]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] JarvanIV                                                                       |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["JarvanIV"] then
    spellDamages["JarvanIV"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({90, 130, 170, 210, 250}, lvl) + 1.2 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({80, 120, 160, 200, 240}, lvl) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({200, 325, 450}, lvl) + 1.5 * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['JarvanIV'] = {
        ['JarvanIVDragonStrike'] = {
            ['Default'] = spellDamages['JarvanIV'][SpellSlots.Q]['Default'],
        },
        ['JarvanIVDemacianStandard'] = {
            ['Default'] = spellDamages['JarvanIV'][SpellSlots.E]['Default'],
        },
        ['JarvanIVQE'] = {
            ['Default'] = spellDamages['JarvanIV'][SpellSlots.Q]['Default'],
        },
        ['JarvanIVCataclysm'] = {
            ['Default'] = spellDamages['JarvanIV'][SpellSlots.R]['Default'],
        },
    }

    dynamicPassiveDamages["JarvanIV"] = {
        [1] = {
            Name = "JarvanIV",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end

                if not aiTarget:GetBuff("jarvanivmartialcadencecheck") then
                    local dmg = aiTarget.Health * 0.08
                    res.FlatPhysical = res.FlatPhysical + min(400, max(20, dmg))
                end
            end
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.6] Jax                                                                             |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Jax"] then
    spellDamages["Jax"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({65, 105, 145, 185, 225}, lvl) + source.BonusAD + 0.6 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({50, 85, 120, 155, 190}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({55, 80, 105, 130, 155}, lvl) + 0.5 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({100, 140, 180}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Jax'] = {
        ['JaxLeapStrike'] = {
            ['Default'] = spellDamages['Jax'][SpellSlots.Q]['Default'],
        },
    }

    staticPassiveDamages["Jax"] = {
        [1] = {
            Name = "Jax",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("jaxempowertwo") then
                    local dmg = spellDamages.Jax[SpellSlots.W].Default(source)
                    res.FlatMagical = res.FlatMagical + dmg.RawMagical
                end
            end
        },
        [2] = {
            Name = "Jax",
            Func = function(res, source, isMinionTarget)
                local rLvl = source:GetSpell(SpellSlots.R).Level
                local buff = source:GetBuff("jaxrelentlessassaultas")
                if rLvl > 0 and buff then
                    local buffCount = JaxBuffData[source.Handle]
                    if buffCount and buffCount % 3 == 2 then
                        local dmg = spellDamages.Jax[SpellSlots.R].Default(source)
                        res.FlatMagical = res.FlatMagical + dmg.RawMagical
                    end
                end
            end
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Jayce                                                                          |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Jayce"] then
    spellDamages["Jayce"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({55, 95, 135, 175, 215, 255}, lvl) + 1.2 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
            ["RangeForm"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({55, 110, 165, 220, 275, 330}, lvl) + 1.2 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({77, 154, 231, 308, 385, 462}, lvl) + 1.68 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({25, 40, 55, 70, 85, 100}, lvl) + 0.25 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({0.08, 0.104, 0.128, 0.152, 0.176, 0.20}, lvl) * target.MaxHealth + source.BonusAD
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Jayce'] = {
        ['JayceShockBlast'] = {
            ['Default'] = spellDamages['Jayce'][SpellSlots.Q]['RangeForm'],
        },
        ['JayceQAccel'] = {
            ['Default'] = spellDamages['Jayce'][SpellSlots.Q]['Empowered'],
        },
        ['JayceToTheSkies'] = {
            ['Default'] = spellDamages['Jayce'][SpellSlots.Q]['Default'],
        },
        ['JayceThunderingBlow'] = {
            ['Default'] = spellDamages['Jayce'][SpellSlots.E]['Default'],
        },
    }

    staticPassiveDamages["Jayce"] = {
        [1] = {
            Name = "Jayce",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("jaycepassivemeleeattack") then
                    local dmg = GetDamageByLvl({25, 25, 25, 25, 25, 65, 65, 65, 65, 65, 105, 105, 105, 105, 105, 145, 145, 145}, source.Level)
                    res.FlatMagical = res.FlatMagical + (dmg + 0.25 * source.BonusAD)
                end
            end
        },
        [2] = {
            Name = "Jayce",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("jaycehypercharge") then
                    local wLvl = source:GetSpell(SpellSlots.W).Level
                    local mod = 1 - (0.62 + 0.08 * wLvl)
                    res.FlatPhysical = res.FlatPhysical - (source.TotalAD * mod)
                end
            end
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.25] Jhin                                                                           |
--| Last Update: 22.12.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Jhin"] then
    spellDamages["Jhin"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local adRatio = GetDamageByLvl({0.35, 0.425, 0.50, 0.575, 0.65}, lvl)
                local rawDmg = GetDamageByLvl({45, 70, 95, 120, 145}, lvl) + adRatio * source.TotalAD + 0.6 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({50, 85, 120, 155, 190}, lvl) + 0.5 * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({20, 80, 140, 200, 260}, lvl) + 1.2 * source.TotalAD + source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local addDamage = 0.03 * ((1 - target.HealthPercent) / 0.01)
                local rawDmg = GetDamageByLvl({50, 125, 200}, lvl) + 0.2 * source.TotalAD
                return { RawPhysical = rawDmg + (rawDmg * addDamage) }
            end,
        },
    }

    spellData['Jhin'] = {
        ['JhinW'] = {
            ['Default'] = spellDamages['Jhin'][SpellSlots.W]['Default'],
        },
        ['JhinE'] = {
            ['Default'] = spellDamages['Jhin'][SpellSlots.E]['Default'],
        },
        ['JhinE_Explosion'] = {
            ['Default'] = spellDamages['Jhin'][SpellSlots.E]['Default'],
        },
        ['JhinRShot'] = {
            ['Default'] = spellDamages['Jhin'][SpellSlots.R]['Default'],
        },
        ['JhinQ'] = {
            ['Default'] = spellDamages['Jhin'][SpellSlots.Q]['Default'],
        },
    }

    dynamicPassiveDamages["Jhin"] = {
        [1] = {
            Name = "Jhin",
            Func = function(res, source, target)
                if source:GetBuff("jhinpassiveattackbuff") then
                    res.CriticalHit = true
                    local missingHealthMod = (0.1 + 0.05 * min(3, ceil(source.Level/5)))
                    res.FlatPhysical = res.FlatPhysical + (target.MaxHealth - target.Health) * missingHealthMod
                end
            end,
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.10] Jinx                                                                           |
--| Last Update: 16.05.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Jinx"] then
    spellDamages["Jinx"] = {
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({10, 60, 110, 160, 210}, lvl) + 1.6 * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({70, 120, 170, 220, 270}, lvl) + source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level                
                
                local baseDamage = GetDamageByLvl({250, 350, 450}, lvl) + 1.5 * source.BonusAD
                local missingHealthDmg = (target.MaxHealth - target.Health) * GetDamageByLvl({0.25, 0.30, 0.35}, lvl)                
                if target.IsMonster then 
                    missingHealthDmg = min(missingHealthDmg, 800) 
                end
                
                local rawDmg = baseDamage + missingHealthDmg
                local travelMod = max(0.1, min(1, source:EdgeDistance(target) / 1700))
                return { RawPhysical = rawDmg + (rawDmg * travelMod) }
            end,
        },
    }

    spellData['Jinx'] = {
        ['JinxWMissile'] = {
            ['Default'] = spellDamages['Jinx'][SpellSlots.W]['Default'],
        },
        ['JinxR'] = {
            ['Default'] = spellDamages['Jinx'][SpellSlots.R]['Default'],
        },
        ['JinxE'] = {
            ['Default'] = spellDamages['Jinx'][SpellSlots.E]['Default'],
        },
    }

    staticPassiveDamages["Jinx"] = {
        [1] = {
            Name = "Jinx",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("JinxQ") then
                    res.FlatPhysical = res.FlatPhysical + 0.1 * source.TotalAD
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.8] Kaisa                                                                          |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Kaisa"] then
    spellDamages["Kaisa"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({40, 55, 70, 85, 100}, lvl) + 0.4 * source.BonusAD + 0.25 * source.TotalAP
                if target.IsMinion and target.HealthPercent < 0.35 then
                    rawDmg = rawDmg * 2
                end
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({30, 55, 80, 105, 130}, lvl) + 1.3 * source.TotalAD + 0.45 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    dynamicPassiveDamages["Kaisa"] = {
        [1] = {
            Name = "Kaisa",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end

                local lvl = source.Level                    
                local bonusDmg = GetDamageByLvl({4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 12, 12, 12, 14, 14, 14, 16, 16}, lvl) + source.TotalAP * 0.15
                local stacks = aiTarget:GetBuffCount("kaisapassivemarker")
                if stacks > 0 then
                    local stackDamage = GetDamageByLvl({1, 1, 1, 2.75, 2.75, 2.75, 2.75, 4.5, 4.5, 4.5, 4.5, 6.25, 6.25, 6.25, 6.25, 8, 8, 8}, lvl) * stacks
                    bonusDmg = bonusDmg + stackDamage + (source.TotalAP * (min(stacks, 4) * 0.025))
                    if stacks == 4 then
                        local extra = (0.15 + 0.05 * floor(source.TotalAP/100)) * (aiTarget.MaxHealth - aiTarget.Health)
                        if aiTarget.IsMonster and extra > 400 then extra = 400 end
                        bonusDmg = bonusDmg + extra
                    end
                end
                res.FlatMagical = res.FlatMagical + bonusDmg
            end
        },
    }

    spellData['Kaisa'] = {
        ['KaisaW'] = {
            ['Default'] = spellDamages['Kaisa'][SpellSlots.W]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.22] Kalista                                                                        |
--| Last Update: 04.11.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Kalista"] then
    spellDamages["Kalista"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({20, 85, 150, 215, 280}, lvl) + source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local adRatio = GetDamageByLvl({0.232, 0.2755, 0.319, 0.3625, 0.406}, lvl)
                local baseDmg = GetDamageByLvl({20, 30, 40, 50, 60}, lvl) + 0.7 * source.TotalAD
                local dmgPerSpear = GetDamageByLvl({10, 16, 22, 28, 34}, lvl) + adRatio * source.TotalAD
                local buff = target:GetBuff("kalistaexpungemarker")
                local stacks = buff and buff.Count or 0
                local rawDmg = baseDmg + dmgPerSpear * (stacks-1)
                
                local minion = target.AsMinion
                if minion and minion.IsEpicMinion then
                    rawDmg = rawDmg * 0.5
                end
                return { RawPhysical = rawDmg }
            end,
        },
    }

    staticPassiveDamages["Kalista"] = {
        [1] = {
            Name = "Kalista",
            Func = function(res, source, isMinionTarget)
                res.FlatPhysical = res.FlatPhysical - (0.1 * source.TotalAD)
            end,
        }
    }

    spellData['Kalista'] = {
        ['KalistaMysticShot'] = {
            ['Default'] = spellDamages['Kalista'][SpellSlots.Q]['Default'],
        },
    }

    dynamicPassiveDamages["Kalista"] = {
        [1] = {
            Name = "Kalista",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if aiTarget and aiTarget:GetBuff("kalistacoopstrikemarkally") then
                    local lvl = source:GetSpell(SpellSlots.W).Level
                    local passiveDamage = (0.13 + 0.01 * lvl) * target.MaxHealth

                    if target.IsMinion then
                        local health = target.Health
                        if health < 125 then
                            res.FlatMagical = res.FlatMagical + health
                            return
                        end
                        local maxDmg = (75 + 25 * lvl)
                        res.FlatMagical = res.FlatMagical + min(maxDmg, passiveDamage)
                        return
                    end
                    res.FlatMagical = res.FlatMagical + passiveDamage
                end
            end,
        },
        [2] = {
            Name = nil,
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                local b = aiTarget and aiTarget:GetBuff("kalistacoopstrikemarkbuff")
                if b and source:GetBuff("kalistacoopstrikeally") then
                    local Caster = b.Caster
                    if not Caster then return end

                    local lvl = source:GetSpell(SpellSlots.W).Level
                    local passiveDamage = (0.13 + 0.01 * lvl) * target.MaxHealth

                    if target.IsMinion then
                        if target.Health < 125 then
                            res.FlatMagical = res.FlatMagical + target.Health
                            return
                        end
                        local maxDmg = (75 + 25 * lvl)
                        res.FlatMagical = res.FlatMagical + min(maxDmg, passiveDamage)
                        return
                    end
                    res.FlatMagical = res.FlatMagical + passiveDamage
                end
            end,
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Karma                                                                          |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Karma"] then
    spellDamages["Karma"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({90, 135, 180, 225, 270}, lvl) + 0.4 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({90, 135, 180, 225, 270}, lvl) + 0.4 * source.TotalAP
                local addDamage = GetDamageByLvl({25, 75, 125, 175}, lvl) + 0.3 * source.TotalAP
                return { RawMagical = rawDmg + addDamage }
            end,
            ["Detonation"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({35, 140, 245, 350}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({40, 65, 90, 115, 140}, lvl) + 0.45 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Karma'] = {
        ['KarmaQ'] = {
            ['Default'] = spellDamages['Karma'][SpellSlots.Q]['Default'],
        },
        ['KarmaQMantra'] = {
            ['Default'] = spellDamages['Karma'][SpellSlots.Q]['Empowered'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.6] Karthus                                                                         |
--| Last Update: 19.03.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Karthus"] then
    spellDamages["Karthus"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({45, 62.5, 80, 97.5, 115}, lvl) + 0.35 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({7.5, 12.5, 17.5, 22.5, 27.5}, lvl) + 0.05 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({200, 350, 500}, lvl) + 0.75
                return { RawMagical = rawDmg }  
            end,
        },
    }

    spellData['Karthus'] = {
        ['KarthusLayWasteA1'] = {
            ['Default'] = spellDamages['Karthus'][SpellSlots.Q]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.8] Kassadin                                                                       |
--| Last Update: 24.12.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Kassadin"] then
    spellDamages["Kassadin"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({65, 95, 125, 155, 185}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({80, 105, 130, 155, 180}, lvl) + 0.85 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local baseDmg = GetDamageByLvl({80, 100, 120}, lvl) + 0.4 * source.TotalAP + 0.02 * source.MaxMana
                local dmgPerStack = GetDamageByLvl({40, 50, 60}, lvl) + 0.1 * source.TotalAP + 0.01 * source.MaxMana
                local buff = source:GetBuff("riftwalk")
                local stacks = buff and buff.Count or 0
                local rawDmg = baseDmg + dmgPerStack * stacks
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Kassadin'] = {
        ['ForcePulse'] = {
            ['Default'] = spellDamages['Kassadin'][SpellSlots.E]['Default'],
        },
        ['RiftWalk'] = {
            ['Default'] = spellDamages['Kassadin'][SpellSlots.R]['Default'],
        },
        ['NullLance'] = {
            ['Default'] = spellDamages['Kassadin'][SpellSlots.Q]['Default'],
        },
    }

    staticPassiveDamages["Kassadin"] = {
        [1] = {
            Name = "Kassadin",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("netherblade") then
                    local wLvl = source:GetSpell(SpellSlots.W).Level
                    res.FlatMagical = res.FlatMagical + (25 + 25 * wLvl + 0.8 * source.TotalAP)
                else
                    res.FlatMagical = res.FlatMagical + (20 + 0.1 * source.TotalAP)
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.12] Katarina                                                                       |
--| Last Update: 23.06.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Katarina"] then
    spellDamages["Katarina"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({75, 105, 135, 165, 195}, lvl) + 0.3 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({20, 35, 50, 65, 80}, lvl) + 0.4 * source.TotalAD + 0.25 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({25, 37.5, 50}, lvl) + 0.19 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Katarina'] = {
        ['KatarinaQ'] = {
            ['Default'] = spellDamages['Katarina'][SpellSlots.Q]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.10] Kayle                                                                          |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Kayle"] then
    spellDamages["Kayle"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({60, 100, 140, 180, 220}, lvl) + 0.6 * source.BonusAD + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({15, 20, 25, 30, 35}, lvl) + 0.1 * source.BonusAD + 0.2 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({200, 350, 500}, lvl) + source.BonusAD + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Kayle'] = {
        ['KayleQ'] = {
            ['Default'] = spellDamages['Kayle'][SpellSlots.Q]['Default'],
        },
        ['KayleR_Wrapper'] = {
            ['Default'] = spellDamages['Kayle'][SpellSlots.R]['Default'],
        },
        ['KayleE'] = {
            ['Default'] = spellDamages['Kayle'][SpellSlots.E]['Default'],
        },
    }

    staticPassiveDamages["Kayle"] = {
        [1] = {
            Name = "Kayle",
            Func = function(res, source, isMinionTarget)
                local eLvl = source:GetSpell(SpellSlots.E).Level
                if eLvl > 0 then
                    res.FlatMagical = res.FlatMagical + (10 + 5 * eLvl + 0.1 * source.BonusAD + 0.2 * source.TotalAP)
                end
            end
        },
        [2] = {
            Name = "Kayle",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("kayleenrage") then
                    local eLvl = source:GetSpell(SpellSlots.E).Level
                    res.FlatMagical = res.FlatMagical + GetDamageByLvl({[0]=15, 15, 20, 25, 30, 35}, eLvl) + 0.1 * source.BonusAD + 0.25 * source.TotalAP
                end
            end
        },
    }

    dynamicPassiveDamages["Kayle"] = {
        [1] = {
            Name = "Kayle",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end

                if source:GetBuff("kaylee") then
                    local eLvl = source:GetSpell(SpellSlots.E).Level
                    local missingHealth = aiTarget.MaxHealth - aiTarget.Health
                    local dmg = (0.075 + 0.005 * eLvl + 0.015 * (source.TotalAP / 100)) * missingHealth
                    dmg = aiTarget.IsMonster and min(400, dmg) or dmg
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Kayn                                                                           |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Kayn"] then
    spellDamages["Kayn"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({75, 95, 115, 135, 155}, lvl) + 0.65 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({90, 135, 180, 225, 270}, lvl) + 1.3 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 250, 350}, lvl) + 1.75 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Kayn'] = {
        ['KaynW'] = {
            ['Default'] = spellDamages['Kayn'][SpellSlots.W]['Default'],
        },
        ['KaynAssW'] = {
            ['Default'] = spellDamages['Kayn'][SpellSlots.W]['Default'],
        },  
        ['KaynR'] = {
            ['Default'] = spellDamages['Kayn'][SpellSlots.R]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.5] Kennen                                                                         |
--| Last Update: 02.03.2022                                                                 |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Kennen"] then
    spellDamages["Kennen"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({75, 120, 165, 210, 255}, lvl) + 0.75 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({60, 85, 110, 135, 160}, lvl) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({80, 120, 160, 200, 240}, lvl) + 0.8 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({40, 75, 110}, lvl) + 0.2 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Kennen'] = {
        ['KennenShurikenHurlMissile1'] = {
            ['Default'] = spellDamages['Kennen'][SpellSlots.Q]['Default'],
        },
    }

    dynamicPassiveDamages["Kennen"] = {
        [1] = {
            Name = "Kennen",
            Func = function(res, source, target)
                if target.IsStructure then return end
                if source:GetBuff("kennendoublestrikelive") then
                    local wLvl = source:GetSpell(SpellSlots.W).Level
                    local dmg = (25 + 10 * wLvl) + ((0.7 + 0.1 * wLvl) * source.BonusAD) + (0.35 * source.TotalAP)
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.22] Khazix                                                                         |
--| Last Update: 04.11.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Khazix"] then
    spellDamages["Khazix"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({60, 85, 110, 135, 160}, lvl) + 1.15 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({85, 115, 145, 175, 205}, lvl) + source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({65, 100, 135, 170, 205}, lvl) + 0.2 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Khazix'] = {
        ['KhazixW'] = {
            ['Default'] = spellDamages['Khazix'][SpellSlots.W]['Default'],
        },
        ['KhazixE'] = {
            ['Default'] = spellDamages['Khazix'][SpellSlots.E]['Default'],
        },
        ['KhazixELong'] = {
            ['Default'] = spellDamages['Khazix'][SpellSlots.E]['Default'],
        },
        ['KhazixQ'] = {
            ['Default'] = spellDamages['Khazix'][SpellSlots.Q]['Default'],
        },
        ['KhazixQLong'] = {
            ['Default'] = spellDamages['Khazix'][SpellSlots.Q]['Default'],
        },
    }

    staticPassiveDamages["Khazix"] = {
        [1] = {
            Name = "Khazix",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("Khazixpdamage") then
                    res.FlatMagical = res.FlatMagical + (8 + 6 * source.Level + 0.4 * source.BonusAD)
                end
            end,
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.9] Kindred                                                                         |
--| Last Update: 30.04.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Kindred"] then
    spellDamages["Kindred"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({60, 85, 110, 135, 160}, lvl) + 0.75 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local buff = source:GetBuff("kindredmarkofthekindredstackcounter")
                local stacks = buff and buff.Count or 0
                local hpDmg = (0.015 + (0.01 * stacks)) * target.Health
                local rawDmg = GetDamageByLvl({25, 30, 35, 40, 45}, lvl) + 0.2 * source.BonusAD + hpDmg
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local buff = source:GetBuff("kindredmarkofthekindredstackcounter")
                local stacks = buff and buff.Count or 0
                local hpDmg = (0.08 + (0.005 * stacks)) * (1 - target.HealthPercent)
                local rawDmg = GetDamageByLvl({80, 100, 120, 140, 160}, lvl) + 0.8 * source.BonusAD + hpDmg
                return { RawPhysical = source.TotalAD + rawDmg }
            end,
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Kled                                                                           |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Kled"] then
    spellDamages["Kled"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({30, 55, 80, 105, 130}, lvl) + 0.6 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
            ["Detonation"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({60, 110, 160, 210, 260}, lvl) + 1.2 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
            ["SecondForm"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({35, 50, 65, 80, 95}, lvl) + 0.8 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local hpDmg = GetDamageByLvl({0.045, 0.05, 0.055, 0.06, 0.065}, lvl) + (0.05 * (source.BonusAD / 100))
                local rawDmg = GetDamageByLvl({20, 30, 40, 50, 60}, lvl) + hpDmg * target.MaxHealth
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({35, 60, 85, 110, 135}, lvl) + 0.6 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = (GetDamageByLvl({0.04, 0.05, 0.06}, lvl) + (0.04 * (source.BonusAD / 100))) * target.MaxHealth
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Kled'] = {
        ['KledQ'] = {
            ['Default'] = spellDamages['Kled'][SpellSlots.Q]['Default'],
        },
        ['KledRiderQ'] = {
            ['Default'] = spellDamages['Kled'][SpellSlots.Q]['SecondForm'],
        },
        ['KledEDash'] = {
            ['Default'] = spellDamages['Kled'][SpellSlots.E]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.11] KogMaw                                                                         |
--| Last Update: 23.06.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["KogMaw"] then
    spellDamages["KogMaw"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({90, 140, 190, 240, 290}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local apMod = 0.01 / 100 * source.TotalAP
                local rawDmg = ((0.0225 + 0.0075 * lvl) + apMod) * target.MaxHealth
                if target.IsMinion then passiveDamage = min(passiveDamage, 100) end
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({75, 120, 165, 210, 255}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = 0
                local missingHealth = min((1 - target.HealthPercent), 0.6)
                local hpDmg = min(0.00833 * ((1 - target.HealthPercent) / 0.01), 0.5)
                local baseDmg = GetDamageByLvl({100, 140, 180}, lvl) + 0.65 * source.BonusAD + 0.35 * source.TotalAP
                if target.HealthPercent < 0.4 then
                    rawDmg = GetDamageByLvl({200, 280, 360}, lvl) + 1.3 * source.BonusAD + 0.7 * source.TotalAP
                else
                    rawDmg = baseDmg + baseDmg * hpDmg
                end
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['KogMaw'] = {
        ['KogMawQ'] = {
            ['Default'] = spellDamages['KogMaw'][SpellSlots.Q]['Default'],
        },
        ['KogMawVoidOozeMissile'] = {
            ['Default'] = spellDamages['KogMaw'][SpellSlots.E]['Default'],
        },
        ['KogMawLivingArtillery'] = {
            ['Default'] = spellDamages['KogMaw'][SpellSlots.R]['Default'],
        },
    }

    dynamicPassiveDamages["KogMaw"] = {
        [1] = {
            Name = "KogMaw",
            Func = function(res, source, target)
                if target.IsStructure then return end

                if source:GetBuff("KogMawBioArcaneBarrage") then
                    local lvl = source:GetSpell(SpellSlots.W).Level

                    local apMod = 0.01 / 100 * source.TotalAP
                    local passiveDamage = ((0.02 + 0.01 * lvl) + apMod) * target.MaxHealth
                    if target.IsMinion then passiveDamage = min(passiveDamage, 100) end

                    res.FlatMagical = res.FlatMagical + passiveDamage
                end
            end,
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.3] Leblanc                                                                         |
--| Last Update: 08.02.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Leblanc"] then
    spellDamages["Leblanc"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({65, 90, 115, 140, 165}, lvl) + 0.4 * source.TotalAP 
                local detonationDamage = spellDamages.Leblanc[SpellSlots.Q].Detonation(source, target).RawMagical             
                return { RawMagical = rawDmg + detonationDamage}
            end,
            ["SecondForm"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({70, 140, 210}, lvl) + 0.4 * source.TotalAP
                local detonationDamage = spellDamages.Leblanc[SpellSlots.Q].Detonation(source, target).RawMagical
                return { RawMagical = rawDmg + detonationDamage}
            end,
            ["Detonation"] = function(source, target)                
                if target:GetBuff("leblancqmark") then
                    local lvl = source:GetSpell(SpellSlots.Q).Level
                    return{ RawMagical = GetDamageByLvl({65, 90, 115, 140, 165}, lvl) + 0.4 * source.TotalAP }
                elseif target:GetBuff("leblancrqmark") then
                    local lvl = source:GetSpell(SpellSlots.R).Level
                    return{ RawMagical = GetDamageByLvl({70, 140, 210}, lvl) + 0.4 * source.TotalAP }
                end
                return { RawMagical = 0 }
            end,            
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({75, 110, 145, 180, 215}, lvl) + 0.6 * source.TotalAP
                local detonationDamage = spellDamages.Leblanc[SpellSlots.Q].Detonation(source, target).RawMagical
                return { RawMagical = rawDmg + detonationDamage}
            end,
            ["SecondForm"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 300, 450}, lvl) + 0.75 * source.TotalAP
                local detonationDamage = spellDamages.Leblanc[SpellSlots.Q].Detonation(source, target).RawMagical
                return { RawMagical = rawDmg + detonationDamage }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({50, 70, 90, 110, 130}, lvl) + 0.3 * source.TotalAP
                local detonationDamage = spellDamages.Leblanc[SpellSlots.Q].Detonation(source, target).RawMagical
                return { RawMagical = rawDmg + detonationDamage}
            end,
            ["SecondForm"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({70, 140, 210}, lvl) + 0.4 * source.TotalAP
                local detonationDamage = spellDamages.Leblanc[SpellSlots.Q].Detonation(source, target).RawMagical
                return { RawMagical = rawDmg + detonationDamage }
            end,
            ["Detonation"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({80, 120, 160, 200, 240}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target) 
                local delegate = spellData['Leblanc'][source:GetSpell(SpellSlots.R).Name]        
                if delegate then
                    return delegate['Default'](source, target)
                end                
                return { RawMagical = 0}
            end
        },
    }
    spellData['Leblanc'] = {
        ['LeblancQ'] = {
            ['Default'] = spellDamages['Leblanc'][SpellSlots.Q]['Default'],
        },
        ['LeblancRQ'] = {
            ['Default'] = spellDamages['Leblanc'][SpellSlots.Q]['SecondForm'],
        },
        ['LeblancW'] = {
            ['Default'] = spellDamages['Leblanc'][SpellSlots.W]['Default'],
        }, 
        ['LeblancRW'] = {
            ['Default'] = spellDamages['Leblanc'][SpellSlots.W]['SecondForm'],
        },
        ['LeblancE'] = {
            ['Default'] = spellDamages['Leblanc'][SpellSlots.E]['Default'],
        }, 
        ['LeblancRE'] = {
            ['Default'] = spellDamages['Leblanc'][SpellSlots.E]['SecondForm'],
        }, 
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.12] LeeSin                                                                         |
--| Last Update: 23.06.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["LeeSin"] then
    spellDamages["LeeSin"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({55, 80, 105, 130, 155}, lvl) + source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({100, 130, 160, 190, 220}, lvl) + source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({175, 400, 625}, lvl) + 2 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['LeeSin'] = {
        ['BlindMonkQOne'] = {
            ['Default'] = spellDamages['LeeSin'][SpellSlots.Q]['Default'],
        },
        ['LeeSinR_KickedUnit'] = {
            ['Default'] = spellDamages['LeeSin'][SpellSlots.R]['Default'],
        }, 
        ['BlindMonkRKick'] = {
            ['Default'] = spellDamages['LeeSin'][SpellSlots.R]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.11] Leona                                                                          |
--| Last Update: 13.06.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Leona"] then
    spellDamages["Leona"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({10, 35, 60, 85, 110}, lvl) + 0.3 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({45, 80, 115, 150, 185}, lvl) + 0.4 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({50, 90, 130, 170, 210}, lvl) + 0.4 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({100, 175, 250}, lvl) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Leona'] = {
        ['LeonaZenithBlade'] = {
            ['Default'] = spellDamages['Leona'][SpellSlots.E]['Default'],
        },
        ['LeonaSolarFlare'] = {
            ['Default'] = spellDamages['Leona'][SpellSlots.R]['Default'],
        },
    }

    staticPassiveDamages["Leona"] = {
        [1] = {
            Name = "Leona",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("leonashieldofdaybreak") then
                    local qLvl = source:GetSpell(SpellSlots.Q).Level
                    res.FlatMagical = res.FlatMagical + (-15 + 25 * qLvl + 0.3 * source.TotalAP)
                end
            end
        },
    }

    dynamicPassiveDamages["Leona"] = {
        [1] = {
            Name = nil,
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end

                local buff = aiTarget:GetBuff("leonasunlight")
                if buff then
                    if source.CharName == "Leona" then return end
                    local buffSource = buff.Source
                    buffSource = buffSource and buffSource.AsHero
                    if not buffSource then return end
                    res.FlatMagical = res.FlatMagical + (18 + 7 * buffSource.Level)
                end
            end,
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.7] Lillia                                                                         |
--| Last Update: 09.07.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Lillia"] then
    spellDamages["Lillia"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({35, 50, 65, 80, 95}, lvl) + 0.4 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({80, 100, 120, 140, 160}, lvl) + 0.35 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({70, 95, 120, 145, 170}, lvl) + 0.45 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({100, 150, 200}, lvl) + 0.4 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Lillia'] = {
        ['LilliaQ'] = {
            ['Default'] = spellDamages['Lillia'][SpellSlots.Q]['Default'],
        },
        ['LilliaW'] = {
            ['Default'] = spellDamages['Lillia'][SpellSlots.W]['Default'],
        },
        ['LilliaE'] = {
            ['Default'] = spellDamages['Lillia'][SpellSlots.E]['Default'],
        },
        ['LilliaE_Roll'] = {
            ['Default'] = spellDamages['Lillia'][SpellSlots.E]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.7] Lissandra                                                                       |
--| Last Update: 31.03.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Lissandra"] then
    spellDamages["Lissandra"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({80, 110, 140, 170, 200}, lvl) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({70, 105, 140, 175, 210}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({70, 105, 140, 175, 210}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 250, 350}, lvl) + 0.75 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Lissandra'] = {
        ['LissandraQMissile'] = {
            ['Default'] = spellDamages['Lissandra'][SpellSlots.Q]['Default'],
        },
        ['LissandraQShards'] = {
            ['Default'] = spellDamages['Lissandra'][SpellSlots.Q]['Default'],
        },
        ['LissandraEMissile'] = {
            ['Default'] = spellDamages['Lissandra'][SpellSlots.E]['Default'],
        },
        ['LissandraR'] = {
            ['Default'] = spellDamages['Lissandra'][SpellSlots.R]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.12] Lucian                                                                         |
--| Last Update: 23.06.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Lucian"] then
    spellDamages["Lucian"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local adRatio = GetDamageByLvl({0.6, 0.75, 0.9, 1.05, 1.2}, lvl)
                local rawDmg = GetDamageByLvl({95, 125, 155, 185, 215}, lvl) + adRatio * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({75, 110, 145, 180, 215}, lvl) + 0.9 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({15, 30, 45}, lvl) + 0.25 * source.TotalAD + 0.15 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Lucian'] = {
        ['LucianQ'] = {
            ['Default'] = spellDamages['Lucian'][SpellSlots.Q]['Default'],
        },
        ['LucianW'] = {
            ['Default'] = spellDamages['Lucian'][SpellSlots.W]['Default'],
        },
        ['LucianR'] = {
            ['Default'] = spellDamages['Lucian'][SpellSlots.R]['Default'],
        },
    }

    local loop = false
    dynamicPassiveDamages["Lucian"] = {
        [1] = {
            Name = "Lucian",
            Func = function(res, source, target)
                if not loop and source:GetBuff("lucianpassivebuff") then
                    loop = true
                    local mult = 1
                    if not target.IsMinion then
                        mult = source.Level <= 6 and 0.5 or source.Level <= 12 and 0.55 or 0.6
                    end
                    local aaDmg = DamageLib.GetAutoAttackDamage(source, target, true, nil, mult)
                    loop = false
                    res.FlatPhysical = res.FlatPhysical + aaDmg
                end
            end
        },
        [2] = {
            Name = "Lucian",
            Func = function(res, source, target)
                if source:GetBuff("lucianpassivedamagebuff") then
                    res.FlatMagical = res.FlatMagical + 14 + source.TotalAD * 0.2
                end
            end
        },        
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.25] Lulu                                                                           |
--| Last Update: 22.12.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Lulu"] then
    spellDamages["Lulu"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({70, 105, 140, 175, 210}, lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({80, 120, 160, 200, 240}, lvl) + 0.4 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Lulu'] = {
        ['LuluQ'] = {
            ['Default'] = spellDamages['Lulu'][SpellSlots.Q]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.10] Lux                                                                            |
--| Last Update: 16.05.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Lux"] then
    spellDamages["Lux"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({70, 120, 170,  220, 270}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({60, 110, 160, 210, 260}, lvl) + 0.65 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({300, 400, 500}, lvl) + source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Lux'] = {
        ['LuxLightBinding'] = {
            ['Default'] = spellDamages['Lux'][SpellSlots.Q]['Default'],
        },
        ['LuxLightStrikeKugel'] = {
            ['Default'] = spellDamages['Lux'][SpellSlots.E]['Default'],
        },
        ['LuxMaliceCannon'] = {
            ['Default'] = spellDamages['Lux'][SpellSlots.R]['Default'],
        },
    }

    dynamicPassiveDamages["Lux"] = {
        [1] = {
            Name = "Lux",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end

                local buff = aiTarget:GetBuff("luxilluminatingfraulein")
                if buff then
                    local dmg = (10 + 10 * source.Level) + 0.2 * source.TotalAP
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.12] Malphite                                                                       |
--| Last Update: 13.06.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Malphite"] then
    spellDamages["Malphite"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({70, 120, 170, 220, 270}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({30, 45, 60, 75, 90}, lvl) + 0.2 * source.TotalAP + 0.10 * source.Armor
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({60, 95, 130, 165, 200}, lvl) + 0.6 * source.TotalAP + 0.3 * source.Armor
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({200, 300, 400}, lvl) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Malphite'] = {
        ['UFSlash'] = {
            ['Default'] = spellDamages['Malphite'][SpellSlots.R]['Default'],
        },
        ['SeismicShard'] = {
            ['Default'] = spellDamages['Malphite'][SpellSlots.Q]['Default'],
        },
    }

    staticPassiveDamages["Malphite"] = {
        [1] = {
            Name = "Malphite",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("malphitethunderclap") then
                    local wLvl = source:GetSpell(SpellSlots.W).Level
                    local dmg = (15 + 15 * wLvl) + (0.2 * source.TotalAP) + (0.10 * source.Armor)
                    local coneDmg = (5 + 10 * wLvl) + (0.2 * source.TotalAP) + (0.15 * source.Armor)
                    res.FlatPhysical = res.FlatPhysical + dmg + coneDmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.14] Malzahar                                                                       |
--| Last Update: 09.07.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Malzahar"] then
    spellDamages["Malzahar"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({70, 105, 140, 175, 210}, lvl) + 0.55 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = 5 + 3.5 * source.Level + 10 + 2 * lvl + 0.4 * source.BonusAD + 0.2 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({80, 115, 150, 185, 220}, lvl) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local hpDmg = (GetDamageByLvl({0.1, 0.15, 0.2}, lvl) + (0.025 * (source.TotalAP / 100))) * target.MaxHealth
                local rawDmg = GetDamageByLvl({125, 200, 275}, lvl) + 0.8 * source.TotalAP + hpDmg
                return { RawMagical= rawDmg }
            end,
        },
    }

    spellData['Malzahar'] = {
        ['MalzaharQ'] = {
            ['Default'] = spellDamages['Malzahar'][SpellSlots.Q]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.22] Maokai                                                                         |
--| Last Update: 04.11.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Maokai"] then
    spellDamages["Maokai"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({60, 85, 110, 135, 160}, lvl) + 0.4 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({70, 95, 120, 145, 170}, lvl) + 0.4 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local hpDmg = (GetDamageByLvl({0.07, 0.0725, 0.075, 0.075, 0.08}, lvl) + (0.008 * (source.TotalAP / 100))) * target.MaxHealth
                local rawDmg = GetDamageByLvl({25, 50, 75, 100, 125}, lvl) + hpDmg
                return { RawMagical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local hpDmg = (GetDamageByLvl({0.07, 0.0725, 0.075, 0.075, 0.08}, lvl) + (0.008 * (source.TotalAP / 100))) * target.MaxHealth
                local rawDmg = GetDamageByLvl({25, 50, 75, 100, 125}, lvl) + hpDmg
                return { RawMagical = rawDmg * 2 }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 225, 300}, lvl) + 0.75 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Maokai'] = {
        ['MaokaiQ'] = {
            ['Default'] = spellDamages['Maokai'][SpellSlots.Q]['Default'],
        },
        ['MaokaiW'] = {
            ['Default'] = spellDamages['Maokai'][SpellSlots.W]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.11] MasterYi                                                                       |
--| Last Update: 23.06.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["MasterYi"] then
    spellDamages["MasterYi"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({30, 60, 90, 120, 150}, lvl) + 0.5 * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = (25 + 5 * lvl) + (0.35 * source.BonusAD)
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['MasterYi'] = {
        ['AlphaStrikeMissile'] = {
            ['Default'] = spellDamages['MasterYi'][SpellSlots.Q]['Default'],
        },
    }

    staticPassiveDamages["MasterYi"] = {
        [1] = {
            Name = "MasterYi",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("wujustylesuperchargedvisual") then
                    local eLvl = source:GetSpell(SpellSlots.E).Level
                    local dmg = (22 + 8 * eLvl) + (0.35 * source.BonusAD)
                    res.FlatTrue = res.FlatTrue + dmg
                end
            end
        }
    }

    local loop = false
    dynamicPassiveDamages["MasterYi"] = {
        [1] = {
            Name = "MasterYi",
            Func = function(res, source, target)
                if not loop and source:GetBuff("doublestrike") then
                    loop = true
                    local aaDmg = DamageLib.GetAutoAttackDamage(source, target, true, nil, 0.5)
                    loop = false
                    res.FlatPhysical = res.FlatPhysical + aaDmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] MissFortune                                                                    |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["MissFortune"] then
    spellDamages["MissFortune"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({20, 40, 60, 80, 100}, lvl) + source.TotalAD + 0.35 * source.TotalAP
                return { RawPhysical = rawDmg, ApplyOnHit = true, ApplyOnAttack = true }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({10, 14.375, 18.75, 23.125, 27.5}, lvl) + 0.1 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = 0.75 * source.TotalAD + 0.2 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['MissFortune'] = {
        ['MissFortuneScattershot'] = {
            ['Default'] = spellDamages['MissFortune'][SpellSlots.Q]['Default'],
        },
        ['MissFortuneBulletTime'] = {
            ['Default'] = spellDamages['MissFortune'][SpellSlots.R]['Default'],
        },
        ['MissFortuneRicochetShot'] = {
            ['Default'] = spellDamages['MissFortune'][SpellSlots.Q]['Default'],
        },
    }

    dynamicPassiveDamages["MissFortune"] = {
        [1] = {
            Name = "MissFortune",
            Func = function(res, source, target)
                local lastTarget = MissFortuneAttackData[source.Handle]
                if lastTarget and lastTarget == target.Handle then
                    return
                end
                local mod = GetDamageByLvl({0.5, 0.5, 0.5, 0.6, 0.6, 0.6, 0.7, 0.7, 0.8, 0.8, 0.9, 0.9, 1, 1, 1, 1, 1, 1}, source.Level)
                local minionMod = target.IsMinion and not target.IsMonster and 0.5 or 1
                res.FlatPhysical = res.FlatPhysical + (source.TotalAD * mod * minionMod)
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.7] MonkeyKing                                                                      |
--| Last Update: 14.06.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["MonkeyKing"] then
    spellDamages["MonkeyKing"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({20, 45, 70, 95, 120}, lvl) + 0.45 * source.BonusAD
                return { RawPhysical = rawDmg + source.TotalAD }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({80, 110, 140, 170, 200}, lvl) + source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({0.01, 0.015, 0.02}, lvl) * target.MaxHealth + 0.275 * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['MonkeyKing'] = {
        ['MonkeyKingNimbus'] = {
            ['Default'] = spellDamages['MonkeyKing'][SpellSlots.E]['Default'],
        },
    }

    staticPassiveDamages["MonkeyKing"] = {
        [1] = {
            Name = "MonkeyKing",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("monkeykingdoubleattack") then
                    local qLvl = source:GetSpell(SpellSlots.Q).Level
                    local dmg = (-5 + 25 * qLvl) + (0.45 * source.BonusAD)
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Mordekaiser                                                                    |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Mordekaiser"] then
    spellDamages["Mordekaiser"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local addDamage = GetDamageByLvl({75, 95, 115, 135, 155}, lvl)
                local rawDmg = GetDamageByLvl({5, 9, 13, 17, 21, 25, 29, 33, 37, 41, 51, 61, 71, 81, 91, 107, 123, 139}, source.Level) + addDamage + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({80, 95, 110, 125, 140}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Mordekaiser'] = {
        ['MordekaiserQ'] = {
            ['Default'] = spellDamages['Mordekaiser'][SpellSlots.Q]['Default'],
        },
        ['MordekaiserE'] = {
            ['Default'] = spellDamages['Mordekaiser'][SpellSlots.E]['Default'],
        },
    }

    staticPassiveDamages["Mordekaiser"] = {
        [1] = {
            Name = "Mordekaiser",
            Func = function(res, source, isMinionTarget)
                res.FlatMagical = res.FlatMagical + (0.4 * source.TotalAP)
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.25] Morgana                                                                        |
--| Last Update: 22.12.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Morgana"] then
    spellDamages["Morgana"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({80, 135, 190, 245, 300}, lvl) + 0.9 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({12, 22, 32, 42, 52}, lvl) + 0.14 * source.TotalAP
                local hpDmg = 0.017 * (0.01 * (1 - target.HealthPercent))
                return { RawMagical = rawDmg + rawDmg * hpDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 225, 300}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Morgana'] = {
        ['MorganaQ'] = {
            ['Default'] = spellDamages['Morgana'][SpellSlots.Q]['Default'],
        },
        ['MorganaW'] = {
            ['Default'] = spellDamages['Morgana'][SpellSlots.Q]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.4] Nami                                                                            |
--| Last Update: 16.02.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Nami"] then
    spellDamages["Nami"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({75, 130, 185, 240, 295}, lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({70, 110, 150, 190, 230}, lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({25, 40, 55, 70, 85}, lvl) + 0.2 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 250, 350}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Nami'] = {
        ['NamiQ'] = {
            ['Default'] = spellDamages['Nami'][SpellSlots.Q]['Default'],
        },
        ['NamiRMissile'] = {
            ['Default'] = spellDamages['Nami'][SpellSlots.R]['Default'],
        },
        ['NamiWEnemy'] = {
            ['Default'] = spellDamages['Nami'][SpellSlots.W]['Default'],
        },
    }

    staticPassiveDamages["Nami"] = {
        [1] = {
            Name = nil,
            Func = function(res, source, isMinionTarget)
                local buff = source:GetBuff("namie")
                if buff then
                    local buffSource = buff.Source
                    buffSource = buffSource and buffSource.AsHero
                    if not buffSource then return end
                    local eLvl = buffSource:GetSpell(SpellSlots.E).Level
                    res.FlatMagical = res.FlatMagical + (10 + 15 * eLvl + 0.2 * buffSource.TotalAP)
                end
            end,
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Nasus                                                                          |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Nasus"] then
    spellDamages["Nasus"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local stacksBuff = source:GetBuff("nasusqstacks")
                local stacks = stacksBuff and stacksBuff.Count or 0
                local rawDmg = (10 + 20 * lvl) + stacks
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({55, 95, 135, 175, 215}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["DamagePerSecond"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({11, 19, 27, 35, 43}, lvl) + 0.12 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = (GetDamageByLvl({0.03, 0.04, 0.05}, lvl) + (0.01 * (source.TotalAP / 100))) * target.MaxHealth
                rawDmg = min(rawDmg, 240)
                return { RawMagical = rawDmg }
            end,
        },
    }

    staticPassiveDamages["Nasus"] = {
        [1] = {
            Name = "Nasus",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("nasusq") then
                    local qLvl = source:GetSpell(SpellSlots.Q).Level
                    local stacksBuff = source:GetBuff("nasusqstacks")
                    local stacks = stacksBuff and stacksBuff.Count or 0
                    local dmg = (10 + 20 * qLvl) + stacks
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Nautilus                                                                       |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Nautilus"] then
    spellDamages["Nautilus"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({70, 115, 160, 205, 250}, lvl) + 0.9 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({15, 20, 25, 30, 35}, lvl) + 0.2 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({55, 85, 115, 145, 175}, lvl) + 0.3 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 275, 400}, lvl) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Nautilus'] = {
        ['NautilusAnchorDragMissile'] = {
            ['Default'] = spellDamages['Nautilus'][SpellSlots.Q]['Default'],
        },
        ['NautilusGrandLine'] = {
            ['Default'] = spellDamages['Nautilus'][SpellSlots.R]['Default'],
        },
    }

    dynamicPassiveDamages["Nautilus"] = {
        [1] = {
            Name = "Nautilus",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end

                local buff = aiTarget:GetBuff("nautiluspassivecheck")
                if not buff then
                    res.FlatPhysical = res.FlatPhysical + (2 + 6 * source.Level)
                end
            end
        }
    }

    staticPassiveDamages["Nautilus"] = {
        [1] = {
            Name = "Nautilus",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("nautiluspiercinggazeshield") then
                    local wLvl = source:GetSpell(SpellSlots.W).Level
                    local dmg = (10 + 5 * wLvl) + (0.2 * source.TotalAP)
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.7] Neeko                                                                           |
--| Last Update: 16.02.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Neeko"] then
    spellDamages["Neeko"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({80, 125, 170, 215, 260}, lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["SecondForm"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({40, 65, 90, 115, 140}, lvl) + 0.2 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({50, 80, 110, 140, 170}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({80, 115, 150, 185, 220}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({200, 425, 650}, lvl) + 1.3 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Neeko'] = {
        ['NeekoQ'] = {
            ['Default'] = spellDamages['Neeko'][SpellSlots.Q]['Default'],
        },
        ['NeekoE'] = {
            ['Default'] = spellDamages['Neeko'][SpellSlots.E]['Default'],
        },
        ['NeekoR'] = {
            ['Default'] = spellDamages['Neeko'][SpellSlots.R]['Default'],
        },
    }

    staticPassiveDamages["Neeko"] = {
        [1] = {
            Name = "Neeko",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("neekowpassiveready") then
                    local wLvl = source:GetSpell(SpellSlots.W).Level
                    local dmg = (30 + 20 * wLvl) + (0.6 * source.TotalAP)
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.25] Nidalee                                                                        |
--| Last Update: 22.12.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Nidalee"] then
    spellDamages["Nidalee"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({70, 90, 110, 130, 150}, lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["SecondForm"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local dmg = (-20 + 25 * lvl) + (0.75 * source.TotalAD) + (0.4 * source.TotalAP)
                local missingHealth = 1 - target.HealthPercent
                local rawDmg = dmg + (dmg * missingHealth)
                if target:GetBuff("nidaleepassivehunted") then
                    rawDmg = rawDmg + (rawDmg * 0.4)
                end
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({10, 20, 30, 40, 50}, lvl) + 0.05 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["SecondForm"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({60, 110, 160, 210}, lvl) + 0.3 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["SecondForm"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({80, 140, 200, 260}, lvl) + 0.45 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Nidalee'] = {
        ['JavelinToss'] = {
            ['Default'] = spellDamages['Nidalee'][SpellSlots.Q]['Default'],
        },
    }

    dynamicPassiveDamages["Nidalee"] = {
        [1] = {
            Name = "Nidalee",
            Func = function(res, source, target)
                if source.IsMelee and source:GetBuff("takedown") then
                    local aiTarget = target.AsAI
                    if not aiTarget then return end
                    local rLvl = source:GetSpell(SpellSlots.R).Level
                    local dmg = (-20 + 25 * rLvl) + (0.75 * source.TotalAD) + (0.4 * source.TotalAP)
                    local missingHealth = 1 - aiTarget.HealthPercent
                    local totalDmg = dmg + (dmg * missingHealth)
                    if aiTarget:GetBuff("nidaleepassivehunted") then
                        totalDmg = totalDmg + (totalDmg * 0.4)
                    end
                    res.FlatMagical = res.FlatMagical + (totalDmg - source.TotalAD)
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.2] Nocturne                                                                        |
--| Last Update: 21.01.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Nocturne"] then
    spellDamages["Nocturne"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({65, 110, 155, 200, 245}, lvl) + 0.85 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({80, 125, 170, 215, 260}, lvl) + source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 275, 400}, lvl) + 1.2 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Nocturne'] = {
        ['NocturneDuskbringer'] = {
            ['Default'] = spellDamages['Nocturne'][SpellSlots.Q]['Default'],
        },
        ['NocturneParanoia'] = {
            ['Default'] = spellDamages['Nocturne'][SpellSlots.R]['Default'],
        },
        ['NocturneParanoia2'] = {
            ['Default'] = spellDamages['Nocturne'][SpellSlots.R]['Default'],
        },
    }

    staticPassiveDamages["Nocturne"] = {
        [1] = {
            Name = "Nocturne",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("nocturneumbrablades") then
                    res.FlatPhysical = res.FlatPhysical + ((source.TotalAD * 0.2) * (isMinionTarget and 0.5 or 1))
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Nunu                                                                           |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Nunu"] then
    spellDamages["Nunu"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({60, 100, 140, 180, 220}, lvl) + 0.65 * source.TotalAP + 0.05 * source.BonusHealth
                if target.IsMinion then
                    rawDmg = GetDamageByLvl({340, 500, 660, 820, 980}, lvl)
                end
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({36, 45, 54, 63, 72}, lvl) + 0.3 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({20, 30, 40, 50, 60}, lvl) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["SecondForm"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({16, 24, 32, 40, 48}, lvl) + 0.06 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({625, 950, 1275}, lvl) + 2.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Nunu'] = {
        ['NunuQ'] = {
            ['Default'] = spellDamages['Nunu'][SpellSlots.Q]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.11] Olaf                                                                           |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Olaf"] then
    spellDamages["Olaf"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({70, 120, 170, 220, 270}, lvl) + source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({70, 115, 160, 205, 250}, lvl) + 0.5 * source.TotalAD
                return { RawTrue = rawDmg }
            end,
        },
    }

    spellData['Olaf'] = {
        ['OlafAxeThrowCast'] = {
            ['Default'] = spellDamages['Olaf'][SpellSlots.Q]['Default'],
        },
        ['OlafRecklessStrike'] = {
            ['Default'] = spellDamages['Olaf'][SpellSlots.E]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Orianna                                                                        |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Orianna"] then
    spellDamages["Orianna"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({60, 90, 120, 150, 180}, lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({60, 105, 150, 195, 240}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({60, 90, 120, 150, 180}, lvl) + 0.3 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({200, 275, 350}, lvl) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Orianna'] = {
        ['OrianaIzunaCommands'] = {
            ['Default'] = spellDamages['Orianna'][SpellSlots.Q]['Default'],
        },
        ['OrianaRedactCommand'] = {
            ['Default'] = spellDamages['Orianna'][SpellSlots.E]['Default'],
        },
        ['OrianaDetonateCommand'] = {
            ['Default'] = spellDamages['Orianna'][SpellSlots.R]['Default'],
        },
    }

    dynamicPassiveDamages["Orianna"] = {
        [1] = {
            Name = "Orianna",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end
                local dmg = 2 + ceil(source.Level / 3) * 8 + 0.15 * source.TotalAP
                local buff = aiTarget:GetBuff("oriannapstack")
                if buff then
                    dmg = dmg + (dmg * 0.2 * buff.Count)
                end
                res.FlatMagical = res.FlatMagical + dmg
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Ornn                                                                           |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Ornn"] then
    spellDamages["Ornn"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({20, 45, 70, 95, 120}, lvl) + 1.1 * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({0.12, 0.13, 0.14, 0.15, 0.16}, lvl) * target.MaxHealth
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({80, 125, 170, 215, 260}, lvl) + 0.4 * source.BonusArmor + 0.4 * source.BonusSpellBlock
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({125 / 175 / 225}, lvl) + 0.2 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Ornn'] = {
        ['OrnnQ'] = {
            ['Default'] = spellDamages['Ornn'][SpellSlots.Q]['Default'],
        },
        ['OrnnRWave'] = {
            ['Default'] = spellDamages['Ornn'][SpellSlots.R]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.25] Pantheon                                                                       |
--| Last Update: 22.12.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Pantheon"] then
    spellDamages["Pantheon"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({70, 100, 130, 160, 190}, lvl) + 1.15 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = 7.05 + 12.94 * source.Level + 1.15 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({60, 100, 140, 180, 220}, lvl) + source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({55, 105, 155, 205, 255}, lvl) + 1.5 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({55, 105, 155, 205, 255}, lvl) + 1.5 * source.BonusAD
                return { RawPhysical = rawDmg * 1.6 }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({300, 500, 700}, lvl) + source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Pantheon'] = {
        ['PantheonQTap'] = {
            ['Default'] = spellDamages['Pantheon'][SpellSlots.Q]['Default'],
        },
        ['PantheonQMissile'] = {
            ['Default'] = spellDamages['Pantheon'][SpellSlots.Q]['Empowered'],
        },
        ['PantheonE'] = {
            ['Default'] = spellDamages['Pantheon'][SpellSlots.E]['Default'],
        },
        ['PantheonEShieldSlam'] = {
            ['Default'] = spellDamages['Pantheon'][SpellSlots.E]['Empowered'],
        },
        ['PantheonR'] = {
            ['Default'] = spellDamages['Pantheon'][SpellSlots.R]['Default'],
        },
        ['PantheonW'] = {
            ['Default'] = spellDamages['Pantheon'][SpellSlots.W]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Poppy                                                                          |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Poppy"] then
    spellDamages["Poppy"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({40, 60, 80, 100, 120}, lvl) + 0.9 * source.BonusAD + 0.08 * target.MaxHealth
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({70, 110, 150, 190, 230}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({60, 80, 100, 120, 140}, lvl) + 0.5 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({200, 300, 400}, lvl) + 0.9 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Poppy'] = {
        ['PoppyQ'] = {
            ['Default'] = spellDamages['Poppy'][SpellSlots.Q]['Default'],
        },
        ['PoppyRSpellInstant'] = {
            ['Default'] = spellDamages['Poppy'][SpellSlots.R]['Default'],
        },
        ['PoppyRSpell'] = {
            ['Default'] = spellDamages['Poppy'][SpellSlots.R]['Default'],
        },
        ['PoppyE'] = {
            ['Default'] = spellDamages['Poppy'][SpellSlots.E]['Default'],
        },
    }

    staticPassiveDamages["Poppy"] = {
        [1] = {
            Name = "Poppy",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("poppypassivebuff") then
                    res.FlatMagical = res.FlatMagical + (10.588 + 9.412 * source.Level)
                end
            end,
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Pyke                                                                           |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Pyke"] then
    spellDamages["Pyke"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({85, 135, 185, 235, 285}, lvl) + 0.6 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({105, 135, 165, 195, 225}, lvl) + source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({0, 0, 0, 0, 0, 250, 290, 330, 400, 430, 450, 470, 490, 510, 540, 550}, lvl) + 0.8 * source.BonusAD + (0.015 * source.PhysicalLethality)
                return { RawTrue = rawDmg }
            end,
        },
    }

    spellData['Pyke'] = {
        ['PykeQMelee'] = {
            ['Default'] = spellDamages['Pyke'][SpellSlots.Q]['Default'],
        },
        ['PykeQRange'] = {
            ['Default'] = spellDamages['Pyke'][SpellSlots.Q]['Default'],
        },
        ['PykeE'] = {
            ['Default'] = spellDamages['Pyke'][SpellSlots.E]['Default'],
        },
        ['PykeR'] = {
            ['Default'] = spellDamages['Pyke'][SpellSlots.R]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.22] Qiyana                                                                         |
--| Last Update: 04.11.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Qiyana"] then
    spellDamages["Qiyana"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({50, 80, 110, 140, 170}, lvl) + 0.75 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
            ["Brush"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({50, 80, 110, 140, 170}, lvl) + 0.75 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
            ["River"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({50, 80, 110, 140, 170}, lvl) + 0.75 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
            ["Terrain"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({50, 80, 110, 140, 170}, lvl) + 0.75 * source.BonusAD
                local bonusDmg = GetDamageByLvl({36, 51, 66, 81, 96}, lvl) + 0.54 * source.BonusAD
                if target.HealthPercent < 0.5 then
                    rawDmg = rawDmg + bonusDmg
                end
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({50, 90, 130, 170, 210}, lvl) + 0.5 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({100, 200, 300}, lvl) + 1.7 * source.BonusAD + 0.1 * target.MaxHealth
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Qiyana'] = {
        ['QiyanaQ'] = {
            ['Default'] = spellDamages['Qiyana'][SpellSlots.Q]['Default'],
        },
        ['QiyanaQ_Grass'] = {
            ['Default'] = spellDamages['Qiyana'][SpellSlots.Q]['Brush'],
        },
        ['QiyanaQ_Rock'] = {
            ['Default'] = spellDamages['Qiyana'][SpellSlots.Q]['Terrain'],
        },
        ['QiyanaQ_Water'] = {
            ['Default'] = spellDamages['Qiyana'][SpellSlots.Q]['River'],
        },
        ['QiyanaR'] = {
            ['Default'] = spellDamages['Qiyana'][SpellSlots.R]['Default'],
        },
        ['QiyanaE'] = {
            ['Default'] = spellDamages['Qiyana'][SpellSlots.E]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.3] Quinn                                                                           |
--| Last Update: 08.02.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Quinn"] then
    spellDamages["Quinn"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local adRatio = GetDamageByLvl({0.8, 0.9, 1, 1.1, 1.2}, lvl)
                local rawDmg = GetDamageByLvl({20, 45, 70, 95, 120}, lvl) + adRatio * source.TotalAD + 0.5 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({40, 70, 100, 130, 160}, lvl) + 0.2 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = 0.7 * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Quinn'] = {
        ['QuinnQ'] = {
            ['Default'] = spellDamages['Quinn'][SpellSlots.Q]['Default'],
        },
        ['QuinnE'] = {
            ['Default'] = spellDamages['Quinn'][SpellSlots.E]['Default'],
        },
    }

    dynamicPassiveDamages["Quinn"] = {
        [1] = {
            Name = "Quinn",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end
                if aiTarget:GetBuff("quinnw") then
                    local dmg = 5 + 5 * source.Level + (0.14 + 0.02 * source.Level) * source.TotalAD
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Rakan                                                                          |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Rakan"] then
    spellDamages["Rakan"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({70, 115, 160, 205, 250}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({70, 125, 180, 235, 290}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({100, 200, 300}, lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Rakan'] = {
        ['RakanQ'] = {
            ['Default'] = spellDamages['Rakan'][SpellSlots.Q]['Default'],
        },
        ['RakanW'] = {
            ['Default'] = spellDamages['Rakan'][SpellSlots.W]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.8] Rammus                                                                          |
--| Last Update: 16.04.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Rammus"] then
    spellDamages["Rammus"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({100, 130, 160, 190, 220}, lvl) + source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({100, 175, 250}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.1] RekSai                                                                          |
--| Last Update: 04.01.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["RekSai"] then
    spellDamages["RekSai"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({20, 25, 30, 35, 40}, lvl) + 0.5 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
            ["SecondForm"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({60, 90, 120, 150, 180}, lvl) + 0.5 * source.BonusAD + 0.7 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({55, 70, 85, 100, 115}, lvl) + 0.8 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({55, 60, 65, 70, 75}, lvl) + 0.85 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({100, 120, 140, 160, 180}, lvl) + 1.7 * source.BonusAD
                return { RawTrue = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local hpDmg = GetDamageByLvl({0.2, 0.25, 0.3}, lvl) * (target.MaxHealth - target.Health)
                local rawDmg = GetDamageByLvl({100, 250, 400}, lvl) + 1.75 * source.BonusAD + hpDmg
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['RekSai'] = {
        ['RekSaiQBurrowed'] = {
            ['Default'] = spellDamages['RekSai'][SpellSlots.Q]['SecondForm'],
        },
        ['RekSaiE'] = {
            ['Default'] = spellDamages['RekSai'][SpellSlots.E]['Default'],
        },
        ['RekSaiRWrapper'] = {
            ['Default'] = spellDamages['RekSai'][SpellSlots.R]['Default'],
        },
    }

    staticPassiveDamages["RekSai"] = {
        [1] = {
            Name = "RekSai",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("reksaiq") then
                    local qLvl = source:GetSpell(SpellSlots.Q).Level
                    local dmg = (15 + 6 * qLvl) + (0.5 * source.BonusAD)
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        },
        [2] = {
            Name = "RekSai",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("reksaiw") then
                    local wLvl = source:GetSpell(SpellSlots.W).Level
                    local dmg = (40 + 15 * wLvl) + (0.8 * source.BonusAD)
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.9] Renekton                                                                        |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Renekton"] then
    spellDamages["Renekton"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({65, 100, 135, 170, 205}, lvl) + 0.8 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local dmgPerHit = (-10 + 15 * lvl) + (0.75 * source.TotalAD)
                local rawDmg = source.Mana <= 50 and dmgPerHit * 2 or dmgPerHit * 3
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({40, 70, 100, 130, 160}, lvl) + 0.9 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({25, 50, 75}, lvl) + 0.1 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    staticPassiveDamages["Renekton"] = {
        [1] = {
            Name = "Renekton",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("renektonpreexecute") then
                    local wLvl = source:GetSpell(SpellSlots.W).Level
                    local dmgPerHit = (-5 + 10 * wLvl) + (0.75 * source.TotalAD)
                    local totalDmg = source.Mana <= 50 and dmgPerHit * 2 or dmgPerHit * 3
                    res.FlatPhysical = res.FlatPhysical + (totalDmg - source.TotalAD)
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.9] Rengar                                                                          |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Rengar"] then
    spellDamages["Rengar"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = (0 + 30 * lvl) + (source.TotalAD * (-0.05 + 0.05 * lvl))
                local critMod = (0.66 + InfinityEdgeMod(source, 0.33))/100 * source.CritChance
                return { RawPhysical = rawDmg * (1+critMod) }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local dmgPerLvl = GetDamageByLvl({30, 45, 60, 75, 90, 105, 120, 135, 150, 160, 170, 180, 190, 200, 210, 220, 230, 240}, source.Level)
                local rawDmg = dmgPerLvl + (0.4 * source.TotalAD) 
                local critMod = (0.66 + InfinityEdgeMod(source, 0.33))/100 * source.CritChance
                return { RawPhysical = rawDmg * (1+critMod) }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = 65 + 65/17 * (lvl-1) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160, 170, 180, 190, 200, 210, 220}, source.Level) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({55, 100, 145, 190, 235}, lvl) + 0.8 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({50, 65, 80, 95, 110, 125, 140, 155, 170, 185, 200, 215, 230, 245, 260, 275, 290, 305}, source.Level) + 0.8 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Rengar'] = {
        ['RengarE'] = {
            ['Default'] = spellDamages['Rengar'][SpellSlots.E]['Default'],
        },
        ['RengarEEmp'] = {
            ['Default'] = spellDamages['Rengar'][SpellSlots.E]['Empowered'],
        },
    }

    staticPassiveDamages["Rengar"] = {
        [1] = {
            Name = "Rengar",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("rengarq") then
                    local dmg = spellDamages['Rengar'][SpellSlots.Q]['Default'](source, nil).RawPhysical
                    res.FlatPhysical = res.FlatPhysical + dmg
                elseif source:GetBuff("rengarqemp") then
                    local dmg = spellDamages['Rengar'][SpellSlots.Q]['Empowered'](source, nil).RawPhysical
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.22] Riven                                                                          |
--| Last Update: 04.11.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Riven"] then
    spellDamages["Riven"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local adRatio = GetDamageByLvl({0.45, 0.5, 0.55, 0.6, 0.65}, lvl)
                local rawDmg = GetDamageByLvl({15, 35, 55, 75, 95}, lvl) + adRatio * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({65, 95, 125, 155, 185}, lvl) + source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local hpDmg = min(2.667 * (1 - target.HealthPercent), 2)
                local rawDmg = GetDamageByLvl({100, 150, 200}, lvl) + 0.6 * source.BonusAD
                return { RawPhysical = rawDmg + rawDmg * hpDmg }
            end,
        },
    }

    spellData['Riven'] = {
        ['RivenMartyr'] = {
            ['Default'] = spellDamages['Riven'][SpellSlots.W]['Default'],
        },
        ['RivenIzunaBlade'] = {
            ['Default'] = spellDamages['Riven'][SpellSlots.R]['Default'],
        },
    }

    staticPassiveDamages["Riven"] = {
        [1] = {
            Name = "Riven",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("rivenpassiveaaboost") then
                    local lvl = source.Level
                    local mod = lvl >= 6 and 0.30 + 0.06 * ceil((lvl - 5) / 3) or 0.3
                    res.FlatPhysical = res.FlatPhysical + (source.TotalAD * mod)
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.11] Rumble                                                                          |
--| Last Update: 13.06.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Rumble"] then
    spellDamages["Rumble"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({180, 220, 260, 300, 340}, lvl) + 1.1 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({270, 330, 390, 450, 510}, lvl) + 1.65 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({60, 85, 110, 135, 160}, lvl) + 0.4 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({90, 127.5, 165, 202.5, 240}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({70, 105, 140}, lvl) + 0.175 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Rumble'] = {
        ['RumbleGrenade'] = {
            ['Default'] = spellDamages['Rumble'][SpellSlots.E]['Default'],
        },
        ['RumbleR'] = {
            ['Default'] = spellDamages['Rumble'][SpellSlots.R]['Default'],
        },
    }

    dynamicPassiveDamages["Rumble"] = {
        [1] = {
            Name = "Rumble",
            Func = function(res, source, target)
                if not target.IsStructure and source:GetBuff("rumbleoverheat") then
                    local baseDmg = 5 + 35/17 * (source.Level-1) + (0.25 * source.TotalAP) 
                    local extraDmg = (0.06 * target.MaxHealth)
                    if target.IsMonster then extraDmg = min(extraDmg, 80) end
                    res.FlatMagical = res.FlatMagical + baseDmg + extraDmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.11] Ryze                                                                           |
--| Last Update: 23.06.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Ryze"] then
    spellDamages["Ryze"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rLvl = source:GetSpell(SpellSlots.R).Level
                local bonusDmg = rLvl > 5 and GetDamageByLvl({0.4, 0.7, 1}, rLvl) or 0
                local rawDmg = GetDamageByLvl({70, 90, 110, 130, 150}, lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg + rawDmg * bonusDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({80, 110, 140, 170, 200}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({60, 80, 100, 120, 140}, lvl) + 0.35 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Ryze'] = {
        ['RyzeQ'] = {
            ['Default'] = spellDamages['Ryze'][SpellSlots.Q]['Default'],
        },
        ['RyzeW'] = {
            ['Default'] = spellDamages['Ryze'][SpellSlots.W]['Default'],
        },
        ['RyzeE'] = {
            ['Default'] = spellDamages['Ryze'][SpellSlots.E]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.19] Sejuani                                                                        |
--| Last Update: 22.09.2021                                                                 |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Sejuani"] then
    spellDamages["Sejuani"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({90, 140, 190, 240, 290}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({20, 25, 30, 35, 40}, lvl) + 0.2 * source.TotalAP + 0.02 * source.MaxHealth
                return { RawPhysical = rawDmg }
            end,
            ["SecondForm"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({30, 70, 110, 150, 190}, lvl) + 0.6 * source.TotalAP + 0.06 * source.MaxHealth
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({55, 105, 155, 205, 255}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({125, 150, 175}, lvl) + 0.4 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["SecondForm"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({200, 300, 400}, lvl) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Sejuani'] = {
        ['SejuaniQ'] = {
            ['Default'] = spellDamages['Sejuani'][SpellSlots.Q]['Default'],
        },
        ['SejuaniR'] = {
            ['Default'] = spellDamages['Sejuani'][SpellSlots.R]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.11] Samira                                                                         |
--| Last Update: 23.06.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
if IsInGame["Samira"] then
    spellDamages["Samira"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({0, 5, 10, 15, 20}, lvl) + GetDamageByLvl({0.85, 0.95, 1.05, 1.15, 1.25}, lvl) * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({20, 35, 50, 65, 80}, lvl) + 0.8 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({50, 60, 70, 80, 90}, lvl) + 0.2 * source.BonusAD
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({5, 15, 25}, lvl) + 0.5 * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Samira'] = {
        ['SamiraQGun'] = {
            ['Default'] = spellDamages['Samira'][SpellSlots.Q]['Default'],
        },
    }

    dynamicPassiveDamages["Samira"] = {
        [1] = {
            Name = "Samira",
            Func = function(res, source, target)
                if target:Distance(source) < 325 then
                    local lvl = source.Level
                    local healthMod = 1 - target.HealthPercent                    
                    local totalDmg = (1 + lvl) + ((0.035 + (lvl - 1) * 0.07/17) * source.TotalAD)
                    res.FlatMagical = res.FlatMagical + totalDmg * (1 + healthMod)
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.14] Seraphine                                                                      |
--| Last Update: 09.07.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Seraphine"] then
    spellDamages["Seraphine"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local apRatio = GetDamageByLvl({0.45, 0.50, 0.55, 0.60, 0.65}, lvl)
                local rawDmg = GetDamageByLvl({55, 70, 85, 100, 115}, lvl) + apRatio * source.TotalAP
                local bonusDmg = 5 * ((1 - target.HealthPercent) / 7.5)
                return { RawMagical = rawDmg + rawDmg * bonusDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({60, 80, 100, 120, 140}, lvl)
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 200, 250}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Seraphine'] = {
        ['SeraphineQCast'] = {
            ['Default'] = spellDamages['Seraphine'][SpellSlots.Q]['Default'],
        },
        ['SeraphineECast'] = {
            ['Default'] = spellDamages['Seraphine'][SpellSlots.E]['Default'],
        },
        ['SeraphineR'] = {
            ['Default'] = spellDamages['Seraphine'][SpellSlots.R]['Default'],
        },
    }

    dynamicPassiveDamages["Seraphine"] = {
        [1] = {
            Name = "Seraphine",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end
                local buff = source:GetBuff("seraphinepassivenotesbuff")
                if buff then
                    local lvl = source.Level
                    local baseDmg = lvl < 6 and 4    or lvl < 11 and 8    or lvl < 16 and 14   or 24
                    local apScale = lvl < 6 and 0.06 or lvl < 11 and 0.07 or lvl < 16 and 0.08 or 0.09 
                    local dmgPerNote = baseDmg + (apScale * source.TotalAP)
                    local mod = buff.Count == 1 and 1 or 1 - (buff.Count * 0.05)
                    local totalDmg = dmgPerNote * buff.Count
                    if target.IsMinion and not target.IsMonster then
                        totalDmg = totalDmg * 3
                    elseif target.IsHero then
                        totalDmg = totalDmg * mod
                    end
                    res.FlatMagical = res.FlatMagical + totalDmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.10] Senna                                                                          |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Senna"] then
    spellDamages["Senna"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({40, 70, 100, 130, 160}, lvl) + 0.4 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({70, 115, 160, 205, 250}, lvl) + 0.7 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({250, 375, 500}, lvl) + source.BonusAD + 0.7 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Senna'] = {
        ['SennaQCast'] = {
            ['Default'] = spellDamages['Senna'][SpellSlots.Q]['Default'],
        },
        ['SennaW'] = {
            ['Default'] = spellDamages['Senna'][SpellSlots.W]['Default'],
        },
        ['SennaR'] = {
            ['Default'] = spellDamages['Senna'][SpellSlots.R]['Default'],
        },
    }

    staticPassiveDamages["Senna"] = {
        [1] = {
            Name = "Senna",
            Func = function(res, source, isMinionTarget)
                res.FlatPhysical = res.FlatPhysical + source.TotalAD * 0.2
            end
        }
    }

    dynamicPassiveDamages["Senna"] = {
        [1] = {
            Name = "Senna",
            Func = function(res, source, target)
                local heroSource = source.AsHero
                local aiTarget = target.AsAI
                
                if heroSource and aiTarget and aiTarget:GetBuff("sennapassivemarker") then
                    local dmg_mod = min(heroSource.Level/100, 0.1)
                    res.FlatPhysical = res.FlatPhysical + dmg_mod * aiTarget.Health
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.9] Sett                                                                            |
--| Last Update: 30.04.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Sett"] then
    spellDamages["Sett"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = (0 + 10 * lvl) + (0.01 + (0.01 * (source.TotalAD / 100))) * target.MaxHealth
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({80, 100, 120, 140, 160}, lvl) + (0.25 + (0.2 * (source.BonusAD / 100))) * source.Mana
                return { RawTrue = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({50, 70, 90, 110, 130}, lvl) + 0.6 * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({200, 300, 400}, lvl) + 1.2*source.BonusAD + ((0.3 + 0.1 * lvl) * target.BonusHealth)
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Sett'] = {
        ['SettW'] = {
            ['Default'] = spellDamages['Sett'][SpellSlots.W]['Default'],
        },
        ['SettE'] = {
            ['Default'] = spellDamages['Sett'][SpellSlots.E]['Default'],
        },
        ['SettR'] = {
            ['Default'] = spellDamages['Sett'][SpellSlots.R]['Default'],
        },
    }

    staticPassiveDamages["Sett"] = {
        [1] = {
            Name = "Sett",
            Func = function(res, source, isMinionTarget)
                if source.AttackRange > 125 and not source:GetBuff("settq") then
                    local dmg = (5 * source.Level) + (0.5 * source.BonusAD)
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        }
    }

    dynamicPassiveDamages["Sett"] = {
        [1] = {
            Name = "Sett",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if aiTarget and source:GetBuff("settq") then
                    local qLvl = source:GetSpell(SpellSlots.Q).Level
                    local maxHealthMod = (0.005 + 0.005 * qLvl) * (source.TotalAD/100)
                    local dmg = (10 * qLvl) + (0.01 + maxHealthMod) * target.MaxHealth
                    local lastAttackName = SettAttackData[source.Handle]
                    if lastAttackName and lastAttackName == "SettQAttack" then
                        local rightPunchDmg = (5 * source.Level) + (0.5 * source.BonusAD)
                        dmg = dmg + rightPunchDmg
                    end
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.12] Shaco                                                                          |
--| Last Update: 23.06.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Shaco"] then
    spellDamages["Shaco"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({25, 35, 45, 55, 65}, lvl) + 0.4 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({15, 20, 25, 30, 35}, lvl) + 0.12 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({70, 95, 120, 145, 170}, lvl) + 0.75 * source.BonusAD + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 225, 300}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Shaco'] = {
        ['TwoShivPoison'] = {
            ['Default'] = spellDamages['Shaco'][SpellSlots.E]['Default'],
        },
    }

    dynamicPassiveDamages["Shaco"] = {
        [1] = {
            Name = "Shaco",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end
                if not aiTarget:IsFacing(source, 90) then
                    local dmg = (19.118 + 0.882 * source.Level) + (0.15 * source.BonusAD)
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        },
        [2] = {
            Name = "Shaco",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end

                if source:GetBuff("Deceive") then
                    local qLvl = source:GetSpell(SpellSlots.Q).Level
                    local dmg = 15 + 10 * qLvl + 0.25 * source.BonusAD

                    if not aiTarget:IsFacing(source, 90) then
                        res.PercentPhysical = (1.3+InfinityEdgeMod(source, 0.35))
                    end
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        }          
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.2] Shen                                                                            |
--| Last Update: 21.01.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Shen"] then
    spellDamages["Shen"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source.Level
                local qLvl = source:GetSpell(SpellSlots.Q).Level
                local baseDmg = (lvl >= 4 and 10 + 6 * ceil((lvl - 3) / 3) or 10)
                local maxHealthDamage = ((0.015 + 0.005 * qLvl) + (0.015 * (source.TotalAP / 100))) * target.MaxHealth
                local totalDmg = baseDmg + maxHealthDamage
                if target.IsMonster then
                    local cappedDmg = 100 + 20 * qLvl
                    totalDmg = min(totalDmg * 2, cappedDmg)
                end
                return { RawMagical = totalDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source.Level
                local qLvl = source:GetSpell(SpellSlots.Q).Level
                local baseDmg = (lvl >= 4 and 10 + 6 * ceil((lvl - 3) / 3) or 10)
                local maxHealthDamage = ((0.035 + 0.005 * qLvl) + (0.02 * (source.TotalAP / 100))) * target.MaxHealth
                local totalDmg = baseDmg + maxHealthDamage
                if target.IsMonster then
                    local cappedDmg = 100 + 20 * qLvl
                    totalDmg = min(totalDmg * 2, cappedDmg)
                end
                return { RawMagical = totalDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({60, 85, 110, 135, 160}, lvl) + 0.15 * target.BonusHealth
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Shen'] = {
        ['ShenE'] = {
            ['Default'] = spellDamages['Shen'][SpellSlots.E]['Default'],
        },
    }

    dynamicPassiveDamages["Shen"] = {
        [1] = {
            Name = "Shen",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end
                if source:GetBuff("shenqbuffstrong") then
                    local dmg = spellDamages.Shen[SpellSlots.Q].Empowered(source, aiTarget).RawMagical
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end
        },
        [2] = {
            Name = "Shen",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end
                if source:GetBuff("shenqbuffweak") then
                    local dmg = spellDamages.Shen[SpellSlots.Q].Default(source, aiTarget).RawMagical
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.15] Shyvana                                                                        |
--| Last Update: 28.07.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Shyvana"] then
    spellDamages["Shyvana"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({0.2, 0.35, 0.5, 0.65, 0.8}, lvl) * source.TotalAD + (0.35+0.25) * source.TotalAP
                return { RawMagical = rawDmg, ApplyOnHit = true }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({20, 32.5, 45, 57.5, 70}, lvl) + 0.2 * source.BonusAD
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({60, 100, 140, 180, 220}, lvl) + 0.3 * source.TotalAD + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = (100 + 5 * source.Level) + 0.6 * source.TotalAD + source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 250, 350}, lvl) + source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Shyvana'] = {
        ['ShyvanaFireball'] = {
            ['Default'] = spellDamages['Shyvana'][SpellSlots.E]['Default'],
        },
        ['ShyvanaFireballDragon2'] = {
            ['Default'] = spellDamages['Shyvana'][SpellSlots.E]['Empowered'],
        },
        ['ShyvanaTransformCast'] = {
            ['Default'] = spellDamages['Shyvana'][SpellSlots.R]['Empowered'],
        },
    }

    local loop = false
    dynamicPassiveDamages["Shyvana"] = {
        [1] = {
            Name = "Shyvana",
            Func = function(res, source, target)
                if not loop and (source:GetBuff("shyvanadoubleattack") or source:GetBuff("shyvanadoubleattackdragon")) then
                    loop = true
                    local aaDmg = DamageLib.GetAutoAttackDamage(source, target, true)
                    local bonusDmg = spellDamages['Shyvana'][SpellSlots.Q]['Default'](source, target).RawMagical
                    loop = false
                    res.FlatPhysical = res.FlatPhysical + aaDmg + bonusDmg
                end
            end
        },
        [2] = {
            Name = "Shyvana",
            Func = function(res, source, target)
                if not loop and source:GetBuff("shyvanaimmolationaura") then
                    local wLvl = source:GetSpell(SpellSlots.W).Level
                    local dmg = (1.875 + 3.125 * wLvl) + (0.05 * source.BonusAD)
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end
        },
        [3] = {
            Name = "Shyvana",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if loop or not aiTarget then return end
                if aiTarget:GetBuff("shyvanafireballmissile") then
                    local dmg = 0.0375 * aiTarget.MaxHealth
                    if target.IsMonster then
                        dmg = min(dmg, 150)
                    end
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.20] Singed                                                                         |
--| Last Update: 08.10.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Singed"] then
    spellDamages["Singed"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({5, 7.5, 10, 12.5, 15}, lvl) + 0.1125 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local hpDmg = GetDamageByLvl({0.06, 0.065, 0.07, 0.075, 0.08}, lvl) * target.MaxHealth
                local rawDmg = GetDamageByLvl({50, 60, 70, 80, 90}, lvl) + hpDmg + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Singed'] = {
        ['Fling'] = {
            ['Default'] = spellDamages['Singed'][SpellSlots.E]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.24] Sion                                                                           |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Sion"] then
    spellDamages["Sion"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local adRatio = GetDamageByLvl({0.45, 0.525, 0.60, 0.675, 0.75}, lvl)
                local rawDmg = GetDamageByLvl({30, 50, 70, 90, 110}, lvl) + adRatio * source.TotalAD
                if target.IsMinion then rawDmg = rawDmg * (target.IsNeutral and 1.5 or 0.6) end
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local hpDmg = GetDamageByLvl({0.10, 0.11, 0.12, 0.13, 0.14}, lvl)
                local rawDmg = GetDamageByLvl({40, 65, 90, 115, 140}, lvl) + 0.4 * source.TotalAP + hpDmg
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({65, 100, 135, 170, 205}, lvl) + 0.55 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 300, 450}, lvl) + 0.4 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Sion'] = {
        ['SionE'] = {
            ['Default'] = spellDamages['Sion'][SpellSlots.E]['Default'],
        },
        ['SionEMinion'] = {
            ['Default'] = spellDamages['Sion'][SpellSlots.E]['Default'],
        },
    }

    dynamicPassiveDamages["Sion"] = {
        [1] = {
            Name = "Sion",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end
                if source.IsZombie then
                    local dmg = 0.1 * aiTarget.MaxHealth
                    if not aiTarget.IsHero then
                        dmg = min(dmg, 75)
                    end
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Sivir                                                                          |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Sivir"] then
    spellDamages["Sivir"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local adRatio = GetDamageByLvl({0.70, 0.85, 1, 1.15, 1.3}, lvl)
                local rawDmg = GetDamageByLvl({35, 50, 65, 80, 95}, lvl) + adRatio * source.TotalAD + 0.5 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Sivir'] = {
        ['SivirQ'] = {
            ['Default'] = spellDamages['Sivir'][SpellSlots.Q]['Default'],
        },
        ['SivirQReturn'] = {
            ['Default'] = spellDamages['Sivir'][SpellSlots.Q]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Skarner                                                                        |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Skarner"] then
    spellDamages["Skarner"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({0.01, 0.015, 0.02, 0.025, 0.03}, lvl) * target.MaxHealth + 0.2 * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({0.01, 0.015, 0.02, 0.025, 0.03}, lvl) * target.MaxHealth + 0.2 * source.TotalAD + 0.3 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({40, 65, 90, 115, 140}, lvl) + 0.2 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({20, 60, 100}, lvl) + 0.5 * source.TotalAP
                return { RawPhysical = source.TotalAP * 0.6, RawMagical = rawDmg }
            end,
        },
    }

    spellData['Skarner'] = {
        ['SkarnerFracture'] = {
            ['Default'] = spellDamages['Skarner'][SpellSlots.E]['Default'],
        },
        ['SkarnerImpale'] = {
            ['Default'] = spellDamages['Skarner'][SpellSlots.R]['Default'],
        },
    }

    dynamicPassiveDamages["Skarner"] = {
        [1] = {
            Name = "Skarner",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end
                if aiTarget:GetBuff("skarnerpassivebuff") then
                    local eLvl = source:GetSpell(SpellSlots.E).Level
                    local dmg = 10 + 20 * eLvl
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Sona                                                                           |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Sona"] then
    spellDamages["Sona"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({40, 70, 100, 130, 160}, lvl) + 0.4 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 250, 350}, lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Sona'] = {
        ['SonaR'] = {
            ['Default'] = spellDamages['Sona'][SpellSlots.R]['Default'],
        },
    }

    staticPassiveDamages["Sona"] = {
        [1] = {
            Name = nil,
            Func = function(res, source, isMinionTarget)
                local buff = source:GetBuff("sonaqprocattacker")
                if buff then
                    local buffSource = buff.Source
                    buffSource = buffSource and buffSource.AsHero
                    if not buffSource then return end
                    local qLvl = buffSource:GetSpell(SpellSlots.Q).Level
                    res.FlatMagical = res.FlatMagical + (5 + 5 * qLvl + 0.2 * buffSource.TotalAP)
                end
            end,
            -- //TODO: Add Power Chord
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Soraka                                                                         |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Soraka"] then
    spellDamages["Soraka"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({85, 120, 155, 190, 225}, lvl) + 0.35 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({70, 95, 120, 145, 170}, lvl) + 0.4 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Soraka'] = {
        ['SorakaQ'] = {
            ['Default'] = spellDamages['Soraka'][SpellSlots.Q]['Default'],
        },
        ['SorakaE'] = {
            ['Default'] = spellDamages['Soraka'][SpellSlots.E]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.11] Swain                                                                          |
--| Last Update: 23.06.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Swain"] then
    spellDamages["Swain"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({60, 80, 100, 120, 140}, lvl) + 0.38 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({80, 115, 150, 185, 220}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({35, 70, 105, 140, 175}, lvl) + 0.25 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["Detonation"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({35, 45, 55, 65, 75}, lvl) + 0.25 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({20, 40, 60}, lvl) + 0.10 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["Detonation"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 225, 300}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Swain'] = {
        ['SwainW'] = {
            ['Default'] = spellDamages['Swain'][SpellSlots.W]['Default'],
        },
        ['SwainE'] = {
            ['Default'] = spellDamages['Swain'][SpellSlots.E]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.15] Sylas                                                                          |
--| Last Update: 28.07.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Sylas"] then
    spellDamages["Sylas"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({40, 60, 80, 100, 120}, lvl) + 0.4 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["Detonation"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({70, 125, 180, 235, 290}, lvl) + 0.9 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({70, 105, 140, 175, 210}, lvl) + 0.9 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({80, 130, 180, 230, 280}, lvl) + source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Sylas'] = {
        ['SylasQ'] = {
            ['Default'] = spellDamages['Sylas'][SpellSlots.Q]['Default'],
        },
        ['SylasQ_Explosion'] = {
            ['Default'] = spellDamages['Sylas'][SpellSlots.Q]['Detonation'],
        },
        ['SylasE2'] = {
            ['Default'] = spellDamages['Sylas'][SpellSlots.E]['Default'],
        },
    }

    staticPassiveDamages["Sylas"] = {
        [1] = {
            Name = "Sylas",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("SylasPassiveAttack") then
                    res.FlatPhysical = res.FlatPhysical - source.TotalAD
                    res.FlatMagical = source.TotalAD*1.3 + source.TotalAP*0.25
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Syndra                                                                         |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Syndra"] then
    spellDamages["Syndra"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({70, 105, 140, 175, 210}, lvl) + 0.65 * source.TotalAP
                if target.IsHero and lvl == 5 then
                    rawDmg = rawDmg + 52.5 + 0.1625 * source.TotalAP
                end
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({70, 110, 150, 190, 230}, lvl) + 0.7 * source.TotalAP
                local bonusDmg = 0
                if lvl == 5 then
                    bonusDmg = 46 + 0.14 * source.TotalAP
                end
                return { RawMagical = rawDmg, RawTrue = bonusDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({85, 130, 175, 220, 265}, lvl) + 0.6 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local ammo = source:GetSpell(SpellSlots.R).Ammo
                local rawDmg = (GetDamageByLvl({90, 140, 190}, lvl) + 0.2 * source.TotalAP) * ammo
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Syndra'] = {
        ['SyndraQ'] = {
            ['Default'] = spellDamages['Syndra'][SpellSlots.Q]['Default'],
        },
        ['SyndraWCast'] = {
            ['Default'] = spellDamages['Syndra'][SpellSlots.W]['Default'],
        },
        ['SyndraE'] = {
            ['Default'] = spellDamages['Syndra'][SpellSlots.E]['Default'],
        },
        ['SyndraE5'] = {
            ['Default'] = spellDamages['Syndra'][SpellSlots.E]['Default'],
        },
        ['SyndraEQ'] = {
            ['Default'] = spellDamages['Syndra'][SpellSlots.E]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.14] TahmKench                                                                      |
--| Last Update: 09.07.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["TahmKench"] then
    spellDamages["TahmKench"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({80, 130, 180, 230, 280}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local hpDmg = (0.15 + (0.05 * (source.TotalAP / 100))) * target.MaxHealth
                local rawDmg = GetDamageByLvl({100, 250, 400}, lvl) + hpDmg
                return { RawMagical = rawDmg }
            end,
        },

    }

    spellData['TahmKench'] = {
        ['TahmKenchQ'] = {
            ['Default'] = spellDamages['TahmKench'][SpellSlots.Q]['Default'],
        },
        ['TahmKenchWCastTimeAndAnimation'] = {
            ['Default'] = spellDamages['TahmKench'][SpellSlots.R]['Default'],
        },
    }

    staticPassiveDamages["TahmKench"] = {
        [1] = {
            Name = "TahmKench",
            Func = function(res, source, isMinionTarget)
                local baseDmg = 12 + 48/17 * (source.Level - 1)
                res.FlatMagical = res.FlatMagical + baseDmg + (0.025 * source.BonusHealth)
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.11] Taliyah                                                                        |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Taliyah"] then
    spellDamages["Taliyah"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({40, 60, 80, 100, 120}, lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                return { RawMagical = 0 }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({60, 105, 150, 195, 240}, lvl) + 0.6 * source.TotalAP
                return { RawPhysical = 0 }
            end,
        },
    }

    spellData['Taliyah'] = {
        ['TaliyahQ'] = {
            ['Default'] = spellDamages['Taliyah'][SpellSlots.Q]['Default'],
        },
        ['TaliyahWVC'] = {
            ['Default'] = spellDamages['Taliyah'][SpellSlots.W]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.18] Talon                                                                          |
--| Last Update: 09.09.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Talon"] then
    spellDamages["Talon"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({65, 85, 105, 125, 145}, lvl) + 1 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({97.5, 135, 172.5, 210, 247.5}, lvl) + 1.5 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({40, 50, 60, 70, 80}, lvl) + 0.4 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
            ["WayBack"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({50, 80, 110, 140, 170}, lvl) + 0.8 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({90, 135, 180}, lvl) + source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Talon'] = {
        ['TalonW'] = {
            ['Default'] = spellDamages['Talon'][SpellSlots.W]['Default'],
        },
        ['TalonW_Return'] = {
            ['Default'] = spellDamages['Talon'][SpellSlots.W]['WayBack'],
        },
        ['TalonQ'] = {
            ['Default'] = spellDamages['Talon'][SpellSlots.Q]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Taric                                                                          |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Taric"] then
    spellDamages["Taric"] = {
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({90, 130, 170, 210, 250}, lvl) + 0.5 * source.TotalAP + 0.5 * source.BonusArmor
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Taric'] = {
        ['TaricE'] = {
            ['Default'] = spellDamages['Taric'][SpellSlots.E]['Default'],
        },
    }

    staticPassiveDamages["Taric"] = {
        [1] = {
            Name = "Taric",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("taricpassiveattack") then
                    local dmg = (21 + 4 * source.Level) + (0.15 * source.BonusArmor)
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.17] Teemo                                                                           |
--| Last Update: 25.08.2021                                                                 |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Teemo"] then
    spellDamages["Teemo"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({80, 125, 170, 215, 260}, lvl) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({10, 20, 30, 40, 50}, lvl) + 0.3 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["DamagePerSecond"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({6, 12, 18, 24, 30}, lvl) + 0.1 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({50, 81.25, 112.5}, lvl) + 0.125 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Teemo'] = {
        ['TeemoRCast'] = {
            ['Default'] = spellDamages['Teemo'][SpellSlots.R]['Default'],
        },
        ['BlindingDart'] = {
            ['Default'] = spellDamages['Teemo'][SpellSlots.Q]['Default'],
        },
    }

    staticPassiveDamages["Teemo"] = {
        [1] = {
            Name = "Teemo",
            Func = function(res, source, isMinionTarget)
                local eLvl = source:GetSpell(SpellSlots.E).Level
                if eLvl > 0 then
                    local dmg = (3 + 11 * eLvl) + (0.3 * source.TotalAP)
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Thresh                                                                         |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Thresh"] then
    spellDamages["Thresh"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({80, 120, 160, 200, 240}, lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({65, 95, 125, 155, 185}, lvl) + 0.4 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({250, 400, 550}, lvl) + source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Thresh'] = {
        ['ThreshQ'] = {
            ['Default'] = spellDamages['Thresh'][SpellSlots.Q]['Default'],
        },
        ['ThreshE'] = {
            ['Default'] = spellDamages['Thresh'][SpellSlots.E]['Default'],
        },
    }

    staticPassiveDamages["Thresh"] = {
        [1] = {
            Name = "Thresh",
            Func = function(res, source, isMinionTarget)
                local eLvl = source:GetSpell(SpellSlots.E).Level
                if eLvl > 0 then
                    local mod = 0
                    local offset = isMinionTarget and 4 or 1
                    local b1 = source:GetBuff("threshepassive1")
                    local b2 = source:GetBuff("threshepassive2")
                    local b3 = source:GetBuff("threshepassive3")
                    local b4 = source:GetBuff("threshepassive4")
                    local soulsBuff = source:GetBuff("threshpassivesoulsgain")
                    local soulsCount = soulsBuff and soulsBuff.Count or 1
                    if b1 then
                        mod = (b1.Duration - b1.DurationLeft) - offset
                    end
                    if b2 then
                        mod = (b2.Duration - b2.DurationLeft) - offset
                    end
                    if b3 then
                        mod = (b3.Duration - b3.DurationLeft) - offset
                    end
                    if b4 then
                        mod = 10
                    end
                    mod = mod / 10
                    local dmg = ((0.75 + 0.25 * eLvl) * source.TotalAD) * mod + soulsCount
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Tristana                                                                       |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Tristana"] then
    spellDamages["Tristana"] = {
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({95, 145, 195, 245, 295}, lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local buff = target:GetBuff("tristanaecharge")
                local baseDmg = 60 + 10 * lvl + ((0.35 + 0.15 * lvl) * source.BonusAD) + 0.5 * source.TotalAP
                local stacks = buff and buff.Count or 0
                local stackDmg = (18 + 3 * lvl + ((0.075 + 0.075 * lvl) * source.BonusAD) + 0.15 * source.TotalAP) * stacks
                local rawDmg = baseDmg + stackDmg
                local bonusDmg = min(0.33 * source.CritChance, 33.3)
                return { RawPhysical = rawDmg + rawDmg * bonusDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({300, 400, 500}, lvl) + source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Tristana'] = {
        ['TristanaW'] = {
            ['Default'] = spellDamages['Tristana'][SpellSlots.W]['Default'],
        },
        ['TristanaE'] = {
            ['Default'] = spellDamages['Tristana'][SpellSlots.E]['Default'],
        },
        ['TristanaR'] = {
            ['Default'] = spellDamages['Tristana'][SpellSlots.R]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.2] Trundle                                                                        |
--| Last Update: 25.01.2021                                                               |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Trundle"] then
    spellDamages["Trundle"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = (0 + 20 * lvl) + ((0.05 + 0.1 * lvl) * source.TotalAD)
                return { RawPhysical = rawDmg, ApplyOnHit = true }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = (GetDamageByLvl({0.20, 0.275, 0.35}, lvl) + (0.02 * (source.TotalAP / 100))) * target.MaxHealth
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Trundle'] = {
        ['TrundlePain'] = {
            ['Default'] = spellDamages['Trundle'][SpellSlots.R]['Default'],
        },
    }

    staticPassiveDamages["Trundle"] = {
        [1] = {
            Name = "Trundle",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("trundletrollsmash") then
                    local dmg = spellDamages.Trundle[SpellSlots.Q].Default(source).RawPhysical
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Tryndamere                                                                     |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Tryndamere"] then
    spellDamages["Tryndamere"] = {
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({80, 110, 140, 170, 200}, lvl) + 1.3 * source.BonusAD + 0.8 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.3] TwistedFate                                                                     |
--| Last Update: 08.02.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["TwistedFate"] then
    spellDamages["TwistedFate"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({60, 100, 140, 180, 220}, lvl) + 0.7 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Blue"] = function(source, target)
                local wLvl = source:GetSpell(SpellSlots.W).Level
                local dmg = (20 + 20 * wLvl) + (source.TotalAD) + (0.9 * source.TotalAP)
                return { RawMagical = dmg }
            end,
            ["Red"] = function(source, target)
                local wLvl = source:GetSpell(SpellSlots.W).Level
                local dmg = (15 + 15 * wLvl) + (source.TotalAD) + (0.6 * source.TotalAP)
                return { RawMagical = dmg }
            end,
            ["Gold"] = function(source, target)
                local wLvl = source:GetSpell(SpellSlots.W).Level
                local dmg = (7.5 + 7.5 * wLvl) + (source.TotalAD) + (0.5 * source.TotalAP)
                return { RawMagical = dmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = (40 + 25 * lvl) + (0.5 * source.TotalAP)
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['TwistedFate'] = {
        ['WildCards'] = {
            ['Default'] = spellDamages['TwistedFate'][SpellSlots.Q]['Default'],
        },
    }

    dynamicPassiveDamages["TwistedFate"] = {
        [1] = {
            Name = "TwistedFate",
            Func = function(res, source, target)
                if target.IsStructure then return end
                if source:GetBuff("cardmasterstackparticle") then
                    local eLvl = source:GetSpell(SpellSlots.E).Level
                    local dmg = (40 + 25 * eLvl) + (0.5 * source.TotalAP)
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end
        }
    }

    staticPassiveDamages["TwistedFate"] = {
        [1] = {
            Name = "TwistedFate",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("bluecardpreattack") then
                    local dmg = spellDamages.TwistedFate[SpellSlots.W].Blue(source).RawMagical
                    res.FlatMagical = res.FlatMagical + (dmg - source.TotalAD)
                end
                if source:GetBuff("redcardpreattack") then
                    local dmg = spellDamages.TwistedFate[SpellSlots.W].Red(source).RawMagical
                    res.FlatMagical = res.FlatMagical + (dmg - source.TotalAD)
                end
                if source:GetBuff("goldcardpreattack") then
                    local dmg = spellDamages.TwistedFate[SpellSlots.W].Gold(source).RawMagical
                    res.FlatMagical = res.FlatMagical + (dmg - source.TotalAD)
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Twitch                                                                         |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Twitch"] then
    spellDamages["Twitch"] = {
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local buff = target:GetBuff("twitchdeadlyvenom")
                local stacks = buff and buff.Count or 0
                local baseDmg = GetDamageByLvl({20, 30, 40, 50, 60}, lvl)
                local stackDmg = (GetDamageByLvl({15, 20, 25, 30, 35}, lvl) + 0.35 * source.BonusAD + 0.333 * source.TotalAP) * stacks
                local rawDmg = baseDmg + stackDmg
                return { RawPhysical = rawDmg }
            end,
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.20] Udyr                                                                           |
--| Last Update: 08.10.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Udyr"] then
    spellDamages["Udyr"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local adRatio = GetDamageByLvl({1.10, 1.25, 1.40, 1.55, 1.70, 1.85}, lvl) * source.TotalAD
                local rawDmg = GetDamageByLvl({30, 60, 90, 120, 150, 180}, lvl) + adRatio
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = (10 + 50 * lvl) + (0.8 * source.TotalAP)
                return { RawMagical = rawDmg }
            end,
        },
    }

    staticPassiveDamages["Udyr"] =  {
        [1] = {
            Name = "Udyr",
            Func = function(res, source, isMinionTarget)
                local buff = source:GetBuff("udyrphoenixstance")
                if buff and buff.Count == 3 then
                    local dmg = spellDamages.Udyr[SpellSlots.R].Default(source).RawMagical
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.11] Urgot                                                                          |
--| Last Update: 13.06.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Urgot"] then
    spellDamages["Urgot"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({25, 70, 115, 160, 205}, lvl) + 0.7 * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({90, 120, 150, 180, 210}, lvl) + source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({100, 225, 350}, lvl) + 0.5 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Urgot'] = {
        ['UrgotQ'] = {
            ['Default'] = spellDamages['Urgot'][SpellSlots.Q]['Default'],
        },
        ['UrgotE'] = {
            ['Default'] = spellDamages['Urgot'][SpellSlots.E]['Default'],
        },
        ['UrgotE'] = {
            ['Default'] = spellDamages['Urgot'][SpellSlots.R]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.9] Varus                                                                           |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Varus"] then
    spellDamages["Varus"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local bonusDmg = 0
                local adRatio = GetDamageByLvl({0.8333, 0.8667, 0.90, 0.9333, 0.9667}, lvl) * source.TotalAD
                local rawDmg = GetDamageByLvl({10, 46.67, 83.33, 120, 156.67}, lvl) + adRatio
                local buff = source:GetBuff("varusq")
                local duration = buff and buff.Duration - buff.DurationLeft + 0.7 or 0
                duration = min(duration, 2)
                if duration > 0 then
                    bonusDmg = min(0.25 * duration, 2)
                end
                return { RawPhysical = rawDmg + rawDmg * bonusDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local aiTarget = target.AsAI
                local wBuff = aiTarget and aiTarget:GetBuff("varuswdebuff")
                if not wBuff then return { RawMagical = 0 } end
                
                local wLvl = source:GetSpell(SpellSlots.W).Level
                local modPerStack = (0.025 + 0.005 * wLvl) + (0.02 * source.TotalAP/100)
                
                local totalDmg = (modPerStack * wBuff.Count) * target.MaxHealth
                if target.IsMonster then totalDmg = min(360, totalDmg) end

                return { RawMagical = totalDmg }
            end,
            ["SecondForm"] = function(source, target)
                local lvl = source.Level
                local qMod = (lvl > 12 and 0.14) or 
                             (lvl > 9  and 0.12) or 
                             (lvl > 6  and 0.10) or
                             (lvl > 3  and 0.08) or 0.06                
                local totalDmg = qMod * (target.MaxHealth - target.Health)
                if target.IsMonster then totalDmg = min(360, totalDmg) end
                return { RawMagical = totalDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({60, 100, 140, 180, 220}, lvl) + 0.9 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 250, 350}, lvl) + source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Varus'] = {
        ['VarusQCast'] = {
            ['Default'] = spellDamages['Varus'][SpellSlots.Q]['Default'],
        },
        ['VarusE'] = {
            ['Default'] = spellDamages['Varus'][SpellSlots.E]['Default'],
        },
        ['VarusR'] = {
            ['Default'] = spellDamages['Varus'][SpellSlots.R]['Default'],
        },
    }

    staticPassiveDamages["Varus"] =  {
        [1] = {
            Name = "Varus",
            Func = function(res, source, isMinionTarget)
                local wLvl = source:GetSpell(SpellSlots.W).Level
                if wLvl > 0 then
                    local dmg = (3.5 + 5 * wLvl) + (0.3 * source.TotalAP)
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.10] Vayne                                                                          |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Vayne"] then
    spellDamages["Vayne"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = (0.55 + 0.05 * lvl) * source.TotalAD
                return { RawPhysical = rawDmg + source.TotalAD, ApplyOnHit = true }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local wLvl = source:GetSpell(SpellSlots.W).Level
                local wPassivedmg = target.MaxHealth * (0.02 + 0.02 * wLvl)
                local minDmg = 35 + (15 * wLvl)

                wPassivedmg = max(minDmg, wPassivedmg)
                if target.IsMonster then
                    wPassivedmg = min(200, wPassivedmg)
                end
                return { RawTrue = wPassivedmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({50, 85, 120, 155, 190}, lvl) + 0.5 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
            ["Detonation"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({75, 127.5, 180, 232.5, 285}, lvl) + 0.75 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Vayne'] = {
        ['VayneCondemnMissile'] = {
            ['Default'] = spellDamages['Vayne'][SpellSlots.E]['Default'],
        },
    }

    staticPassiveDamages["Vayne"] =  {
        [1] = {
            Name = "Vayne",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("vaynetumblebonus") then
                    local dmg = spellDamages.Vayne[SpellSlots.Q].Default(source).RawPhysical
                    res.FlatPhysical = res.FlatPhysical + (dmg - source.TotalAD)
                end
            end
        }
    }

    dynamicPassiveDamages["Vayne"] = {
        [1] = {
            Name = "Vayne",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                local buff = aiTarget and aiTarget:GetBuff("VayneSilveredDebuff")
                if buff and buff.Count == 2 then
                    local dmg = spellDamages.Vayne[SpellSlots.W].Default(source, target).RawTrue
                    if dmg > 200 and aiTarget.IsMonster then dmg = 200 end
                    res.FlatTrue = res.FlatTrue + dmg
                end
            end,
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Veigar                                                                         |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Veigar"] then
    spellDamages["Veigar"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({80, 120, 160, 200, 240}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({100, 150, 200, 250, 300}, lvl) + source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({175, 250, 325}, lvl) + 0.75 * source.TotalAP
                local bonusDmg = 1.5 * min(1 - target.HealthPercent, 0.66)
                return { RawMagical = rawDmg + rawDmg * bonusDmg }
            end,
        },
    }

    spellData['Veigar'] = {
        ['VeigarBalefulStrike'] = {
            ['Default'] = spellDamages['Veigar'][SpellSlots.Q]['Default'],
        },
        ['VeigarDarkMatter'] = {
            ['Default'] = spellDamages['Veigar'][SpellSlots.W]['Default'],
        },
        ['VeigarR'] = {
            ['Default'] = spellDamages['Veigar'][SpellSlots.R]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.8] Velkoz                                                                         |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Velkoz"] then
    spellDamages["Velkoz"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({80, 120, 160, 200, 240}, lvl) + 0.9 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({30, 50, 70, 90, 110}, lvl) + 0.20 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["Detonation"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({45, 75, 105, 135, 165}, lvl) + 0.25 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({70, 100, 130, 160, 190}, lvl) + 0.3 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({34.62, 48.08, 61.54}, lvl) + 0.0962 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Velkoz'] = {
        ['VelkozQ'] = {
            ['Default'] = spellDamages['Velkoz'][SpellSlots.Q]['Default'],
        },
        ['VelkozQSplit'] = {
            ['Default'] = spellDamages['Velkoz'][SpellSlots.Q]['Default'],
        },
        ['VelkozW'] = {
            ['Default'] = spellDamages['Velkoz'][SpellSlots.W]['Default'],
        },
        ['VelkozE'] = {
            ['Default'] = spellDamages['Velkoz'][SpellSlots.E]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.19] Vex                                                                            |
--| Last Update: 05.10.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Vex"] then
    spellDamages["Vex"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({60, 105, 150, 195, 240}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg, ApplyPassives = true }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({80, 120, 160, 200, 240}, lvl) + 0.3 * source.TotalAP
                return { RawMagical = rawDmg, ApplyPassives = true }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({50, 70, 90, 110, 130}, lvl) + GetDamageByLvl({0.4, 0.45, 0.5, 0.55, 0.6}, lvl) * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({75, 125, 175}, lvl) + 0.2 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["SecondCast"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 250, 350}, lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    dynamicPassiveDamages["Vex"] = {
        [1] = {
            Name = "Vex",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if aiTarget and aiTarget:GetBuff("vexpgloom") then
                    local dmg = 30 + 110 / 17 * (source.Level - 1) + 0.2 * source.TotalAP
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Vi                                                                             |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Vi"] then
    spellDamages["Vi"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({55, 80, 105, 130, 155}, lvl) + 0.7 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = ((0.025 + 0.015 * lvl) + (0.01 * (source.BonusAD / 35))) * target.MaxHealth
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = (-10 + 20 * lvl) + (0.1 * source.TotalAD) + (0.9 * source.TotalAP)
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 325, 500}, lvl) + 1.1 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Vi'] = {
        ['ViQMissile'] = {
            ['Default'] = spellDamages['Vi'][SpellSlots.Q]['Default'],
        },
        ['ViR'] = {
            ['Default'] = spellDamages['Vi'][SpellSlots.R]['Default'],
        },
    }

    dynamicPassiveDamages["Vi"] = {
        [1] = {
            Name = "Vi",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end
                local buff = aiTarget:GetBuff("viwproc")
                if buff and buff.Count == 2 then
                    local dmg = spellDamages.Vi[SpellSlots.W].Default(source, target).RawPhysical
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        }
    }

    staticPassiveDamages["Vi"] = {
        [1] = {
            Name = "Vi",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("vie") then
                    local dmg = spellDamages.Vi[SpellSlots.E].Default(source).RawPhysical
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.22] Viego                                                                          |
--| Last Update: 10.11.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Viego"] then
    spellDamages["Viego"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({15, 30, 45, 60, 75}, lvl) + 0.7 * source.TotalAD
                return { RawPhysical = rawDmg + (rawDmg * source.CritChance) }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({80, 135, 190, 245, 300}, lvl) + 1 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local missingHealth = (target.MaxHealth - target.Health)
                local adMod = 0.03 / 100 * source.BonusAD
                local missingHealthDmg = (GetDamageByLvl({0.15, 0.20, 0.25}, lvl) + adMod) * missingHealth
                local rawDmg = 1.2 * source.TotalAD
                return { RawPhysical = rawDmg + (rawDmg * source.CritChance) + missingHealthDmg }
            end,
        },
    }

    dynamicPassiveDamages["Viego"] = {
        [1] = {
            Name = "Viego",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end
                local lvl = source:GetSpell(SpellSlots.Q).Level
                if lvl > 0 then
                    local minDmg = GetDamageByLvl({10, 15, 20, 25, 30}, lvl)
                    local dmg = GetDamageByLvl({0.02,  0.03,  0.04,  0.05, 0.06}, lvl) * target.Health
                    dmg = math.max(minDmg, dmg)
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        },
        [2] = {
            Name = "Viego",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end
                local buff = aiTarget:GetBuff("viegoqmark")
                local lvl = source:GetSpell(SpellSlots.Q).Level
                if buff then
                    local dmg = 0.2 * source.TotalAD + 0.15 * source.TotalAP
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Viktor                                                                         |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Viktor"] then
    spellDamages["Viktor"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({60, 75, 90, 105, 120}, lvl) + 0.4 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["SecondCast"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({20, 45, 70, 95, 120}, lvl) + source.TotalAD + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({70, 110, 150, 190, 230}, lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({20, 50, 80, 110, 140}, lvl) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({100, 175, 250}, lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["DamagePerSecond"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({65, 105, 145}, lvl) + 0.45 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Viktor'] = {
        ['ViktorE'] = {
            ['Default'] = spellDamages['Viktor'][SpellSlots.E]['Default'],
        },
        ['ViktorEExplosion'] = {
            ['Default'] = spellDamages['Viktor'][SpellSlots.E]['Empowered'],
        },
        ['ViktorPowerTransfer'] = {
            ['Default'] = spellDamages['Viktor'][SpellSlots.Q]['Default'],
        },
    }

    dynamicPassiveDamages["Viktor"] = {
        [1] = {
            Name = "Viktor",
            Func = function(res, source, target)
                if target.IsStructure then return end
                if source:GetBuff("viktorpowertransferreturn") then
                    local dmg = spellDamages.Viktor[SpellSlots.Q].SecondCast(source, target).RawMagical
                    res.FlatMagical = res.FlatMagical + (dmg - source.TotalAD)
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Vladimir                                                                       |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Vladimir"] then
    spellDamages["Vladimir"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({80, 100, 120, 140, 160}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({148, 185, 222, 259, 296}, lvl) + 1.11 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({20, 33.75, 47.5, 61.25, 75}, lvl) + 0.025 * source.BonusHealth
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({30, 45, 60, 75, 90}, lvl) + 0.015 * source.MaxHealth + 0.35 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 250, 350}, lvl) + 0.7 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Vladimir'] = {
        ['VladimirQ'] = {
            ['Default'] = spellDamages['Vladimir'][SpellSlots.Q]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Volibear                                                                       |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Volibear"] then
    spellDamages["Volibear"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = (0 + 20 * lvl) + (1.2 * source.BonusAD)
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local pDmg = GetDamageByLvl({ 11, 12, 13, 15, 17, 19, 22, 25, 28, 31, 34, 37, 40, 44, 48, 52, 56, 60 }, source.Level)
                local rawDmg = pDmg + (0.4 * source.TotalAP)
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({80, 110, 140, 170, 200}, lvl) + 0.8 * source.TotalAP + (0.1 + 0.01 * lvl) * target.MaxHealth
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({300, 500, 700}, lvl) + 2.5 * source.BonusAD + 1.25 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Volibear'] = {
        ['VolibearW'] = {
            ['Default'] = spellDamages['Volibear'][SpellSlots.W]['Default'],
        },
    }

    staticPassiveDamages["Volibear"] = {
        [1] = {
            Name = "Volibear",
            Func = function(res, source, isMinionTarget)
                local buff = source:GetBuff("volibearpstacktracker")
                if buff and buff.Count >= 4 then
                    local dmg = spellDamages.Volibear[SpellSlots.W].Default(source).RawMagical
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end
        },
        [2] = {
            Name = "Volibear",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("volibearq") then
                    local dmg = spellDamages.Volibear[SpellSlots.Q].Default(source).RawPhysical
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.25] Warwick                                                                        |
--| Last Update: 22.12.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Warwick"] then
    spellDamages["Warwick"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = 1.2 * source.TotalAD + source.TotalAP + (0.05 + 0.01 * lvl) * target.MaxHealth
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({175, 350, 525}, lvl) + 1.67 * source.BonusAD
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Warwick'] = {
        ['WarwickR'] = {
            ['Default'] = spellDamages['Warwick'][SpellSlots.R]['Default'],
        },
        ['WarwickQ'] = {
            ['Default'] = spellDamages['Warwick'][SpellSlots.Q]['Default'],
        },  
    }

    staticPassiveDamages["Warwick"] = {
        [1] = {
            Name = "Warwick",
            Func = function(res, source, isMinionTarget)
                local dmg = 10 + 2 * source.Level + 0.15 * source.BonusAD + 0.10 * source.TotalAP
                res.FlatMagical = res.FlatMagical + dmg
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.8] Xayah                                                                           |
--| Last Update: 25.08.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Xayah"] then
    spellDamages["Xayah"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({45, 60, 75, 90, 105}, lvl) + 0.5 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({55, 65, 75, 85, 95}, lvl) + 0.6 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({200, 300, 400}, lvl) + source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Xayah'] = {
        ['XayahQ'] = {
            ['Default'] = spellDamages['Xayah'][SpellSlots.Q]['Default'],
        },
        ['XayahE_Wrap'] = {
            ['Default'] = spellDamages['Xayah'][SpellSlots.E]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.9] Xerath                                                                          |
--| Last Update: 30.04.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Xerath"] then
    spellDamages["Xerath"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({70, 110, 150, 190, 230}, lvl) + 0.85 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({60, 95, 130, 165, 200}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({100.02, 150.03, 200.04, 250.05, 300.06}, lvl) + 1.02 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({80, 110, 140, 170, 200}, lvl) + 0.45 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({200, 250, 300}, lvl) + 0.45 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Xerath'] = {
        ['XerathArcanopulse2'] = {
            ['Default'] = spellDamages['Xerath'][SpellSlots.Q]['Default'],
        },
        ['XerathArcaneBarrage2'] = {
            ['Default'] = spellDamages['Xerath'][SpellSlots.W]['Default'],
        },
        ['XerathMageSpear'] = {
            ['Default'] = spellDamages['Xerath'][SpellSlots.E]['Default'],
        },
        ['XerathRMissileWrapper'] = {
            ['Default'] = spellDamages['Xerath'][SpellSlots.R]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.11] XinZhao                                                                        |
--| Last Update: 23.06.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["XinZhao"] then
    spellDamages["XinZhao"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = (7 + 9 * lvl) + (0.4 * source.BonusAD)
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({30, 40, 50, 60, 70}, lvl) + 0.3 * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
            ["SecondCast"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({50, 85, 120, 155, 190}, lvl) + 0.9 * source.TotalAD + 0.65 * source.TotalAP
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({50, 75, 100, 125, 150}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({75, 175, 275}, lvl) + source.BonusAD + 1.1 * source.TotalAP + 0.15 * target.Health
                return { RawPhysical = rawDmg }
            end,
        },
    }

    staticPassiveDamages["XinZhao"] = {
        [1] = {
            Name = "XinZhao",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("xinzhaoq") then
                    local dmg = spellDamages.XinZhao[SpellSlots.Q].Default(source).RawPhysical
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.2] Yasuo                                                                           |
--| Last Update: 21.01.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Yasuo"] then
    spellDamages["Yasuo"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({20, 45, 70, 95, 120}, lvl) + 1.05 * source.TotalAD
                return { RawPhysical = rawDmg, ApplyOnHit = true, ApplyOnAttack = true }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({60, 70, 80, 90, 100}, lvl) + 0.2 * source.BonusAD + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({200, 350, 500}, lvl) + 1.5 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Yasuo'] = {
        ['YasuoQ1'] = {
            ['Default'] = spellDamages['Yasuo'][SpellSlots.Q]['Default'],
        },
        ['YasuoQ3'] = {
            ['Default'] = spellDamages['Yasuo'][SpellSlots.Q]['Default'],
        },
        ['YasuoE'] = {
            ['Default'] = spellDamages['Yasuo'][SpellSlots.E]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.2] Yone                                                                            |
--| Last Update: 21.01.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Yone"] then
    spellDamages["Yone"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({20, 40, 60, 80, 100}, lvl) + 1.05 * source.TotalAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({10, 20, 30, 40, 50}, lvl) + (0.1 + 0.01 * lvl) * target.MaxHealth
                return { RawPhysical = rawDmg * 0.5, RawMagical = rawDmg * 0.5 }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({200, 400, 600}, lvl) + 0.8 * source.TotalAD
                return { RawPhysical = rawDmg * 0.5, RawMagical = rawDmg * 0.5 }
            end,
        },
    }

    spellData['Yone'] = {
        ['YoneQ'] = {
            ['Default'] = spellDamages['Yone'][SpellSlots.Q]['Default'],
        },
        ['YoneQ3'] = {
            ['Default'] = spellDamages['Yone'][SpellSlots.Q]['Default'],
        },
        ['YoneW'] = {
            ['Default'] = spellDamages['Yone'][SpellSlots.W]['Default'],
        },
        ['YoneR'] = {
            ['Default'] = spellDamages['Yone'][SpellSlots.R]['Default'],
        },
    }

    -- //TODO: Add Yone Passive
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Yorick                                                                         |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Yorick"] then
    spellDamages["Yorick"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = (5 + 25 * lvl) + (0.4 * source.TotalAD)
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local minDmg = GetDamageByLvl({70, 105, 140, 175, 210}, lvl) + 0.7 * source.TotalAP
                local rawDmg = min(minDmg, 0.15 * target.Health)
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Yorick'] = {
        ['YorickE'] = {
            ['Default'] = spellDamages['Yorick'][SpellSlots.E]['Default'],
        },
    }

    staticPassiveDamages["Yorick"] = {
        [1] = {
            Name = "Yorick",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("yorickqbuff") then
                    local dmg = spellDamages.Yorick[SpellSlots.Q].Default(source).RawPhysical
                    res.FlatPhysical = res.FlatPhysical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.12] Zeri                                                                           |
--| Last Update: 23.06.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Zeri"] then
    spellDamages["Zeri"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({8, 11, 14, 17, 20}, lvl)
                local bonusDmg = GetDamageByLvl({1.10, 1.15, 1.20, 1.25, 1.30}, lvl) * source.TotalAD
                return { RawPhysical = rawDmg + bonusDmg, ApplyOnHit = true, ApplyOnAttack = true }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({20, 55, 90, 125, 160}, lvl) + 1.3 * source.TotalAD + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({150, 250, 350}, lvl) + 0.8 * source.BonusAD + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.10] Yuumi                                                                          |
--| Last Update: 16.05.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Yuumi"] then
    spellDamages["Yuumi"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({50, 80, 110, 140, 170, 200}, lvl) + 0.3 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
            ["Empowered"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({60, 100, 140, 180, 220, 260}, lvl) + 0.4 * source.TotalAP + (0.008 + 0.012 * lvl) * target.Health
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({60, 80, 100}, lvl) + 0.2 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Yuumi'] = {
        ['YuumiR'] = {
            ['Default'] = spellDamages['Yuumi'][SpellSlots.R]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.8] Zac                                                                             |
--| Last Update: 16.04.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Zac"] then
    spellDamages["Zac"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({40, 55, 70, 85, 100}, lvl) + 0.3 * source.TotalAP + 0.025 * source.MaxHealth
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({35, 50, 65, 80, 95}, lvl) + ((0.03 + 0.01 * lvl) + (0.04 * (source.TotalAP / 100))) * target.MaxHealth
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({60, 110, 160, 210, 260}, lvl) + 0.9 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({140, 210, 280}, lvl) + 0.4 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Zac'] = {
        ['ZacQ'] = {
            ['Default'] = spellDamages['Zac'][SpellSlots.Q]['Default'],
        },
        ['ZacE2'] = {
            ['Default'] = spellDamages['Zac'][SpellSlots.E]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.17] Zed                                                                             |
--| Last Update: 25.08.2021                                                                 |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Zed"] then
    spellDamages["Zed"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({80, 115, 150, 185, 220}, lvl) + 1.1*source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({70, 90, 110, 130, 150}, lvl) + 0.65 * source.BonusAD
                return { RawPhysical = rawDmg }
            end,
        },
    }

    spellData['Zed'] = {
        ['ZedQ'] = {
            ['Default'] = spellDamages['Zed'][SpellSlots.Q]['Default'],
        },
    }

    dynamicPassiveDamages["Zed"] = {
        [1] = {
            Name = "Zed",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end
                if not aiTarget:GetBuff("zedpassivecd") and aiTarget.HealthPercent < 0.5 then
                    local lvl = source.Level
                    local dmgPct = (lvl < 7 and 0.06) or (lvl < 17 and 0.08) or 0.1
                    local dmg = aiTarget.MaxHealth * dmgPct
                    if target.IsMonster then
                        dmg = min(dmg, 300)
                    end
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.12] Ziggs                                                                          |
--| Last Update: 14.06.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Ziggs"] then
    spellDamages["Ziggs"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({85, 135, 185, 235, 285}, lvl) + 0.65 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({70, 105, 140, 175, 210}, lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({40, 75, 110, 145, 180}, lvl) + 0.3 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({200, 300, 400}, lvl) + 0.7333 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Ziggs'] = {
        ['ZiggsQ'] = {
            ['Default'] = spellDamages['Ziggs'][SpellSlots.Q]['Default'],
        },
        ['ZiggsQBounce'] = {
            ['Default'] = spellDamages['Ziggs'][SpellSlots.Q]['Default'],
        },
        ['ZiggsW'] = {
            ['Default'] = spellDamages['Ziggs'][SpellSlots.W]['Default'],
        },
        ['ZiggsE'] = {
            ['Default'] = spellDamages['Ziggs'][SpellSlots.E]['Default'],
        },
        ['ZiggsR'] = {
            ['Default'] = spellDamages['Ziggs'][SpellSlots.R]['Default'],
        },
    }

    dynamicPassiveDamages["Ziggs"] = {
        [1] = {
            Name = "Ziggs",
            Func = function(res, source, target)
                if source:GetBuff("ziggsshortfuse") then
                    local aiTarget = target.AsAI
                    if not aiTarget then return end
                    local pDmg = GetDamageByLvl({ 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 80, 88, 100, 112, 124, 136, 148, 160 }, source.Level)
                    local dmg = pDmg + (0.5 * source.TotalAP)
                    if target.IsStructure then
                        dmg = dmg + (dmg * 0.5)
                    end
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Zilean                                                                         |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Zilean"] then
    spellDamages["Zilean"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({75, 115, 165, 230, 300}, lvl) + 0.9 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Zilean'] = {
        ['ZileanQ'] = {
            ['Default'] = spellDamages['Zilean'][SpellSlots.Q]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Zoe                                                                            |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Zoe"] then
    spellDamages["Zoe"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local addDamage = GetDamageByLvl({7, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 29, 32, 35, 38, 42, 46, 50}, source.Level)
                local rawDmg = GetDamageByLvl({50, 80, 110, 140, 170}, lvl) + addDamage + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({25, 35, 45, 55, 65}, lvl) + 0.133 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({60, 100, 140, 180, 220}, lvl) + 0.4 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Zoe'] = {
        ['ZoeQ'] = {
            ['Default'] = spellDamages['Zoe'][SpellSlots.Q]['Default'],
        },
        ['ZoeQ2'] = {
            ['Default'] = spellDamages['Zoe'][SpellSlots.Q]['Default'],
        },
        ['ZoeE'] = {
            ['Default'] = spellDamages['Zoe'][SpellSlots.E]['Default'],
        },
    }

    staticPassiveDamages["Zoe"] = {
        [1] = {
            Name = "Zoe",
            Func = function(res, source, isMinionTarget)
                if source:GetBuff("zoepassivesheenbuff") then
                    local pDmg = GetDamageByLvl({ 16, 20, 24, 28, 32, 36, 42, 48, 54, 60, 66, 74, 82, 90, 100, 110, 120, 130 }, source.Level)
                    local dmg = pDmg + (0.2 * source.TotalAP)
                    res.FlatMagical = res.FlatMagical + dmg
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [10.24] Zyra                                                                           |
--| Last Update: 24.11.2020                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Zyra"] then
    spellDamages["Zyra"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({60, 95, 130, 165, 200}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({60, 105, 150, 195, 240}, lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({180, 265, 350}, lvl) + 0.7 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Zyra'] = {
        ['ZyraQ'] = {
            ['Default'] = spellDamages['Zyra'][SpellSlots.Q]['Default'],
        },
        ['ZyraE'] = {
            ['Default'] = spellDamages['Zyra'][SpellSlots.E]['Default'],
        },
        ['ZyraR'] = {
            ['Default'] = spellDamages['Zyra'][SpellSlots.R]['Default'],
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [11.3] Rell                                                                            |
--| Last Update: 11.03.2021                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Rell"] then
    spellDamages["Rell"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({70, 105, 140, 175, 210}, lvl) + 0.5 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({70, 105, 140, 175, 210}, lvl) + 0.6 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({80, 120, 160, 200, 240}, lvl) + 0.4 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = GetDamageByLvl({15, 25, 35}, lvl) + 0.1375 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    spellData['Rell'] = {
        ['RellQ'] = {
            ['Default'] = spellDamages['Rell'][SpellSlots.Q]['Default'],
        },
        ['RellW_Dismount'] = {
            ['Default'] = spellDamages['Rell'][SpellSlots.W]['Default'],
        },
        ['RellR'] = {
            ['Default'] = spellDamages['Rell'][SpellSlots.R]['Default'],
        },
    }

    staticPassiveDamages["Rell"] = {
        [1] = {
            Name = "Rell",
            Func = function(res, source, isMinionTarget)
                local dmg = 7.53 + 0.47 * source.Level
                if source:GetBuff("RellWEmpoweredAttack") then
                    local wLvl = source:GetSpell(SpellSlots.W).Level
                    dmg = dmg + (-5 + 15 * wLvl + 0.4 * source.TotalAP)                    
                end
                res.FlatMagical = res.FlatMagical + dmg
            end
        },
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.9] Renata                                                                          |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Renata"] then
    spellDamages["Renata"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({80, 125, 170, 215, 260}, lvl) + 0.8 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = GetDamageByLvl({65, 95, 125, 155, 185}, lvl) + 0.55 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
    }

    dynamicPassiveDamages["Renata"] = {
        [1] = {
            Name = "Renata",
            Func = function(res, source, target)
                local aiTarget = target.AsAI
                if not aiTarget then return end

                local buff = aiTarget:GetBuff("RenataPassiveDebuff")
                local dmg = ((0.875 + 0.125 * source.Level) * 0.01 + (0.02 / 100 * source.TotalAP)) * aiTarget.MaxHealth

                if source.CharName == "Renata" then
                    if not buff then
                        res.FlatMagical = res.FlatMagical + dmg
                    end
                else
                    if buff then
                        res.FlatMagical = res.FlatMagical + dmg
                    end
                end
            end
        }
    }
end

--//////////////////////////////////////////////////////////////////////////////////////////
--| [12.12] Belveth                                                                        |
--| Last Update: 23.06.2022                                                                |
--\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if IsInGame["Belveth"] then
    spellDamages["Belveth"] = {
        [SpellSlots.Q] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.Q).Level
                local rawDmg = GetDamageByLvl({10, 15, 20, 25, 30}, lvl) + 1.1 * source.TotalAD
                if target.IsMonster then
                    rawDmg = rawDmg * 1.2
                elseif target.IsLaneMinion then
                    rawDmg = rawDmg * GetDamageByLvl({0.60, 0.70, 0.80, 0.90, 1}, lvl)
                end
                return { RawPhysical = rawDmg, ApplyOnHit = true, ApplyOnAttack = true, ApplyOnHitPercent = 0.75 }
            end,
        },
        [SpellSlots.W] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.W).Level
                local rawDmg = GetDamageByLvl({70, 110, 150, 190, 230}, lvl) + source.BonusAD + 1.25 * source.TotalAP
                return { RawMagical = rawDmg }
            end,
        },
        --WIP
        [SpellSlots.E] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.E).Level
                local rawDmg = 0
                return { RawPhysical = rawDmg }
            end,
        },
        --WIP
        [SpellSlots.R] = {
            ["Default"] = function(source, target)
                local lvl = source:GetSpell(SpellSlots.R).Level
                local rawDmg = 0
                return { RawPhysical = rawDmg }
            end,
        },
    }
end

for handle, hero in pairs(ObjectManager.Get("all", "heroes")) do
    if spellData[hero.CharName] then
        spellData[hero.CharName]['SummonerDot'] = {
            ['Default'] = function(source, target, buff)
                local duration = buff.EndTime - Game.GetTime()
                local rawDmg = 10 + 4 * source.Level
                return { RawTrue = rawDmg * duration }
            end,
            ['TotalDamage'] = function(source, target, buff)
                local rawDmg = 50 + 20 * source.Level
                return { RawMagical = rawDmg }
            end,
        }
    end
end

Init()
_G.Libs.DamageLib = DamageLib
_G.Libs.DamageLib.SpellDamages = spellDamages
return DamageLib
