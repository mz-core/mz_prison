RegisterNetEvent('mz_prison:server:activity:start')
AddEventHandler('mz_prison:server:activity:start', function(payload)
  local playerSource = source
  local ok, result = MZPrison.Service.startActivity(playerSource, payload)
  TriggerClientEvent('mz_prison:client:activity:result', playerSource, {
    action = 'start', ok = ok == true,
    result = ok == true and result or nil, code = ok ~= true and result or nil
  })
end)

RegisterNetEvent('mz_prison:server:activity:complete')
AddEventHandler('mz_prison:server:activity:complete', function(payload)
  local playerSource = source
  local ok, result = MZPrison.Service.completeActivity(playerSource, payload)
  TriggerClientEvent('mz_prison:client:activity:result', playerSource, {
    action = 'complete', ok = ok == true,
    result = ok == true and result or nil, code = ok ~= true and result or nil
  })
end)

RegisterNetEvent('mz_prison:server:release:ack')
AddEventHandler('mz_prison:server:release:ack', function(payload)
  MZPrison.Service.acknowledgeRelease(source, payload)
end)

RegisterNetEvent('mz_prison:server:resume')
AddEventHandler('mz_prison:server:resume', function()
  MZPrison.Service.resumeSource(source)
end)
