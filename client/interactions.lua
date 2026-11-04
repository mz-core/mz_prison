local requestSequence = 0
local activeActivity
local completionPending = false
local timerGeneration = 0

local messages = {
  prison_unavailable = 'O sistema prisional não está pronto.',
  activities_disabled = 'As atividades prisionais estão desativadas.',
  activity_rate_limit_not_configured = 'O controle das atividades não está configurado.',
  activity_not_configured = 'Esta atividade não possui configuração aprovada.',
  activity_bucket_required = 'A atividade não está disponível nesta área.',
  activity_point_required = 'Retorne ao ponto da atividade para concluir.',
  activity_incomplete = 'A atividade ainda não terminou.',
  activity_already_active = 'Você já possui uma atividade em andamento.',
  activity_limit_reached = 'O limite desta atividade foi atingido.',
  activity_reduction_limit_reached = 'O limite de redução de pena foi atingido.',
  activity_cooldown = 'Aguarde antes de repetir esta atividade.',
  active_sentence_not_found = 'Você não possui uma sentença ativa.',
  sentence_not_active = 'Sua sentença não está ativa.',
  rate_limited = 'Aguarde antes de tentar novamente.'
}

local function notify(message, kind)
  if GetResourceState('mz_menu') == 'started' then
    exports['mz_menu']:Notify(message, kind or 'inform')
  else
    print(('[mz_prison] %s'):format(tostring(message)))
  end
end

local function nextRequestId(prefix)
  requestSequence = requestSequence + 1
  return ('%s_%s_%s'):format(prefix, GetGameTimer(), requestSequence)
end

local function removePoints()
  if GetResourceState('mz_interact') == 'started' then exports['mz_interact']:RemovePointsByOwner() end
end

local function pointCoords(point)
  return type(point) == 'table' and (point.coords or point) or nil
end

local function registerPoints()
  removePoints()
  if GetResourceState('mz_interact') ~= 'started' then return end

  local function addIntakePoint(id, point)
    local coords = pointCoords(point)
    if type(point) ~= 'table' or point.enabled ~= true or type(coords) ~= 'table' then return end
    exports['mz_interact']:AddPoint({
      id = ('mz_prison:intake:%s'):format(tostring(id)),
      coords = coords,
      drawDistance = tonumber(point.drawDistance) or 15.0,
      interactDistance = tonumber(point.radius) or tonumber(MZPrisonConfig.intakeMaximumDistance) or 3.0,
      marker = type(point.marker) == 'table' and point.marker or { enabled = true, type = 1 },
      blip = type(point.blip) == 'table' and point.blip or { enabled = false },
      text = { enabled = true, label = tostring(point.label or '[E] Recebimento prisional') },
      event = { type = 'client', name = 'mz_police:client:prison:intake' }
    })
  end

  if type(MZPrisonConfig.confinement) == 'table' and MZPrisonConfig.confinement.enabled == true then
    for facilityId, facility in pairs(type(MZPrisonConfig.facilities) == 'table' and MZPrisonConfig.facilities or {}) do
      if type(facility) == 'table' and facility.enabled == true then
        for pointId, point in pairs(type(facility.intakePoints) == 'table' and facility.intakePoints or {}) do
          addIntakePoint(('%s:%s'):format(tostring(facilityId), tostring(pointId)), point)
        end
      end
    end
  elseif MZPrisonConfig.intakeEnabled == true then
    for pointId, point in pairs(type(MZPrisonConfig.intakePoints) == 'table' and MZPrisonConfig.intakePoints or {}) do
      addIntakePoint(pointId, point)
    end
  end

  if MZPrisonConfig.jobsEnabled == true then
    for jobCode, job in pairs(type(MZPrisonConfig.jobs) == 'table' and MZPrisonConfig.jobs or {}) do
      if type(job) == 'table' and job.enabled == true then
        for pointId, point in pairs(type(job.points) == 'table' and job.points or {}) do
          local coords = pointCoords(point)
          if type(point) == 'table' and point.enabled == true and type(coords) == 'table' then
            exports['mz_interact']:AddPoint({
              id = ('mz_prison:job:%s:%s'):format(tostring(jobCode), tostring(pointId)),
              coords = coords,
              drawDistance = tonumber(point.drawDistance) or 12.0,
              interactDistance = tonumber(point.radius) or 2.0,
              marker = type(point.marker) == 'table' and point.marker or { enabled = true, type = 1 },
              blip = type(point.blip) == 'table' and point.blip or { enabled = false },
              text = { enabled = true, label = tostring(point.label or job.label or '[E] Atividade prisional') },
              event = {
                type = 'client', name = 'mz_prison:client:activity:interact',
                args = { tostring(jobCode), tostring(pointId) }
              }
            })
          end
        end
      end
    end
  end
end

local function completeActivity()
  if not activeActivity or completionPending then return end
  completionPending = true
  TriggerServerEvent('mz_prison:server:activity:complete', {
    activityId = activeActivity.public_id or activeActivity.publicId,
    requestId = nextRequestId('complete')
  })
end

local function scheduleCompletion(activity)
  timerGeneration = timerGeneration + 1
  local generation = timerGeneration
  local availableAt = tonumber(activity.available_at_epoch or activity.availableAt)
  local duration = math.max(0, math.floor(tonumber(activity.duration_seconds or activity.durationSeconds) or 0))
  local remaining = availableAt and math.max(0, availableAt - os.time()) or duration
  notify(('Atividade iniciada. Aguarde %s segundo(s) e permaneça no local.'):format(remaining), 'success')
  CreateThread(function()
    if remaining > 0 then Wait(remaining * 1000) end
    if generation == timerGeneration and activeActivity then completeActivity() end
  end)
end

RegisterNetEvent('mz_prison:client:activity:interact', function(jobCode, pointId)
  if activeActivity then completeActivity(); return end
  TriggerServerEvent('mz_prison:server:activity:start', {
    jobCode = tostring(jobCode or ''), pointId = tostring(pointId or ''), requestId = nextRequestId('start')
  })
end)

RegisterNetEvent('mz_prison:client:activity:result', function(payload)
  payload = type(payload) == 'table' and payload or {}
  completionPending = false
  if payload.ok ~= true then
    notify(messages[tostring(payload.code or '')] or 'Atividade indisponível no momento.', 'error')
    return
  end
  if payload.action == 'start' or payload.action == 'resume' then
    activeActivity = type(payload.result) == 'table' and payload.result or nil
    if activeActivity then scheduleCompletion(activeActivity) end
    return
  end
  if payload.action == 'complete' then
    activeActivity = nil
    timerGeneration = timerGeneration + 1
    notify('Atividade concluída; a redução configurada foi aplicada pelo servidor.', 'success')
  end
end)

CreateThread(function()
  Wait(1000)
  registerPoints()
end)

AddEventHandler('onClientResourceStart', function(resourceName)
  if resourceName == 'mz_interact' or resourceName == GetCurrentResourceName() then
    Wait(500)
    registerPoints()
  end
end)

AddEventHandler('onClientResourceStop', function(resourceName)
  if resourceName == GetCurrentResourceName() then removePoints() end
end)
