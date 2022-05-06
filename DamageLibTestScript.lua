local SDK               = _G.CoreEx
local DamageLib         = _G.Libs.DamageLib
local ObjectManager     = SDK.ObjectManager
local EventManager      = SDK.EventManager
local Input             = SDK.Input
local Game              = SDK.Game
local Geometry          = SDK.Geometry
local Renderer          = SDK.Renderer
local Enums             = SDK.Enums
local Events            = Enums.Events
local SpellSlots        = Enums.SpellSlots
local SpellStates       = Enums.SpellStates
local HitChance         = Enums.HitChance
local Vector            = Geometry.Vector

local stages = { [0] = {}, [1] = {}, [2] = {}, [3] = {} }
local data = DamageLib.SpellDamages[Player.CharName]
if not data then return end
for slot = 0, 3 do
    if data[slot] then
        for stage, v in pairs(data[slot]) do
            table.insert(stages[slot], stage)
        end
    end
end

EventManager.RegisterCallback(Events.OnDraw, function()
    local heroes = ObjectManager.Get("enemy", "heroes")
    for i, hero in pairs(heroes) do
        local hero = hero.AsAI
        if hero and hero.IsOnScreen then
            local damageInfo = { [0] = "Q -> ", [1] = "W -> ", [2] = "E -> ", [3] = "R -> " }
            local position = Renderer.WorldToScreen(hero.Position)
            for slot = 0, 3 do
                local lvl = Player:GetSpell(slot).Level
                for k, stage in pairs(stages[slot]) do
                    local damage = DamageLib.GetSpellDamage(Player, hero, slot, stage)
                    if damageInfo[slot] and lvl > 0 then
                        local last = #stages[slot] == k and "" or "  |  "
                        damageInfo[slot] = damageInfo[slot] .. (stage .. ": " .. damage) .. last
                    end
                end
            end
            local aaDamage = DamageLib.GetAutoAttackDamage(Player, hero, true)
            Renderer.DrawText(position + Vector(60, -20), Vector(1000, 20), "AA -> " .. aaDamage, 0xffffffff)
            for slot = 0, #damageInfo do
                local damage = damageInfo[slot]
                if damage then
                    Renderer.DrawText(position + Vector(60, slot * 20), Vector(1000, 20), damage, 0xffffffff)
                end
            end
        end
    end
end)