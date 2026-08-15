---- ════════════════════════════════════════════════════════════════
----        Copyright © WITHVOIDWITHIN — All rights reserved.
----         https://steamcommunity.com/id/withvoidwithin/
----               https://withvoidwithin.github.io/
---- ════════════════════════════════════════════════════════════════

---- Store — Usage Guide
---- ================================================================================================================================
--[[
    SERVER ONLY.  A small component store:  store[component_name][key] = value  (data/store.lua)

    StoreAPI is stateless helpers over that table. Each component is a module in data/components/
    wrapping them with typed methods; it owns its key shape and its NetworkedMask, and call sites
    never touch StoreAPI directly. A masked component mirrors the masked slice of its value to the
    CustomNetTable "component.<name>" under the same key.

    ── API ─────────────────────────────────────────────────────────────────────────────
        Set(store, name, key, value, mask)             write the value, then publish it
        Get(store, name, key)                          the stored table itself, not a copy
        Publish(store, name, key, changed_key, mask)   publish again; returns at once if
                                                       changed_key is not in the mask

        Since Get hands out the stored table, mutating it IS the write — follow the mutation
        with Publish naming the top-level key you touched. Set is for a value that is not
        there yet (Component.New) or a full replacement.

    ── Add a component ─────────────────────────────────────────────────────────────────
        1) data/components/<name>.lua

            local Component     = {}
            local ComponentName = "<name>"
            local Store         = require("data.store")
            local StoreAPI      = require("core.store_api")

            --- @type _StoreAPI_NetworkedMask
            local NetworkedMask = { score = true }      -- omit for a server-only component

            local function Key(player_id) return "player_"..player_id end

            local function Publish(player_id, changed_key)
                StoreAPI.Publish(Store, ComponentName, Key(player_id), changed_key, NetworkedMask)
            end

            function Component.New(player_id)
                return StoreAPI.Set(Store, ComponentName, Key(player_id), { score = 0 }, NetworkedMask)
            end

            function Component.Get(player_id)
                return StoreAPI.Get(Store, ComponentName, Key(player_id))
            end

            function Component.AddScore(player_id, amount)
                local data = Component.Get(player_id)

                data.score = data.score + amount

                Publish(player_id, "score")
            end

            return Component

        2) A masked component needs its NetTable declared in scripts/custom_net_tables.txt:

            custom_net_tables =
            [
                "component.<name>",
            ]

        3) Use it (server):

            local PlayerAccount = require("data.components.player.account")
            PlayerAccount.New(player_id)
            local data = PlayerAccount.Get(player_id)

    ── NetworkedMask ───────────────────────────────────────────────────────────────────
        Decides what leaves the server.

            nil        server-only, nothing is written to a NetTable
            true       the whole value
            table      per field — true takes the field with its whole subtree, a nested
                       table descends into it, "*" covers every key without an entry of
                       its own (that is how maps keyed by a uid are described)

            local NetworkedMask = {
                account = {
                    collection = { ["*"] = { fragments = true } },
                    heroes     = { ["*"] = { uid = true, hero_name = true } },
                },
            }

        - Whitelist: an unlisted field never leaves the server, and a typo excludes a field
          just as silently. Keep the mask next to the --- @class it describes.
        - What passes is copied; an entity handle is written as its EntityIndex.
        - A NetTable is broadcast to every client — the mask is not per-player privacy.
        - Descending into a field that holds no table raises on the next write.

    Columns are created on first write; data survives hot-reload (kept on _G._STORE).
]]

--- @class _StoreAPI
local StoreAPI = {}

---- Main
---- ================================================================================================================================

--- @param value any
--- @return any
local function ToNetworkedValue(value)
    if type(value) ~= "table" then return value end
    if IsValidEntity(value) then return value:GetEntityIndex() end

    local result = {}

    for key, field in pairs(value) do result[key] = ToNetworkedValue(field) end

    return result
end

--- @param value any
--- @param mask true|_StoreAPI_NetworkedMask
--- @return any
local function ApplyNetworkedMask(value, mask)
    if mask == true then return ToNetworkedValue(value) end

    local result   = {}
    local wildcard = mask["*"]

    for key, field in pairs(value) do
        local field_mask = mask[key] or wildcard

        if field_mask == true then result[key] = ToNetworkedValue(field)
        elseif type(field_mask) == "table" then
            assert(type(field) == "table",
                "[store_api] NetworkedMask descends into a field that holds no table: "..tostring(key))

            result[key] = ApplyNetworkedMask(field, field_mask)
        end
    end

    return result
end

--- @param store _Store
--- @param component_name string
--- @param ent_index string
--- @param value any
--- @param networked_mask? true|_StoreAPI_NetworkedMask
function StoreAPI.Set(store, component_name, ent_index, value, networked_mask)
    local index = tostring(ent_index)

    store[component_name] = store[component_name] or {}
    store[component_name][index] = value

    if networked_mask then
        CustomNetTables:SetTableValue("component."..component_name, index, ApplyNetworkedMask(value, networked_mask))
    end

    return value
end

--- @param store _Store
--- @param component_name string
--- @param ent_index string
--- @param changed_key string
--- @param networked_mask? true|_StoreAPI_NetworkedMask
function StoreAPI.Publish(store, component_name, ent_index, changed_key, networked_mask)
    if not networked_mask then return end
    if networked_mask ~= true and not (networked_mask[changed_key] or networked_mask["*"]) then return end

    local index = tostring(ent_index)

    CustomNetTables:SetTableValue("component."..component_name, index,
        ApplyNetworkedMask(store[component_name][index], networked_mask))
end

--- @param store _Store
--- @param component_name string
--- @param ent_index string
function StoreAPI.Get(store, component_name, ent_index)
    local component = store[component_name]

    return component and component[tostring(ent_index)]
end

return StoreAPI

---- Annotations
---- ================================================================================================================================

--- @class _Store: {[string]: {[string]: any}}

--- @class _StoreAPI_NetworkedMask: {[string]: true|_StoreAPI_NetworkedMask}