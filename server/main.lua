local running = false

local function initialize()
  local ready, errorValue = MZPrison.Prepare.run()
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
  if resourceName == GetCurrentResourceName() then initialize() end
end)

AddEventHandler('onResourceStop', function(resourceName)
  if resourceName ~= GetCurrentResourceName() then return end
  running = false
  MZPrison.Service.stop()
end)

MZPrison.Initialize = initialize
