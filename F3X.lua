
local SERVER_URL = "https://marita-streetless-shani.ngrok-free.dev"  
local SYNC_INTERVAL = 3     
local UPDATE_DEBOUNCE = 3    

local EXPERIENCE_ID = tostring(game.PlaceId)
print("[F3X Sync] Experience ID: " .. EXPERIENCE_ID)

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer


local nativeRequest = (syn and syn.request) or http_request or request or (http and http.request)

if not nativeRequest then
    warn("[F3X Sync] Nenhuma função de request nativa encontrada. Usando fallback HttpService:RequestAsync (pode falhar em mobile).")
end

local function httpRequest(method, url, body)
    if not nativeRequest then
        local ok, result = pcall(function()
            return HttpService:RequestAsync({
                Url = url,
                Method = method,
                Headers = { ["Content-Type"] = "application/json" },
                Body = body,
            })
        end)
        if ok and result then
            return (result.Success ~= false), result.Body
        end
        return false, result
    end

    local ok, response = pcall(function()
        return nativeRequest({
            Url = url,
            Method = method,
            Headers = { ["Content-Type"] = "application/json" },
            Body = body,
        })
    end)

    if not ok then
        return false, response
    end

    if response and (response.StatusCode == 200 or response.Success) then
        return true, response.Body
    end

    return false, (response and response.Body) or "sem resposta do servidor"
end


local localParts = {}          
local serverParts = {}       
local partUpdateCooldowns = {} 
local connectedParts = {}     
local processedParts = {}     
local ignoredInstances = {}   

local function countTable(t)
    local n = 0
    for _ in pairs(t) do n += 1 end
    return n
end



local function getGroupId(part)
    local ancestor = part.Parent
    while ancestor and ancestor ~= Workspace do
        if ancestor:IsA("Model") then
            local gid = ancestor:GetAttribute("F3XSyncGroupId")
            if gid then
                return gid, ancestor.Name
            end
        end
        ancestor = ancestor.Parent
    end
    return nil, nil
end

local function getOrCreateGroupModel(groupId, groupName)
    local cached = groupModelsCache[groupId]
    if cached and cached.Parent then
        return cached
    end

    local model = Instance.new("Model")
    model.Name = groupName or "SyncedGroup"
    model:SetAttribute("F3XSyncGroupId", groupId)
    model.Parent = Workspace

    groupModelsCache[groupId] = model
    ignoredInstances[model] = true
    return model
end



local function serializePart(part)
    local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = part.CFrame:GetComponents()

    local data = {
        ClassName = part.ClassName,
        Name = part.Name,
        Size = { part.Size.X, part.Size.Y, part.Size.Z },
        CFrame = { x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 },
        BrickColor = part.BrickColor and part.BrickColor.Name or "White",
        Material = part.Material and part.Material.Name or "SmoothPlastic",
        Transparency = part.Transparency,
        Reflectance = part.Reflectance,
        Anchored = part.Anchored,
        CanCollide = part.CanCollide,
        Color = { part.Color.R, part.Color.G, part.Color.B },
    }

    if part:IsA("Part") then
        data.Shape = part.Shape.Name
    end

    if part:IsA("MeshPart") then
        data.MeshId = part.MeshId
        data.TextureID = part.TextureID
    end

    local groupId, groupName = getGroupId(part)
    if groupId then
        data.GroupId = groupId
        data.GroupName = groupName
    end

    return data
end

local function deserializePart(data)
    local className = data.ClassName or "Part"
    local ok, part = pcall(Instance.new, className)
    if not ok or not part then
        warn("[F3X Sync] Classe desconhecida '" .. tostring(className) .. "', usando Part")
        part = Instance.new("Part")
    end

    part.Name = data.Name or "Part"
    part.Size = Vector3.new(data.Size[1] or 4, data.Size[2] or 1, data.Size[3] or 2)

    local c = data.CFrame
    part.CFrame = CFrame.new(
        c[1] or 0, c[2] or 0, c[3] or 0,
        c[4] or 1, c[5] or 0, c[6] or 0,
        c[7] or 0, c[8] or 1, c[9] or 0,
        c[10] or 0, c[11] or 0, c[12] or 1
    )

    part.BrickColor = BrickColor.new(data.BrickColor or "White")
    part.Material = Enum.Material[data.Material] or Enum.Material.SmoothPlastic
    part.Transparency = data.Transparency or 0
    part.Reflectance = data.Reflectance or 0
    part.Anchored = (data.Anchored == true)

    if data.CanCollide == nil then
        part.CanCollide = true
    else
        part.CanCollide = data.CanCollide
    end

    part.Color = Color3.new(data.Color[1] or 1, data.Color[2] or 1, data.Color[3] or 1)

    if data.Shape and part:IsA("Part") then
        part.Shape = Enum.PartType[data.Shape] or Enum.PartType.Block
    end

    if data.MeshId and part:IsA("MeshPart") then
        part.MeshId = data.MeshId
        if data.TextureID then part.TextureID = data.TextureID end
    end

    if data.GroupId then
        part.Parent = getOrCreateGroupModel(data.GroupId, data.GroupName)
    else
        part.Parent = Workspace
    end

    return part
end

local function applyServerDataToPart(part, data)
    local ok = pcall(function()
        part.Size = Vector3.new(data.Size[1], data.Size[2], data.Size[3])
        local c = data.CFrame
        part.CFrame = CFrame.new(
            c[1], c[2], c[3],
            c[4], c[5], c[6],
            c[7], c[8], c[9],
            c[10], c[11], c[12]
        )
        part.BrickColor = BrickColor.new(data.BrickColor or "White")
        part.Material = Enum.Material[data.Material] or Enum.Material.SmoothPlastic
        part.Transparency = data.Transparency or 0
        part.Reflectance = data.Reflectance or 0
        part.Anchored = (data.Anchored == true)
        part.CanCollide = (data.CanCollide ~= false)
        part.Color = Color3.new(data.Color[1], data.Color[2], data.Color[3])
    end)
    return ok
end

-- ================================================================
-- 5. COMUNICAÇÃO COM O SERVIDOR (COM EXPERIENCE_ID)
-- ================================================================

local function getPartsFromServer()
    local url = SERVER_URL .. "/parts?experienceId=" .. EXPERIENCE_ID
    local ok, body = httpRequest("GET", url, nil)
    if not ok then
        warn("[F3X Sync] Falha ao buscar partes do servidor: " .. tostring(body))
        return {}
    end
    local decOk, decoded = pcall(HttpService.JSONDecode, HttpService, body)
    if decOk and decoded and decoded.success then
        return decoded.parts or {}
    end
    return {}
end

local function sendPartToServer(partData)
    local body = HttpService:JSONEncode({
        experienceId = EXPERIENCE_ID,
        partData = partData
    })
    local ok, respBody = httpRequest("POST", SERVER_URL .. "/parts", body)
    if not ok then
        warn("[F3X Sync] Falha ao enviar parte: " .. tostring(respBody))
        return nil
    end
    local decOk, decoded = pcall(HttpService.JSONDecode, HttpService, respBody)
    if decOk then return decoded end
    return nil
end

local function updatePartOnServer(partId, partData)
    local body = HttpService:JSONEncode({
        experienceId = EXPERIENCE_ID,
        partData = partData
    })
    local ok, respBody = httpRequest("PUT", SERVER_URL .. "/parts/" .. partId, body)
    if not ok then
        warn("[F3X Sync] Falha ao atualizar parte: " .. tostring(respBody))
        return false, nil
    end
    local decOk, decoded = pcall(HttpService.JSONDecode, HttpService, respBody)
    if decOk and decoded and decoded.success then
        return true, decoded.part and decoded.part.version
    end
    return false, nil
end

local function deletePartOnServer(partId)
    local url = SERVER_URL .. "/parts/" .. partId .. "?experienceId=" .. EXPERIENCE_ID
    local ok, err = httpRequest("DELETE", url, nil)
    if not ok then
        warn("[F3X Sync] Falha ao deletar parte no servidor: " .. tostring(err))
        return false
    end
    return true
end

-- ================================================================
-- 6. CRIAÇÃO LOCAL A PARTIR DO SERVIDOR
-- ================================================================

local function createLocalPart(serverId, data)
    for part, id in pairs(localParts) do
        if id == serverId then return part end
    end

    local part = deserializePart(data)
    localParts[part] = serverId
    processedParts[part] = true
    return part
end

-- ================================================================
-- 7. LISTENERS DE MOVIMENTO / REDIMENSIONAMENTO
-- ================================================================

local function schedulePartUpdate(part)
    local serverId = localParts[part]
    if not serverId then return end

    if partUpdateCooldowns[part] then
        task.cancel(partUpdateCooldowns[part])
    end

    partUpdateCooldowns[part] = task.delay(UPDATE_DEBOUNCE, function()
        partUpdateCooldowns[part] = nil

        if not part.Parent or not localParts[part] then return end

        local partData = serializePart(part)
        local ok, version = updatePartOnServer(serverId, partData)

        if ok then
            serverParts[serverId] = { data = partData, version = version or 0 }
            print("[F3X Sync] Parte atualizada no servidor: " .. serverId)
        else
            warn("[F3X Sync] Falha ao propagar update: " .. serverId)
        end
    end)
end

local function attachPartListeners(part)
    if connectedParts[part] then return end
    connectedParts[part] = true

    part.Changed:Connect(function(property)
        if property ~= "CFrame" and property ~= "Size" then return end
        if not localParts[part] then return end
        schedulePartUpdate(part)
    end)
end

-- ================================================================
-- 8. MONITORAMENTO DO WORKSPACE
-- ================================================================

local function processNewPart(instance)
    if processedParts[instance] then return end

    if ignoredInstances[instance] then
        processedParts[instance] = true
        return
    end

    if instance:IsA("BasePart") then
        if localParts[instance] then
            processedParts[instance] = true
            attachPartListeners(instance)
            return
        end

        print("[F3X Sync] Nova parte detectada: " .. instance.Name)

        local partData = serializePart(instance)
        local response = sendPartToServer(partData)

        if response and response.success then
            local serverId = response.partId
            local version = (response.part and response.part.version) or 1

            localParts[instance] = serverId
            serverParts[serverId] = { data = partData, version = version }
            attachPartListeners(instance)

            print("[F3X Sync] Parte enviada ao servidor: " .. serverId)
        end

        processedParts[instance] = true

    elseif instance:IsA("Model") then
        if not instance:GetAttribute("F3XSyncGroupId") then
            instance:SetAttribute("F3XSyncGroupId", HttpService:GenerateGUID(false))
        end
        processedParts[instance] = true
    end
end

local function monitorWorkspace()
    for _, inst in ipairs(Workspace:GetDescendants()) do
        ignoredInstances[inst] = true
    end

    Workspace.DescendantAdded:Connect(function(descendant)
        task.wait(0.1)
        processNewPart(descendant)
    end)

    Workspace.DescendantRemoving:Connect(function(descendant)
        if partUpdateCooldowns[descendant] then
            task.cancel(partUpdateCooldowns[descendant])
            partUpdateCooldowns[descendant] = nil
        end

        if localParts[descendant] then
            local serverId = localParts[descendant]
            deletePartOnServer(serverId)
            localParts[descendant] = nil
            serverParts[serverId] = nil
            print("[F3X Sync] Parte removida do servidor: " .. serverId)
        end
    end)
end

-- ================================================================
-- 9. SINCRONIZAÇÃO PERIÓDICA
-- ================================================================

local function syncWithServer()
    local serverPartsList = getPartsFromServer()

    local serverIds = {}
    for _, entry in ipairs(serverPartsList) do
        serverIds[entry.id] = true
    end

    for part, serverId in pairs(localParts) do
        if not serverIds[serverId] then
            if partUpdateCooldowns[part] then
                task.cancel(partUpdateCooldowns[part])
                partUpdateCooldowns[part] = nil
            end
            part:Destroy()
            localParts[part] = nil
            serverParts[serverId] = nil
        end
    end

    for _, entry in ipairs(serverPartsList) do
        local serverId = entry.id
        local cached = serverParts[serverId]

        if cached and cached.version == entry.version then
            -- nada
        else
            local existingPart = nil
            for part, id in pairs(localParts) do
                if id == serverId then
                    existingPart = part
                    break
                end
            end

            if existingPart then
                if not partUpdateCooldowns[existingPart] then
                    if applyServerDataToPart(existingPart, entry.data) then
                        serverParts[serverId] = { data = entry.data, version = entry.version }
                    end
                end
            else
                local part = createLocalPart(serverId, entry.data)
                serverParts[serverId] = { data = entry.data, version = entry.version }
                attachPartListeners(part)
            end
        end
    end
end

-- ================================================================
-- 10. CARREGAMENTO DO F3X MODIFICADO
-- ================================================================

local function loadModifiedF3X()
    local success, err = pcall(function()
        local f3xCode = game:HttpGet("https://raw.githubusercontent.com/infyiff/backup/refs/heads/main/f3x.lua")
        local func = loadstring(f3xCode)
        if func then func() end
    end)

    if not success then
        warn("[F3X Sync] Falha ao carregar F3X: " .. tostring(err))
    else
        print("[F3X Sync] F3X carregado com sucesso!")
    end
end

-- ================================================================
-- 11. LOOP DE SINCRONIZAÇÃO
-- ================================================================

local function startSyncLoop()
    task.spawn(function()
        print("[F3X Sync] Sincronização inicial com o servidor...")
        syncWithServer()
        print("[F3X Sync] Sync inicial concluído! (" .. countTable(localParts) .. " partes carregadas)")
    end)

    task.spawn(function()
        while true do
            task.wait(SYNC_INTERVAL)
            syncWithServer()
        end
    end)
end

-- ================================================================
-- 12. INICIALIZAÇÃO
-- ================================================================

print("[F3X Sync] Iniciando F3X Sync Multiplayer com persistência...")
print("[F3X Sync] Server URL: " .. SERVER_URL)
print("[F3X Sync] Experience ID: " .. EXPERIENCE_ID)

loadModifiedF3X()
task.wait(2)

monitorWorkspace()
startSyncLoop()

print("[F3X Sync] Tudo pronto! Construções salvas no servidor e separadas por jogo.")
