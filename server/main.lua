local running = false

local function initialize()
  local valid, configError = MZPrison.Service.validateConfiguration()
  if not valid then
    print(('[mz_prison] initialization blocked: %s'):format(tostring(configError)))
    return false
  end
  local bootstrap = type(MZPrison.Prepare.bootstrap) == 'function'
    and MZPrison.Prepare.bootstrap
    or MZPrison.Prepare.run
  local ready, errorValue = bootstrap()
  if not ready then
    print(('[mz_prison] initialization blocked: %s'):format(tostring(errorValue)))
    return false
  end
  running = true
  if type(CreateThread) == 'function' and type(Wait) == 'function' then
    CreateThread(function()
      while running do
        Wait(math.max(1, math.floor(tonumber(MZPrisonConfig.tickSeconds) or 30)) * 1000)
        MZPrison.Service.tickOnce()
      end
    end)
  end
  print(('[mz_prison] ready clock=%s intake_enabled=%s rules_enabled=%s'):format(
    tostring(MZPrisonConfig.clockMode), tostring(MZPrisonConfig.intakeEnabled == true),
    tostring(MZPrisonConfig.sentenceRulesEnabled == true)
  ))
  return true
end

AddEventHandler('onResourceStart', function(resourceName)
  if resourceName ~= GetCurrentResourceName() then return end
  if type(CreateThread) == 'function' then
    CreateThread(function() initialize() end)
  else
    initialize()
  end
end)

AddEventHandler('onResourceStop', function(resourceName)
  if resourceName ~= GetCurrentResourceName() then return end
  running = false
  MZPrison.Service.stop()
end)

AddEventHandler('playerDropped', function()
  MZPrison.Service.cleanupSource(source)
end)

AddEventHandler('mz_core:server:playerLoaded', function(playerSource)
  MZPrison.Service.resumeSource(tonumber(playerSource))
end)

MZPrison.Initialize = initialize

RegisterCommand('mz_prison_status', function(source, args)
  if tonumber(source) ~= 0 then return end
  local targetSource = tonumber(type(args) == 'table' and args[1])
  if not targetSource then
    print(('[mz_prison][status] ready=%s prepare=%s error=%s confinement=%s uniform=%s'):format(
      tostring(MZPrison.Prepare.ready == true), tostring(MZPrison.Prepare.state),
      tostring(MZPrison.Prepare.error or ''),
      tostring(type(MZPrisonConfig.confinement) == 'table' and MZPrisonConfig.confinement.enabled == true),
      tostring(type(MZPrisonConfig.uniform) == 'table' and MZPrisonConfig.uniform.enabled == true)))
    return
  end
  local identity = MZPrison.Bridge.resolveIdentity(targetSource)
  local sentence = identity and MZPrison.Repository.getCurrent(identity.citizenid) or nil
  print(('[mz_prison][status] source=%s identity=%s sentence=%s status=%s facility=%s cell=%s bucket=%s property=%s confinement=%s last_error=%s'):format(
    tostring(targetSource), tostring(identity and 'ok' or 'unavailable'),
    tostring(sentence and sentence.public_id or 'none'), tostring(sentence and sentence.status or 'none'),
    tostring(sentence and sentence.facility_id or 'none'), tostring(sentence and sentence.cell_id or 'none'),
    tostring(type(GetPlayerRoutingBucket) == 'function' and GetPlayerRoutingBucket(targetSource) or 'unavailable'),
    tostring(sentence and sentence.property_status or 'none'),
    tostring(sentence and sentence.confinement_status or 'none'), tostring(sentence and sentence.last_error or '')))
end, true)
