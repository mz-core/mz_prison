RegisterNetEvent('mz_prison:client:release', function(payload)
  payload = type(payload) == 'table' and payload or {}
  local coords = type(payload.coords) == 'table' and payload.coords or nil
  local sentenceId, destinationId = tostring(payload.sentenceId or ''), tostring(payload.destinationId or '')
  local x, y, z = coords and tonumber(coords.x), coords and tonumber(coords.y), coords and tonumber(coords.z)
  if not x or not y or not z or #sentenceId < 8 or #sentenceId > 96
    or not sentenceId:match('^[%w:_-]+$') or #destinationId < 2 or #destinationId > 64
    or not destinationId:match('^[a-z0-9_-]+$') then return end
  local ped = PlayerPedId()
  if not ped or ped <= 0 then return end
  SetEntityCoords(ped, x, y, z, false, false, false, false)
  if tonumber(payload.heading) then SetEntityHeading(ped, tonumber(payload.heading)) end
  TriggerServerEvent('mz_prison:server:release:ack', {
    sentenceId = sentenceId, destinationId = destinationId
  })
end)

RegisterNetEvent('mz_prison:client:confinement', function(payload)
  payload = type(payload) == 'table' and payload or {}
  local coords = type(payload.coords) == 'table' and payload.coords or nil
  local sentenceId = tostring(payload.sentenceId or '')
  local facilityId, cellId = tostring(payload.facilityId or ''), tostring(payload.cellId or '')
  local x, y, z = coords and tonumber(coords.x), coords and tonumber(coords.y), coords and tonumber(coords.z)
  if not x or not y or not z or #sentenceId < 8 or #sentenceId > 96
    or not sentenceId:match('^[%w:_-]+$') or not facilityId:match('^[a-z0-9_-]+$')
    or not cellId:match('^[a-z0-9_-]+$') then return end
  local ped = PlayerPedId()
  if not ped or ped <= 0 then return end
  SetEntityCoords(ped, x, y, z, false, false, false, false)
  if tonumber(payload.heading) then SetEntityHeading(ped, tonumber(payload.heading)) end
  TriggerServerEvent('mz_prison:server:confinement:ack', {
    sentenceId = sentenceId, facilityId = facilityId, cellId = cellId
  })
end)

AddEventHandler('onClientResourceStart', function(resourceName)
  if resourceName == GetCurrentResourceName() then TriggerServerEvent('mz_prison:server:resume') end
end)
