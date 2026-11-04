-- HUD de apresentacao da sentenca. O servidor continua sendo o unico owner do
-- tempo, cela e status; este arquivo apenas desenha o snapshot recebido.

local active
local clearAt

local STATUS = {
  intake_pending = 'AGUARDANDO INTAKE',
  active = 'CUMPRINDO PENA',
  release_pending = 'LIBERAÇÃO PENDENTE',
  released = 'LIBERTADO'
}

local function formatTime(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  local remaining = seconds % 60
  if hours > 0 then return ('%02d:%02d:%02d'):format(hours, minutes, remaining) end
  return ('%02d:%02d'):format(minutes, remaining)
end

local function clear()
  active, clearAt = nil, nil
end

RegisterNetEvent('mz_prison:client:sentence', function(payload)
  payload = type(payload) == 'table' and payload or {}
  local sentenceId = tostring(payload.sentenceId or '')
  local status = tostring(payload.status or '')
  if sentenceId == '' or status == '' then return end

  if status == 'released' then
    active = {
      sentenceId = sentenceId,
      status = status,
      remainingSeconds = 0,
      receivedAt = GetGameTimer(),
      facilityId = payload.facilityId and tostring(payload.facilityId) or nil,
      cellId = payload.cellId and tostring(payload.cellId) or nil
    }
    clearAt = GetGameTimer() + 10000
    return
  end

  active = {
    sentenceId = sentenceId,
    status = status,
    remainingSeconds = math.max(0, math.floor(tonumber(payload.remainingSeconds) or 0)),
    receivedAt = GetGameTimer(),
    facilityId = payload.facilityId and tostring(payload.facilityId) or nil,
    cellId = payload.cellId and tostring(payload.cellId) or nil
  }
  clearAt = nil
end)

CreateThread(function()
  while true do
    Wait(0)
    if not active then Wait(500) else
      if clearAt and GetGameTimer() >= clearAt then
        clear()
      else
        local elapsed = math.max(0, math.floor((GetGameTimer() - active.receivedAt) / 1000))
        local remaining = active.status == 'released' and 0 or math.max(0, active.remainingSeconds - elapsed)
        local parts = { 'PRISÃO' }
        if active.facilityId and active.facilityId ~= '' then parts[#parts + 1] = active.facilityId end
        if active.cellId and active.cellId ~= '' then parts[#parts + 1] = 'Cela ' .. active.cellId end
        if active.status == 'released' then
          parts[#parts + 1] = STATUS.released
        else
          parts[#parts + 1] = ('%s • %s'):format(STATUS[active.status] or active.status, formatTime(remaining))
        end
        local text = table.concat(parts, '  •  ')
        DrawRect(0.5, 0.035, 0.42, 0.055, 0, 0, 0, 150)
        SetTextFont(4)
        SetTextScale(0.30, 0.30)
        SetTextColour(235, 241, 248, 235)
        SetTextOutline()
        SetTextCentre(true)
        SetTextEntry('STRING')
        AddTextComponentString(text)
        DrawText(0.5, 0.018)
      end
    end
  end
end)

AddEventHandler('onClientResourceStop', function(resourceName)
  if resourceName == GetCurrentResourceName() then clear() end
end)
