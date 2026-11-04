MZPrison = MZPrison or {}

local Service = {}
local locks, activityRates, confinementCorrections = {}, {}, {}

local function trim(value)
  return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function token(value, minimum, maximum, pattern)
  value = trim(value)
  if #value < minimum or #value > maximum or not value:match(pattern or '^[%w:_-]+$') then return nil end
  return value
end

local function closed(value, allowed)
  if type(value) ~= 'table' then return false end
  for key in pairs(value) do if not allowed[key] then return false end end
  return true
end

local function available()
  return MZPrison.Prepare ~= nil and MZPrison.Prepare.ready == true
end

local function fingerprint(...)
  local hash = 2166136261
  for index = 1, select('#', ...) do
    local value = tostring(select(index, ...) or '')
    for offset = 1, #value do hash = ((hash ~ value:byte(offset)) * 16777619) & 0xffffffff end
    hash = ((hash ~ 31) * 16777619) & 0xffffffff
  end
  return ('%08x'):format(hash)
end

local function withLock(key, callback)
  if locks[key] then return false, 'operation_busy' end
  locks[key] = true
  local result = table.pack(pcall(callback))
  locks[key] = nil
  if result[1] ~= true then return false, 'operation_failed' end
  return table.unpack(result, 2, result.n)
end

local function historyReplay(operationId, requestFingerprint)
  local row = MZPrison.Repository.getHistoryOperation(operationId)
  if not row then return false end
  if tostring(row.request_fingerprint or row.requestFingerprint or '') ~= requestFingerprint then
    return nil, 'operation_id_conflict'
  end
  return true
end

local function rule(section, orgCode, ruleCode)
  local enabledKey = section == 'sentenceRules' and 'sentenceRulesEnabled'
    or section == 'reductionRules' and 'reductionRulesEnabled' or nil
  if not enabledKey or MZPrisonConfig[enabledKey] ~= true then return nil, 'rules_disabled' end
  local jurisdiction = type(MZPrisonConfig.jurisdictions) == 'table' and MZPrisonConfig.jurisdictions[orgCode] or nil
  if type(jurisdiction) ~= 'table' or jurisdiction.enabled ~= true then return nil, 'jurisdiction_disabled' end
  -- Mesmo charset aceito pelo catalogo policial (ruleCode pode ser MAIUSCULO).
  ruleCode = token(ruleCode, 2, 64, '^[%w:_-]+$')
  local value = ruleCode and type(MZPrisonConfig[section]) == 'table' and MZPrisonConfig[section][ruleCode] or nil
  if type(value) ~= 'table' or value.enabled ~= true then return nil, 'rule_not_configured' end
  local name = trim(value.name or value.label)
  local seconds = math.floor(tonumber(value.durationSeconds or value.seconds) or 0)
  if name == '' or #name > 160 or seconds <= 0 then return nil, 'rule_invalid' end
  return { code = ruleCode, name = name, seconds = seconds }
end

local function sentenceResponse(sentence)
  if not sentence then return nil end
  local out = {}
  for key, value in pairs(sentence) do out[key] = value end
  out.property = MZPrison.Repository.listProperty(sentence.public_id or sentence.publicId)
  out.activities = MZPrison.Repository.listActivities and MZPrison.Repository.listActivities(sentence.public_id or sentence.publicId) or {}
  out.charges = MZPrison.Repository.listSentenceCharges
    and MZPrison.Repository.listSentenceCharges(sentence.public_id or sentence.publicId) or {}
  out.releaseDelivery = MZPrison.Repository.getReleaseDelivery
    and MZPrison.Repository.getReleaseDelivery(sentence.public_id or sentence.publicId) or nil
  return out
end

-- Evento de apresentacao para o HUD do preso. Nao concede autoridade e nao
-- substitui GetSentence/RequestSentence; apenas publica o snapshot autorizado.
local function pushSentenceStatus(source, sentence)
  if type(TriggerClientEvent) ~= 'function' or not source or type(sentence) ~= 'table' then return end
  local sentenceId = tostring(sentence.public_id or sentence.publicId or '')
  if sentenceId == '' then return end
  local remaining = tonumber(sentence.remaining_seconds or sentence.remainingSeconds
    or sentence.duration_seconds or sentence.durationSeconds) or 0
  TriggerClientEvent('mz_prison:client:sentence', source, {
    sentenceId = sentenceId,
    status = tostring(sentence.status or ''),
    remainingSeconds = math.max(0, math.floor(remaining)),
    facilityId = sentence.facility_id and tostring(sentence.facility_id) or nil,
    cellId = sentence.cell_id and tostring(sentence.cell_id) or nil,
    clockMode = tostring(sentence.clock_mode or MZPrisonConfig.clockMode or '')
  })
end

local function releasePoint(sentence, destinationId)
  local points = type(MZPrisonConfig.releasePoints) == 'table' and MZPrisonConfig.releasePoints or {}
  local ids = {}
  local selected
  if destinationId then
    ids[1] = destinationId
  else
    for id in pairs(points) do ids[#ids + 1] = tostring(id) end
    table.sort(ids)
  end
  for _, id in ipairs(ids) do
    local point = points[id]
    local coords = type(point) == 'table' and point.coords or nil
    local bucket = type(point) == 'table' and tonumber(point.routingBucket) or nil
    local radius = type(point) == 'table' and tonumber(point.radius) or nil
    local orgCode = type(point) == 'table' and token(point.orgCode, 2, 64, '^[a-z0-9_-]+$') or nil
    if token(id, 2, 64, '^[a-z0-9_-]+$') and type(point) == 'table' and point.enabled == true
      and orgCode == tostring(sentence.org_code or sentence.orgCode or '')
      and type(coords) == 'table' and tonumber(coords.x) and tonumber(coords.y) and tonumber(coords.z)
      and radius and radius > 0 and radius <= 25 and bucket and bucket >= 0 and bucket % 1 == 0 then
      local valid = {
        id = id, coords = { x = tonumber(coords.x), y = tonumber(coords.y), z = tonumber(coords.z) },
        heading = tonumber(point.heading), routingBucket = bucket, radius = radius
      }
      if destinationId then return valid end
      if selected then return nil end
      selected = valid
    end
  end
  return selected
end

local function atReleasePoint(source, destination)
  if type(GetPlayerPed) ~= 'function' or type(GetEntityCoords) ~= 'function'
    or type(GetPlayerRoutingBucket) ~= 'function' then return false end
  local ped = GetPlayerPed(source)
  local coords = ped and ped > 0 and GetEntityCoords(ped) or nil
  local x, y, z = coords and tonumber(coords.x), coords and tonumber(coords.y), coords and tonumber(coords.z)
  if not x or not y or not z or tonumber(GetPlayerRoutingBucket(source)) ~= destination.routingBucket then return false end
  local target = destination.coords
  return ((x - target.x) ^ 2 + (y - target.y) ^ 2 + (z - target.z) ^ 2) <= destination.radius ^ 2
end

local function dispatchRelease(identity, sentence)
  if not MZPrison.Repository.getReleaseDelivery then return true end
  local delivery = MZPrison.Repository.getReleaseDelivery(sentence.public_id)
  if not delivery or tostring(delivery.status) ~= 'pending' then return true end
  local destination = releasePoint(sentence, tostring(delivery.destination_id))
  if not destination then
    MZPrison.Repository.setError(sentence.public_id, 'release_destination_invalid')
    return false, 'release_destination_invalid'
  end
  if type(SetPlayerRoutingBucket) ~= 'function' or type(TriggerClientEvent) ~= 'function' then
    MZPrison.Repository.setError(sentence.public_id, 'release_destination_unavailable')
    return false, 'release_destination_unavailable'
  end
  SetPlayerRoutingBucket(identity.source, destination.routingBucket)
  TriggerClientEvent('mz_prison:client:release', identity.source, {
    sentenceId = sentence.public_id, destinationId = destination.id,
    coords = destination.coords, heading = destination.heading
  })
  return true
end

local function restoreRoutingBucket(identity, sentence)
  local destination = releasePoint(sentence)
  if destination then return dispatchRelease(identity, sentence) end
  local bucket = math.floor(tonumber(sentence.previous_routing_bucket or sentence.previousRoutingBucket) or 0)
  if bucket < 0 or type(SetPlayerRoutingBucket) ~= 'function' then return false, 'release_bucket_unavailable' end
  SetPlayerRoutingBucket(identity.source, bucket)
  return true
end

local function activityRateAllowed(source)
  local config = type(MZPrisonConfig.activityRateLimit) == 'table' and MZPrisonConfig.activityRateLimit or {}
  local duration, maximum = tonumber(config.windowMs), tonumber(config.maximum)
  if not duration or duration <= 0 or not maximum or maximum <= 0 then return false, 'activity_rate_limit_not_configured' end
  local now = type(GetGameTimer) == 'function' and GetGameTimer() or os.time() * 1000
  local window = activityRates[source]
  if not window or now - window.startedAt >= duration then
    activityRates[source] = { startedAt = now, count = 1 }
    return true
  end
  window.count = window.count + 1
  if window.count > maximum then return false, 'rate_limited' end
  return true
end

local function activityConfig(jobCode, pointId)
  if MZPrisonConfig.jobsEnabled ~= true then return nil, nil, 'activities_disabled' end
  jobCode, pointId = token(jobCode, 2, 64, '^[a-z0-9_-]+$'), token(pointId, 2, 64, '^[a-z0-9_-]+$')
  local job = jobCode and type(MZPrisonConfig.jobs) == 'table' and MZPrisonConfig.jobs[jobCode] or nil
  local point = pointId and type(job) == 'table' and type(job.points) == 'table' and job.points[pointId] or nil
  local duration = type(job) == 'table' and math.floor(tonumber(job.durationSeconds) or 0) or 0
  local reduction = type(job) == 'table' and math.floor(tonumber(job.reductionSeconds) or 0) or 0
  local maximum = type(job) == 'table' and math.floor(tonumber(job.maximumCompletionsPerSentence) or 0) or 0
  local maximumReduction = type(job) == 'table' and math.floor(tonumber(job.maximumReductionSecondsPerSentence) or 0) or 0
  local cooldown = type(job) == 'table' and math.floor(tonumber(job.cooldownSeconds) or -1) or -1
  local coords = type(point) == 'table' and point.coords or nil
  local radius = type(point) == 'table' and tonumber(point.radius) or nil
  local bucket = type(point) == 'table' and tonumber(point.routingBucket) or nil
  if type(job) ~= 'table' or job.enabled ~= true or type(point) ~= 'table' or point.enabled ~= true
    or duration <= 0 or reduction <= 0 or maximum <= 0 or maximumReduction <= 0 or cooldown < 0
    or type(coords) ~= 'table' or not tonumber(coords.x) or not tonumber(coords.y) or not tonumber(coords.z)
    or not radius or radius <= 0 or radius > 25 or not bucket or bucket < 0 or bucket % 1 ~= 0 then
    return nil, nil, 'activity_not_configured'
  end
  return {
    code = jobCode, duration = duration, reduction = reduction, maximum = maximum,
    maximumReduction = maximumReduction, cooldown = cooldown
  }, { id = pointId, coords = coords, radius = radius, routingBucket = bucket }
end

local function atActivityPoint(source, point)
  if type(GetPlayerPed) ~= 'function' or type(GetEntityCoords) ~= 'function'
    or type(GetPlayerRoutingBucket) ~= 'function' then return false, 'position_unavailable' end
  local ped = GetPlayerPed(source)
  local coords = ped and ped > 0 and GetEntityCoords(ped) or nil
  local x, y, z = coords and tonumber(coords.x), coords and tonumber(coords.y), coords and tonumber(coords.z)
  if not x or not y or not z then return false, 'position_unavailable' end
  if tonumber(GetPlayerRoutingBucket(source)) ~= point.routingBucket then return false, 'activity_bucket_required' end
  local target = point.coords
  if ((x - tonumber(target.x)) ^ 2 + (y - tonumber(target.y)) ^ 2 + (z - tonumber(target.z)) ^ 2)
    > point.radius ^ 2 then return false, 'activity_point_required' end
  return true
end

local function activityAllowed(sentenceId, job)
  local summary = MZPrison.Repository.getActivitySummary(sentenceId, job.code)
  if math.floor(tonumber(summary.completed_count) or 0) >= job.maximum then return false, 'activity_limit_reached' end
  if math.floor(tonumber(summary.reduction_seconds) or 0) + job.reduction > job.maximumReduction then
    return false, 'activity_reduction_limit_reached'
  end
  local completedAt = math.floor(tonumber(summary.last_completed_at) or 0)
  if completedAt > 0 and os.time() - completedAt < job.cooldown then return false, 'activity_cooldown' end
  return true
end

local function positionFor(source)
  if type(GetPlayerPed) ~= 'function' or type(GetEntityCoords) ~= 'function' then
    return nil, 'position_unavailable'
  end
  local ped = GetPlayerPed(source)
  if not ped or ped <= 0 then return nil, 'position_unavailable' end
  local position = GetEntityCoords(ped)
  local x, y, z = position and tonumber(position.x), position and tonumber(position.y), position and tonumber(position.z)
  if not x or not y or not z then return nil, 'position_unavailable' end
  local bucket = type(GetPlayerRoutingBucket) == 'function' and GetPlayerRoutingBucket(source) or nil
  if bucket == nil then return nil, 'position_unavailable' end
  return { x = x, y = y, z = z, bucket = tonumber(bucket) }
end

local function pointContains(position, point, defaultRadius)
  local coords = type(point) == 'table' and (point.coords or point) or nil
  local px, py, pz = coords and tonumber(coords.x), coords and tonumber(coords.y), coords and tonumber(coords.z)
  local radius = type(point) == 'table' and tonumber(point.radius) or nil
  radius = radius or defaultRadius
  local pointBucket = type(point) == 'table' and tonumber(point.routingBucket) or nil
  return type(point) == 'table' and point.enabled == true and px and py and pz
    and radius and radius > 0 and radius <= 25 and pointBucket and pointBucket >= 0
    and pointBucket % 1 == 0 and position.bucket == pointBucket
    and ((position.x - px) ^ 2 + (position.y - py) ^ 2 + (position.z - pz) ^ 2) <= radius ^ 2
end

local function configuredCell(facility)
  local ids = {}
  for id in pairs(type(facility.cells) == 'table' and facility.cells or {}) do ids[#ids + 1] = tostring(id) end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local cell = facility.cells[id]
    local coords = type(cell) == 'table' and cell.coords or nil
    if token(id, 2, 64, '^[a-z0-9_-]+$') and type(cell) == 'table' and cell.enabled == true
      and type(coords) == 'table' and tonumber(coords.x) and tonumber(coords.y) and tonumber(coords.z) then
      return { id = id, coords = { x = tonumber(coords.x), y = tonumber(coords.y), z = tonumber(coords.z) },
        heading = tonumber(cell.heading) }
    end
  end
end

local function hasAllowedArea(facility)
  for _, area in pairs(type(facility.allowedAreas) == 'table' and facility.allowedAreas or {}) do
    local coords = type(area) == 'table' and (area.coords or area) or nil
    local radius = type(area) == 'table' and tonumber(area.radius) or nil
    if type(area) == 'table' and area.enabled == true and type(coords) == 'table'
      and tonumber(coords.x) and tonumber(coords.y) and tonumber(coords.z)
      and radius and radius > 0 then return true end
  end
  return false
end

local function intakeContext(actorSource, targetSource, orgCode)
  local actor, actorError = positionFor(actorSource)
  if not actor then return nil, actorError end
  local target, targetError = positionFor(targetSource)
  if not target then return nil, targetError end
  if actor.bucket ~= target.bucket then return nil, 'routing_bucket_mismatch' end

  local confinement = type(MZPrisonConfig.confinement) == 'table' and MZPrisonConfig.confinement or {}
  if confinement.enabled == true then
    local facilityIds = {}
    for id in pairs(type(MZPrisonConfig.facilities) == 'table' and MZPrisonConfig.facilities or {}) do
      facilityIds[#facilityIds + 1] = tostring(id)
    end
    table.sort(facilityIds)
    for _, facilityId in ipairs(facilityIds) do
      local facility = MZPrisonConfig.facilities[facilityId]
      local facilityOrg = type(facility) == 'table' and token(facility.orgCode, 2, 64, '^[a-z0-9_-]+$') or nil
      if type(facility) == 'table' and facility.enabled == true
        and (not orgCode or facilityOrg == orgCode) then
        local pointIds = {}
        for pointId in pairs(type(facility.intakePoints) == 'table' and facility.intakePoints or {}) do
          pointIds[#pointIds + 1] = tostring(pointId)
        end
        table.sort(pointIds)
        for _, pointId in ipairs(pointIds) do
          local point = facility.intakePoints[pointId]
          if pointContains(actor, point, tonumber(MZPrisonConfig.intakeMaximumDistance) or 3.0)
            and pointContains(target, point, tonumber(MZPrisonConfig.intakeMaximumDistance) or 3.0) then
            local bucket = tonumber(facility.routingBucket)
            local cell = configuredCell(facility)
            if not bucket or bucket < 0 or bucket % 1 ~= 0 or not cell or not hasAllowedArea(facility) then
              return nil, 'confinement_not_configured'
            end
            return {
              facilityId = facilityId, intakePointId = pointId, cell = cell,
              routingBucket = bucket, previousRoutingBucket = target.bucket
            }
          end
        end
      end
    end
    return nil, 'intake_point_required'
  end

  local pointIds = {}
  for id in pairs(type(MZPrisonConfig.intakePoints) == 'table' and MZPrisonConfig.intakePoints or {}) do
    pointIds[#pointIds + 1] = tostring(id)
  end
  table.sort(pointIds)
  for _, pointId in ipairs(pointIds) do
    local point = MZPrisonConfig.intakePoints[pointId]
    local maximum = tonumber(MZPrisonConfig.intakeMaximumDistance) or 3.0
    if pointContains(actor, point, maximum) and pointContains(target, point, maximum) then
      return { intakePointId = pointId, previousRoutingBucket = target.bucket }
    end
  end
  return nil, 'intake_point_required'
end

local function intakeConfigured()
  local confinement = type(MZPrisonConfig.confinement) == 'table' and MZPrisonConfig.confinement or {}
  if confinement.enabled == true then
    return type(MZPrisonConfig.facilities) == 'table' and next(MZPrisonConfig.facilities) ~= nil
  end
  return MZPrisonConfig.intakeEnabled == true and type(MZPrisonConfig.intakePoints) == 'table'
    and next(MZPrisonConfig.intakePoints) ~= nil
end

local function confinementFor(sentence)
  local confinement = type(MZPrisonConfig.confinement) == 'table' and MZPrisonConfig.confinement or {}
  if confinement.enabled ~= true then return nil end
  local facilityId = tostring(sentence.facility_id or sentence.facilityId or '')
  local cellId = tostring(sentence.cell_id or sentence.cellId or '')
  local facility = type(MZPrisonConfig.facilities) == 'table' and MZPrisonConfig.facilities[facilityId] or nil
  local cell = type(facility) == 'table' and type(facility.cells) == 'table' and facility.cells[cellId] or nil
  local coords = type(cell) == 'table' and cell.coords or nil
  local bucket = type(facility) == 'table' and tonumber(facility.routingBucket) or nil
  if type(facility) ~= 'table' or facility.enabled ~= true or type(cell) ~= 'table' or cell.enabled ~= true
    or not bucket or bucket < 0 or bucket % 1 ~= 0 or type(coords) ~= 'table'
    or not tonumber(coords.x) or not tonumber(coords.y) or not tonumber(coords.z) then return nil end
  return {
    facilityId = facilityId, cellId = cellId, routingBucket = bucket,
    coords = { x = tonumber(coords.x), y = tonumber(coords.y), z = tonumber(coords.z) },
    heading = tonumber(cell.heading), allowedAreas = facility.allowedAreas
  }
end

local function dispatchConfinement(identity, sentence)
  local context = confinementFor(sentence)
  if not context then return true end
  if type(SetPlayerRoutingBucket) ~= 'function' or type(TriggerClientEvent) ~= 'function' then
    return false, 'confinement_runtime_unavailable'
  end
  SetPlayerRoutingBucket(identity.source, context.routingBucket)
  TriggerClientEvent('mz_prison:client:confinement', identity.source, {
    sentenceId = sentence.public_id, facilityId = context.facilityId, cellId = context.cellId,
    coords = context.coords, heading = context.heading
  })
  confinementCorrections[identity.source] = os.time()
  return true
end

local function withinAllowedArea(source, context)
  local position = positionFor(source)
  if not position then return false, 'position_unavailable' end
  if position.bucket ~= context.routingBucket then return false, 'routing_bucket_mismatch' end
  for _, area in pairs(type(context.allowedAreas) == 'table' and context.allowedAreas or {}) do
    local coords = type(area) == 'table' and (area.coords or area) or nil
    local radius = type(area) == 'table' and tonumber(area.radius) or nil
    if type(area) == 'table' and area.enabled == true and type(coords) == 'table' and radius and radius > 0
      and tonumber(coords.x) and tonumber(coords.y) and tonumber(coords.z)
      and ((position.x - tonumber(coords.x)) ^ 2 + (position.y - tonumber(coords.y)) ^ 2
        + (position.z - tonumber(coords.z)) ^ 2) <= radius ^ 2 then return true end
  end
  return false, 'allowed_area_left'
end

local function releaseSentence(sentence, actor, operationId, requestFingerprint, action)
  local replayed, replayError = historyReplay(operationId, requestFingerprint)
  if replayed == nil then return false, replayError end
  if tostring(sentence.status) == 'release_pending' and not replayed
    and MZPrison.Repository.getPendingReleaseHistory then
    local pending = MZPrison.Repository.getPendingReleaseHistory(sentence.public_id)
    if pending then return false, 'release_operation_pending' end
  end
  if not replayed then
    local begun = MZPrison.Repository.beginRelease(sentence, {
      operationId = operationId, requestFingerprint = requestFingerprint,
      sentenceId = sentence.public_id, action = action,
      actorCitizenid = actor and actor.citizenid or nil
    })
    if not begun then return false, 'persistence_failed' end
  end
  sentence = MZPrison.Repository.getById(sentence.public_id)
  if not sentence then return false, 'sentence_not_found' end
  if tostring(sentence.status) == 'released' then
    local targetSource = MZPrison.Bridge.getSource(sentence.target_citizenid)
    if targetSource then
      local identity = MZPrison.Bridge.resolveIdentity(targetSource)
      if identity and identity.citizenid == tostring(sentence.target_citizenid) then
        restoreRoutingBucket(identity, sentence)
        pushSentenceStatus(targetSource, sentence)
      end
    end
    return true, sentenceResponse(sentence)
  end
  local targetSource, sourceError = MZPrison.Bridge.getSource(sentence.target_citizenid)
  if not targetSource then MZPrison.Repository.setError(sentence.public_id, sourceError); return false, sourceError end
  local targetIdentity, identityError = MZPrison.Bridge.resolveIdentity(targetSource)
  if not targetIdentity or targetIdentity.citizenid ~= tostring(sentence.target_citizenid) then
    local errorCode = identityError or 'target_identity_mismatch'
    MZPrison.Repository.setError(sentence.public_id, errorCode)
    return false, errorCode
  end
  local expectedProperty = MZPrison.Repository.listProperty(sentence.public_id)
  local removed, uniformError = MZPrison.Bridge.removeUniform(targetSource, sentence.public_id)
  if not removed then MZPrison.Repository.setError(sentence.public_id, uniformError); return false, uniformError end
  local restored, restoreError = MZPrison.Bridge.restoreProperty(targetSource, sentence.public_id, #expectedProperty)
  if not restored then MZPrison.Repository.setError(sentence.public_id, restoreError); return false, restoreError end
  local finishOperation = operationId .. ':property'
  local finishFingerprint = fingerprint(sentence.public_id, 'property_restored')
  local finishReplay, finishError = historyReplay(finishOperation, finishFingerprint)
  if finishReplay == nil then return false, finishError end
  local destination = releasePoint(sentence)
  if not finishReplay and not MZPrison.Repository.finishRelease(sentence.public_id, {
    operationId = finishOperation, requestFingerprint = finishFingerprint,
    sentenceId = sentence.public_id, action = 'property_restored',
    actorCitizenid = actor and actor.citizenid or nil,
    details = { itemCount = #(restored.items or {}), destinationId = destination and destination.id or nil }
  }, destination and { destinationId = destination.id, targetCitizenid = sentence.target_citizenid } or nil) then
    return false, 'persistence_failed'
  end
  sentence = MZPrison.Repository.getById(sentence.public_id)
  MZPrison.Bridge.audit('released', actor, sentence, {
    operationId = operationId, result = 'released', status = sentence.status,
    destinationId = destination and destination.id or nil
  })
  pushSentenceStatus(targetSource, sentence)
  local delivered, deliveryError = restoreRoutingBucket(targetIdentity, sentence)
  if not delivered then MZPrison.Repository.setError(sentence.public_id, deliveryError) end
  return true, sentenceResponse(sentence)
end

local function activateSentence(sentence, actor, target, operationId)
  if tostring(sentence.status) ~= 'intake_pending' then return sentence end
  local retained, retainError = MZPrison.Bridge.retainProperty(target.source, sentence.public_id)
  if not retained then
    MZPrison.Repository.setError(sentence.public_id, retainError)
    MZPrison.Bridge.audit('intake_failed', actor, sentence, {
      operationId = operationId, result = 'pending', reason = retainError
    })
    return false, retainError
  end
  local uniform = type(MZPrisonConfig.uniform) == 'table' and MZPrisonConfig.uniform or {}
  if uniform.enabled == true then
    local dressed, uniformError = MZPrison.Bridge.applyUniform(
      target.source, sentence.public_id, uniform.garments)
    if not dressed then
      MZPrison.Repository.setError(sentence.public_id, uniformError)
      return false, uniformError
    end
  end
  local propertyOperation = operationId .. ':property'
  local propertyFingerprint = fingerprint(sentence.public_id, 'property_retained')
  if not MZPrison.Repository.activateWithProperty(sentence.public_id, retained.items or {}, {
    operationId = propertyOperation, requestFingerprint = propertyFingerprint,
    sentenceId = sentence.public_id, action = 'property_retained', actorCitizenid = actor.citizenid,
    details = { itemCount = #(retained.items or {}) }
  }) then return false, 'persistence_failed' end
  local updated = MZPrison.Repository.getById(sentence.public_id)
  if not updated then return nil, 'persistence_failed' end
  local confined, confinementError = dispatchConfinement(target, updated)
  if not confined then
    MZPrison.Repository.setError(sentence.public_id, confinementError)
    return false, confinementError
  end
  pushSentenceStatus(target.source, updated)
  return updated
end

function Service.requestSentence(actorSource, targetSource, request)
  if not available() then return false, 'prison_unavailable' end
  if not closed(request, {
    chargeId = true, ruleCode = true, ruleName = true, sentenceSeconds = true,
    legalVersion = true, caseId = true, operationId = true, orgCode = true
  }) then
    return false, 'invalid_request'
  end
  if not intakeConfigured() then return false, 'intake_not_configured' end
  local actor, actorError = MZPrison.Bridge.resolveIdentity(actorSource)
  if not actor then return false, actorError end
  local target, targetError = MZPrison.Bridge.resolveIdentity(targetSource)
  if not target then return false, targetError end
  if actor.citizenid == target.citizenid then return false, 'self_sentence_forbidden' end
  local orgCode = token(request.orgCode, 2, 64, '^[a-z0-9_-]+$')
  local caseId = token(request.caseId, 8, 160)
  local chargeId = token(request.chargeId, 8, 160)
  local operationId = token(request.operationId, 16, 64, '^[%w:_-]+$')
  local ruleName = trim(request.ruleName)
  local legalVersion = trim(request.legalVersion)
  local sentenceSeconds = tonumber(request.sentenceSeconds)
  sentenceSeconds = sentenceSeconds and math.floor(sentenceSeconds) or nil
  if not orgCode or not caseId or not chargeId or not operationId or ruleName == ''
    or #ruleName > 160 or legalVersion == '' or #legalVersion > 64
    or not sentenceSeconds or sentenceSeconds <= 0 then
    return false, 'invalid_request'
  end
  local intake, pointError = intakeContext(actor.source, target.source, orgCode)
  if not intake then return false, pointError end
  local sentenceRule, ruleError = rule('sentenceRules', orgCode, request.ruleCode)
  if not sentenceRule then return false, ruleError end
  if sentenceRule.name ~= ruleName or sentenceRule.seconds ~= sentenceSeconds
    or tostring(MZPrisonConfig.legalVersion or '') ~= legalVersion then
    return false, 'sentence_rule_mismatch'
  end
  if MZPrisonConfig.clockMode ~= 'online' then return false, 'clock_mode_not_supported' end
  local requestFingerprint = fingerprint(
    actor.citizenid, target.citizenid, orgCode, caseId,
    chargeId, sentenceRule.code, sentenceSeconds, legalVersion
  )
  local publicId = 'sentence:' .. operationId

  return withLock('citizen:' .. target.citizenid, function()
    local sentence = MZPrison.Repository.getByOperation(operationId)
    if sentence then
      local replayed, replayError = historyReplay(operationId, requestFingerprint)
      if replayed == nil then return false, replayError end
      if tostring(sentence.target_citizenid) ~= target.citizenid then return false, 'operation_id_conflict' end
    else
      if MZPrison.Repository.getCurrent(target.citizenid) then return false, 'active_sentence_exists' end
      if MZPrison.Repository.getChargeSentence
        and MZPrison.Repository.getChargeSentence(chargeId) then
        return false, 'charge_already_sentenced'
      end
      local created = MZPrison.Repository.createSentence({
        publicId = publicId, operationId = operationId, targetCitizenid = target.citizenid,
        caseId = caseId, chargeId = chargeId, orgCode = orgCode,
        ruleCode = sentenceRule.code, ruleName = ruleName,
        legalVersion = legalVersion, durationSeconds = sentenceSeconds,
        clockMode = MZPrisonConfig.clockMode, actorCitizenid = actor.citizenid,
        facilityId = intake.facilityId, intakePointId = intake.intakePointId,
        cellId = intake.cell and intake.cell.id or nil,
        previousRoutingBucket = intake.previousRoutingBucket,
        history = {
          operationId = operationId, requestFingerprint = requestFingerprint,
          sentenceId = publicId, action = 'sentence_created', actorCitizenid = actor.citizenid,
          details = { chargeId = chargeId, ruleCode = sentenceRule.code, durationSeconds = sentenceSeconds }
        }
      })
      if not created then return false, 'persistence_failed' end
      sentence = MZPrison.Repository.getById(publicId)
    end
    local activated, activationError = activateSentence(sentence, actor, target, operationId)
    if not activated then return false, activationError end
    sentence = activated
    MZPrison.Bridge.audit('sentence_started', actor, sentence, { operationId = operationId, result = 'active', status = sentence.status })
    return true, sentenceResponse(sentence)
  end)
end

function Service.requestSentenceFromCharges(actorSource, targetSource, request)
  if not available() then return false, 'prison_unavailable' end
  if not closed(request, {
    caseId = true, primaryChargeId = true, charges = true, operationId = true, orgCode = true
  }) then return false, 'invalid_request' end

  local multi = type(MZPrisonConfig.multiCharge) == 'table' and MZPrisonConfig.multiCharge or {}
  if multi.enabled ~= true then return false, 'multi_charge_disabled' end
  if tostring(multi.aggregation or '') ~= 'sum' then return false, 'aggregation_policy_not_supported' end
  if not intakeConfigured() then return false, 'intake_not_configured' end

  local actor, actorError = MZPrison.Bridge.resolveIdentity(actorSource)
  if not actor then return false, actorError end
  local target, targetError = MZPrison.Bridge.resolveIdentity(targetSource)
  if not target then return false, targetError end
  if actor.citizenid == target.citizenid then return false, 'self_sentence_forbidden' end
  local orgCode = token(request.orgCode, 2, 64, '^[a-z0-9_-]+$')
  local caseId = token(request.caseId, 8, 160)
  local primaryChargeId = token(request.primaryChargeId, 8, 160)
  local operationId = token(request.operationId, 16, 64, '^[%w:_-]+$')
  local maximum = math.max(1, math.floor(tonumber(multi.maximumCharges) or 1))
  if not orgCode or not caseId or not primaryChargeId or not operationId
    or type(request.charges) ~= 'table' or #request.charges < 1 or #request.charges > maximum then
    return false, 'invalid_charge_count'
  end
  local intake, pointError = intakeContext(actor.source, target.source, orgCode)
  if not intake then return false, pointError end

  local legalVersion = trim(MZPrisonConfig.legalVersion)
  if legalVersion == '' then return false, 'invalid_legal_version' end
  local charges, seen, sortedIds = {}, {}, {}
  local total = 0
  for _, raw in ipairs(request.charges) do
    if not closed(raw, {
      chargeId = true, ruleCode = true, ruleName = true, sentenceSeconds = true, legalVersion = true
    }) then return false, 'invalid_request' end
    local chargeId = token(raw.chargeId, 8, 160)
    local ruleCode = token(raw.ruleCode, 2, 64, '^[%w:_-]+$')
    local ruleName = trim(raw.ruleName)
    local seconds = tonumber(raw.sentenceSeconds)
    local version = trim(raw.legalVersion)
    if not chargeId or seen[chargeId] or not ruleCode or ruleName == '' or #ruleName > 160
      or not seconds or seconds <= 0 or seconds % 1 ~= 0 or version == '' or version ~= legalVersion then
      return false, 'invalid_request'
    end
    local sentenceRule, ruleError = rule('sentenceRules', orgCode, ruleCode)
    if not sentenceRule then return false, ruleError end
    if sentenceRule.name ~= ruleName or sentenceRule.seconds ~= seconds
      or tostring(MZPrisonConfig.legalVersion or '') ~= version then
      return false, 'sentence_rule_mismatch'
    end
    seen[chargeId] = true
    total = total + seconds
    sortedIds[#sortedIds + 1] = chargeId
    charges[#charges + 1] = {
      chargeId = chargeId, ruleCode = sentenceRule.code, ruleName = ruleName,
      sentenceSeconds = seconds, legalVersion = version
    }
  end
  if not seen[primaryChargeId] then return false, 'invalid_primary_charge' end
  local maximumSentence = math.floor(tonumber(multi.maximumSentenceSeconds) or 0)
  if #charges > 1 and maximumSentence <= 0 then return false, 'sentence_cap_not_configured' end
  if maximumSentence > 0 and total > maximumSentence then return false, 'sentence_limit_exceeded' end
  if MZPrisonConfig.clockMode ~= 'online' then return false, 'clock_mode_not_supported' end

  table.sort(sortedIds)
  local primary
  for _, charge in ipairs(charges) do
    if charge.chargeId == primaryChargeId then primary = charge; break end
  end
  if not primary then return false, 'invalid_primary_charge' end

  local requestFingerprint = fingerprint(
    actor.citizenid, target.citizenid, orgCode, caseId, primaryChargeId,
    table.concat(sortedIds, ','), total, legalVersion
  )
  local publicId = 'sentence:' .. operationId

  return withLock('citizen:' .. target.citizenid, function()
    local sentence = MZPrison.Repository.getByOperation(operationId)
    if sentence then
      local replayed, replayError = historyReplay(operationId, requestFingerprint)
      if replayed == nil then return false, replayError end
      if tostring(sentence.target_citizenid) ~= target.citizenid then return false, 'operation_id_conflict' end
    else
      if MZPrison.Repository.getCurrent(target.citizenid) then return false, 'active_sentence_exists' end
      if MZPrison.Repository.getChargeSentence then
        for _, charge in ipairs(charges) do
          if MZPrison.Repository.getChargeSentence(charge.chargeId) then
            return false, 'charge_already_sentenced'
          end
        end
      end

      local created = MZPrison.Repository.createSentenceWithCharges({
        publicId = publicId, operationId = operationId, targetCitizenid = target.citizenid,
        caseId = caseId, primaryChargeId = primaryChargeId, orgCode = orgCode,
        ruleCode = primary.ruleCode, ruleName = primary.ruleName, legalVersion = legalVersion,
        durationSeconds = total, clockMode = MZPrisonConfig.clockMode, actorCitizenid = actor.citizenid,
        facilityId = intake.facilityId, intakePointId = intake.intakePointId,
        cellId = intake.cell and intake.cell.id or nil,
        previousRoutingBucket = intake.previousRoutingBucket,
        charges = charges,
        history = {
          operationId = operationId, requestFingerprint = requestFingerprint,
          sentenceId = publicId, action = 'sentence_created', actorCitizenid = actor.citizenid,
          details = {
            chargeIds = sortedIds, chargeCount = #charges,
            durationSeconds = total, aggregation = 'sum'
          }
        }
      })
      if not created then return false, 'persistence_failed' end
      sentence = MZPrison.Repository.getById(publicId)
      if not sentence then return false, 'persistence_failed' end
    end

    local activated, activationError = activateSentence(sentence, actor, target, operationId)
    if not activated then return false, activationError end
    sentence = activated
    MZPrison.Bridge.audit('sentence_started', actor, sentence, {
      operationId = operationId, result = 'active', status = sentence.status, chargeCount = #charges
    })
    return true, sentenceResponse(sentence)
  end)
end

function Service.getSentence(citizenid)
  if not available() then return false, 'prison_unavailable' end
  citizenid = token(citizenid, 2, 64)
  if not citizenid then return false, 'invalid_citizenid' end
  local character, characterError = MZPrison.Bridge.getCharacter(citizenid)
  if not character then return false, characterError end
  local sentence = MZPrison.Repository.getCurrent(citizenid)
  return true, sentence and sentenceResponse(sentence) or { active = false, citizenid = citizenid }
end

function Service.reduceSentence(actorSource, citizenid, request)
  if not available() then return false, 'prison_unavailable' end
  if not closed(request, { ruleCode = true, operationId = true, orgCode = true }) then return false, 'invalid_request' end
  local actor, actorError = MZPrison.Bridge.resolveIdentity(actorSource)
  if not actor then return false, actorError end
  citizenid = token(citizenid, 2, 64)
  local orgCode = token(request.orgCode, 2, 64, '^[a-z0-9_-]+$')
  local operationId = token(request.operationId, 16, 64, '^[%w:_-]+$')
  if not citizenid or not orgCode or not operationId then return false, 'invalid_request' end
  local reduction, ruleError = rule('reductionRules', orgCode, request.ruleCode)
  if not reduction then return false, ruleError end
  local requestFingerprint = fingerprint(citizenid, orgCode, reduction.code, reduction.seconds)
  return withLock('citizen:' .. citizenid, function()
    local replayed, replayError = historyReplay(operationId, requestFingerprint)
    if replayed == nil then return false, replayError end
    if replayed then
      local historyRow = MZPrison.Repository.getHistoryOperation(operationId)
      local previous = historyRow and MZPrison.Repository.getById(
        historyRow.sentence_public_id or historyRow.sentenceId
      ) or nil
      if not previous or tostring(previous.target_citizenid) ~= citizenid
        or tostring(previous.org_code) ~= orgCode then return false, 'operation_id_conflict' end
      return true, sentenceResponse(previous)
    end
    local sentence = MZPrison.Repository.getCurrent(citizenid)
    if not sentence then return false, 'active_sentence_not_found' end
    if tostring(sentence.org_code) ~= orgCode then return false, 'organization_mismatch' end
    if tostring(sentence.status) ~= 'active' then return false, 'sentence_not_active' end
    local reduced, remaining = MZPrison.Repository.reduce(sentence, reduction.seconds, {
      operationId = operationId, requestFingerprint = requestFingerprint,
      sentenceId = sentence.public_id, action = 'sentence_reduced', actorCitizenid = actor.citizenid,
      details = { ruleCode = reduction.code, seconds = reduction.seconds }
    })
    if not reduced then return false, 'persistence_failed' end
    sentence = MZPrison.Repository.getById(sentence.public_id)
    MZPrison.Bridge.audit('sentence_reduced', actor, sentence, { operationId = operationId, result = 'reduced', status = sentence.status })
    if remaining == 0 then
      return releaseSentence(sentence, actor, operationId .. ':release', fingerprint(sentence.public_id, 'reduction_release'), 'reduction_release')
    end
    return true, sentenceResponse(sentence)
  end)
end

function Service.releasePrisoner(actorSource, citizenid, request)
  if not available() then return false, 'prison_unavailable' end
  if not closed(request, { reasonCode = true, operationId = true, orgCode = true }) then return false, 'invalid_request' end
  if MZPrisonConfig.manualReleaseEnabled ~= true then return false, 'manual_release_disabled' end
  local actor, actorError = MZPrison.Bridge.resolveIdentity(actorSource)
  if not actor then return false, actorError end
  citizenid = token(citizenid, 2, 64)
  local orgCode = token(request.orgCode, 2, 64, '^[a-z0-9_-]+$')
  local operationId = token(request.operationId, 16, 64, '^[%w:_-]+$')
  local reasonCode = token(request.reasonCode, 2, 64, '^[a-z0-9_-]+$')
  local reason = reasonCode and type(MZPrisonConfig.manualReleaseReasons) == 'table'
    and MZPrisonConfig.manualReleaseReasons[reasonCode] or nil
  if not citizenid or not orgCode or not operationId or type(reason) ~= 'table' or reason.enabled ~= true then
    return false, 'release_reason_not_configured'
  end
  local requestFingerprint = fingerprint(citizenid, orgCode, reasonCode)
  return withLock('citizen:' .. citizenid, function()
    local replayed, replayError = historyReplay(operationId, requestFingerprint)
    if replayed == nil then return false, replayError end
    if replayed then
      local historyRow = MZPrison.Repository.getHistoryOperation(operationId)
      local previous = historyRow and MZPrison.Repository.getById(
        historyRow.sentence_public_id or historyRow.sentenceId
      ) or nil
      if not previous or tostring(previous.target_citizenid) ~= citizenid
        or tostring(previous.org_code) ~= orgCode then return false, 'operation_id_conflict' end
      return releaseSentence(previous, actor, operationId, requestFingerprint, 'manual_release')
    end
    local sentence = MZPrison.Repository.getCurrent(citizenid)
    if not sentence then return false, 'active_sentence_not_found' end
    if tostring(sentence.org_code) ~= orgCode then return false, 'organization_mismatch' end
    return releaseSentence(sentence, actor, operationId, requestFingerprint, 'manual_release')
  end)
end

function Service.startActivity(source, request)
  if not available() then return false, 'prison_unavailable' end
  if not closed(request, { jobCode = true, pointId = true, requestId = true }) then return false, 'invalid_request' end
  if MZPrisonConfig.jobsEnabled ~= true then return false, 'activities_disabled' end
  local rateOk, rateError = activityRateAllowed(source)
  if not rateOk then return false, rateError end
  local identity, identityError = MZPrison.Bridge.resolveIdentity(source)
  if not identity then return false, identityError end
  local job, point, configError = activityConfig(request.jobCode, request.pointId)
  if not job then return false, configError end
  local requestId = token(request.requestId, 8, 40, '^[%w_-]+$')
  if not requestId then return false, 'invalid_request_id' end
  local operationId = ('activity_start:%s:%s'):format(identity.sessionId, requestId)
  local requestFingerprint = fingerprint(identity.citizenid, job.code, point.id)
  local publicId = ('activity:%s:%s'):format(identity.sessionId, requestId)

  return withLock('citizen:' .. identity.citizenid, function()
    local replayed, replayError = historyReplay(operationId, requestFingerprint)
    if replayed == nil then return false, replayError end
    if replayed then
      local activity = MZPrison.Repository.getActivityByOperation(operationId)
      return activity and true, activity or 'activity_not_found'
    end
    local sentence = MZPrison.Repository.getCurrent(identity.citizenid)
    if not sentence then return false, 'active_sentence_not_found' end
    if tostring(sentence.status) ~= 'active' then return false, 'sentence_not_active' end
    if MZPrison.Repository.getActiveActivity(sentence.public_id) then return false, 'activity_already_active' end
    local allowed, allowedError = activityAllowed(sentence.public_id, job)
    if not allowed then return false, allowedError end
    local atPoint, pointError = atActivityPoint(source, point)
    if not atPoint then return false, pointError end
    local availableAt = os.time() + job.duration
    local saved = MZPrison.Repository.createActivity({
      publicId = publicId, operationId = operationId, sentenceId = sentence.public_id,
      targetCitizenid = identity.citizenid, jobCode = job.code, pointId = point.id,
      durationSeconds = job.duration, reductionSeconds = job.reduction,
      sessionId = identity.sessionId, availableAt = availableAt,
      history = {
        operationId = operationId, requestFingerprint = requestFingerprint,
        sentenceId = sentence.public_id, action = 'activity_started', actorCitizenid = identity.citizenid,
        details = { activityId = publicId, jobCode = job.code, pointId = point.id, durationSeconds = job.duration }
      }
    })
    if not saved then return false, 'persistence_failed' end
    local activity = MZPrison.Repository.getActivity(publicId)
    MZPrison.Bridge.audit('activity_started', identity, sentence, {
      operationId = operationId, result = 'started', status = sentence.status,
      activityId = publicId, jobCode = job.code
    })
    return true, activity
  end)
end

function Service.completeActivity(source, request)
  if not available() then return false, 'prison_unavailable' end
  if not closed(request, { activityId = true, requestId = true }) then return false, 'invalid_request' end
  if MZPrisonConfig.jobsEnabled ~= true then return false, 'activities_disabled' end
  local rateOk, rateError = activityRateAllowed(source)
  if not rateOk then return false, rateError end
  local identity, identityError = MZPrison.Bridge.resolveIdentity(source)
  if not identity then return false, identityError end
  local activityId = token(request.activityId, 8, 96)
  local requestId = token(request.requestId, 8, 40, '^[%w_-]+$')
  if not activityId or not requestId then return false, 'invalid_request' end
  local operationId = ('activity_complete:%s:%s'):format(identity.sessionId, requestId)

  return withLock('citizen:' .. identity.citizenid, function()
    local activity = MZPrison.Repository.getActivity(activityId)
    if not activity or tostring(activity.target_citizenid) ~= identity.citizenid then
      return false, 'activity_not_found'
    end
    if tostring(activity.status) == 'completed' then return true, activity end
    if tostring(activity.status) ~= 'in_progress' then return false, 'activity_not_active' end
    local job, point, configError = activityConfig(activity.job_code, activity.point_id)
    if not job then return false, configError end
    if math.floor(tonumber(activity.duration_seconds) or 0) ~= job.duration
      or math.floor(tonumber(activity.reduction_seconds) or 0) ~= job.reduction then
      return false, 'activity_configuration_changed'
    end
    local requestFingerprint = fingerprint(identity.citizenid, activityId, job.code, point.id)
    local replayed, replayError = historyReplay(operationId, requestFingerprint)
    if replayed == nil then return false, replayError end
    if replayed then return true, MZPrison.Repository.getActivity(activityId) end
    local sentence = MZPrison.Repository.getById(activity.sentence_public_id)
    if not sentence or tostring(sentence.target_citizenid) ~= identity.citizenid then
      return false, 'active_sentence_not_found'
    end
    if tostring(sentence.status) ~= 'active' then return false, 'sentence_not_active' end
    if os.time() < math.floor(tonumber(activity.available_at_epoch) or 0) then return false, 'activity_incomplete' end
    local atPoint, pointError = atActivityPoint(source, point)
    if not atPoint then return false, pointError end
    local allowed, allowedError = activityAllowed(sentence.public_id, job)
    if not allowed then return false, allowedError end
    local remaining = math.max(0, math.floor(tonumber(sentence.remaining_seconds) or 0) - job.reduction)
    local saved = MZPrison.Repository.completeActivity(sentence, activity, remaining, {
      operationId = operationId, requestFingerprint = requestFingerprint,
      sentenceId = sentence.public_id, action = 'activity_completed', actorCitizenid = identity.citizenid,
      details = { activityId = activityId, jobCode = job.code, reductionSeconds = job.reduction }
    })
    if not saved then return false, 'persistence_failed' end
    sentence = MZPrison.Repository.getById(sentence.public_id)
    MZPrison.Bridge.audit('activity_completed', identity, sentence, {
      operationId = operationId, result = 'completed', status = sentence.status,
      activityId = activityId, jobCode = job.code
    })
    if remaining == 0 then
      local releaseOperation = 'activity_release:' .. activityId
      return releaseSentence(sentence, identity, releaseOperation,
        fingerprint(sentence.public_id, activityId, 'activity_release'), 'activity_release')
    end
    return true, sentenceResponse(sentence)
  end)
end

function Service.acknowledgeRelease(source, request)
  if not available() then return false, 'prison_unavailable' end
  if not closed(request, { sentenceId = true, destinationId = true }) then return false, 'invalid_request' end
  local identity, identityError = MZPrison.Bridge.resolveIdentity(source)
  if not identity then return false, identityError end
  local sentenceId = token(request.sentenceId, 8, 96)
  local destinationId = token(request.destinationId, 2, 64, '^[a-z0-9_-]+$')
  if not sentenceId or not destinationId or not MZPrison.Repository.getReleaseDelivery then
    return false, 'invalid_request'
  end
  return withLock('citizen:' .. identity.citizenid, function()
    local sentence = MZPrison.Repository.getById(sentenceId)
    local delivery = MZPrison.Repository.getReleaseDelivery(sentenceId)
    if not sentence or tostring(sentence.status) ~= 'released'
      or tostring(sentence.target_citizenid) ~= identity.citizenid
      or not delivery or tostring(delivery.destination_id) ~= destinationId then
      return false, 'release_delivery_not_found'
    end
    if tostring(delivery.status) == 'delivered' then return true, delivery end
    local destination = releasePoint(sentence, destinationId)
    if tostring(delivery.status) ~= 'pending' or not destination then
      return false, 'release_destination_invalid'
    end
    if not atReleasePoint(source, destination) then return false, 'release_destination_not_reached' end
    local operationId = ('release_destination:%s:%s'):format(sentenceId, identity.sessionId)
    local requestFingerprint = fingerprint(sentenceId, destinationId, identity.citizenid)
    local replayed, replayError = historyReplay(operationId, requestFingerprint)
    if replayed == nil then return false, replayError end
    if not replayed and not MZPrison.Repository.markReleaseDelivered({
      sentenceId = sentenceId, destinationId = destinationId,
      targetCitizenid = identity.citizenid, sessionId = identity.sessionId,
      history = {
        operationId = operationId, requestFingerprint = requestFingerprint,
        sentenceId = sentenceId, action = 'release_destination_delivered',
        actorCitizenid = identity.citizenid, details = { destinationId = destinationId }
      }
    }) then return false, 'persistence_failed' end
    MZPrison.Bridge.audit('release_destination_delivered', identity, sentence, {
      operationId = operationId, result = 'delivered', status = 'released', destinationId = destinationId
    })
    return true, MZPrison.Repository.getReleaseDelivery(sentenceId)
  end)
end

function Service.acknowledgeConfinement(source, request)
  if not available() then return false, 'prison_unavailable' end
  if not closed(request, { sentenceId = true, facilityId = true, cellId = true }) then
    return false, 'invalid_request'
  end
  local identity, identityError = MZPrison.Bridge.resolveIdentity(source)
  if not identity then return false, identityError end
  local sentenceId = token(request.sentenceId, 8, 96)
  local facilityId = token(request.facilityId, 2, 64, '^[a-z0-9_-]+$')
  local cellId = token(request.cellId, 2, 64, '^[a-z0-9_-]+$')
  if not sentenceId or not facilityId or not cellId then return false, 'invalid_request' end
  local sentence = MZPrison.Repository.getById(sentenceId)
  local context = sentence and confinementFor(sentence) or nil
  if not sentence or tostring(sentence.status) ~= 'active'
    or tostring(sentence.target_citizenid) ~= identity.citizenid or not context
    or context.facilityId ~= facilityId or context.cellId ~= cellId then
    return false, 'confinement_not_found'
  end
  local position = positionFor(source)
  if not position or position.bucket ~= context.routingBucket
    or ((position.x - context.coords.x) ^ 2 + (position.y - context.coords.y) ^ 2
      + (position.z - context.coords.z) ^ 2) > 25 then return false, 'confinement_not_reached' end
  if tostring(sentence.confinement_status or '') ~= 'confirmed'
    and not MZPrison.Repository.markConfinement(sentenceId, 'confirmed') then
    return false, 'persistence_failed'
  end
  MZPrison.Bridge.audit('confinement_confirmed', identity, sentence, {
    result = 'confirmed', status = 'active'
  })
  return true
end

function Service.resumeSource(source)
  if not available() then return false, 'prison_unavailable' end
  local identity, identityError = MZPrison.Bridge.resolveIdentity(source)
  if not identity then return false, identityError end
  local sentence = MZPrison.Repository.getCurrent(identity.citizenid)
  if sentence and tostring(sentence.status) == 'release_pending' then
    return withLock('citizen:' .. identity.citizenid, function()
      sentence = MZPrison.Repository.getById(sentence.public_id)
      local pending = MZPrison.Repository.getPendingReleaseHistory
        and MZPrison.Repository.getPendingReleaseHistory(sentence.public_id) or nil
      local operationId = pending and tostring(pending.operation_id or pending.operationId) or ('auto_release:%s'):format(sentence.public_id)
      local requestFingerprint = pending and tostring(pending.request_fingerprint or pending.requestFingerprint)
        or fingerprint(sentence.public_id, 'time_complete')
      local action = pending and tostring(pending.action) or 'time_complete'
      return releaseSentence(sentence, nil, operationId, requestFingerprint, action)
    end)
  end
  if sentence and tostring(sentence.status) == 'active' and MZPrison.Repository.getActiveActivity
    and type(TriggerClientEvent) == 'function' then
    local activity = MZPrison.Repository.getActiveActivity(sentence.public_id)
    if activity then
      TriggerClientEvent('mz_prison:client:activity:result', identity.source, {
        action = 'resume', ok = true, result = activity
      })
    end
  end
  if sentence and tostring(sentence.status) == 'active' then
    local confined, confinementError = dispatchConfinement(identity, sentence)
    if not confined then return false, confinementError end
    pushSentenceStatus(identity.source, sentence)
    local settings = type(MZPrisonConfig.confinement) == 'table' and MZPrisonConfig.confinement or {}
    local grace = math.max(0, math.floor(tonumber(settings.resumeGraceSeconds) or 0))
    local cooldown = math.max(1, math.floor(tonumber(settings.correctionCooldownSeconds) or 10))
    confinementCorrections[identity.source] = os.time() + math.max(0, grace - cooldown)
  end
  if MZPrison.Repository.getPendingReleaseDelivery then
    local delivery = MZPrison.Repository.getPendingReleaseDelivery(identity.citizenid)
    if delivery then
      local released = MZPrison.Repository.getById(delivery.sentence_public_id)
      if released then return dispatchRelease(identity, released) end
    end
  end
  return true
end

function Service.tickOnce()
  if not available() then return false, 'prison_unavailable' end
  local seconds = math.max(1, math.floor(tonumber(MZPrisonConfig.tickSeconds) or 30))
  for _, candidate in ipairs(MZPrison.Repository.listPending()) do
    withLock('citizen:' .. tostring(candidate.target_citizenid), function()
      local sentence = MZPrison.Repository.getById(candidate.public_id)
      if not sentence then return false end
      if tostring(sentence.status) == 'active' then
        local source = MZPrison.Bridge.getSource(sentence.target_citizenid)
        if source then
          sentence = MZPrison.Repository.tick(sentence.public_id, seconds)
          if sentence then pushSentenceStatus(source, sentence) end
          local context = sentence and confinementFor(sentence) or nil
          local cooldown = math.max(1, math.floor(tonumber(
            type(MZPrisonConfig.confinement) == 'table'
              and MZPrisonConfig.confinement.correctionCooldownSeconds) or 10))
          local inside, correctionReason
          if context then inside, correctionReason = withinAllowedArea(source, context) end
          local death = context and MZPrison.Bridge.getDeathState(source) or nil
          if context and inside == false and type(death) == 'table' and death.deathState == 'alive'
            and os.time() - tonumber(confinementCorrections[source] or 0) >= cooldown then
            local identity = MZPrison.Bridge.resolveIdentity(source)
            if identity and identity.citizenid == tostring(sentence.target_citizenid) then
              local corrected = dispatchConfinement(identity, sentence)
              if corrected then
                MZPrison.Bridge.audit('confinement_corrected', identity, sentence, {
                  result = 'corrected', status = 'active', reason = correctionReason
                })
              end
            end
          end
        end
      end
      if sentence and tostring(sentence.status) == 'release_pending' then
        local pending = MZPrison.Repository.getPendingReleaseHistory
          and MZPrison.Repository.getPendingReleaseHistory(sentence.public_id) or nil
        local operationId = pending and tostring(pending.operation_id or pending.operationId)
          or ('auto_release:%s'):format(sentence.public_id)
        local requestFingerprint = pending and tostring(pending.request_fingerprint or pending.requestFingerprint)
          or fingerprint(sentence.public_id, 'time_complete')
        releaseSentence(sentence, nil, operationId, requestFingerprint,
          pending and tostring(pending.action) or 'time_complete')
      end
      return true
    end)
  end
end

function Service.validateConfiguration()
  local multi = type(MZPrisonConfig.multiCharge) == 'table' and MZPrisonConfig.multiCharge or {}
  if multi.enabled == true then
    local maximum = math.floor(tonumber(multi.maximumCharges) or 0)
    local cap = math.floor(tonumber(multi.maximumSentenceSeconds) or 0)
    if maximum < 1 or maximum > 8 or cap <= 0 then return false, 'multi_charge_policy_incomplete' end
  end
  local uniform = type(MZPrisonConfig.uniform) == 'table' and MZPrisonConfig.uniform or {}
  if uniform.enabled == true and (type(uniform.garments) ~= 'table' or #uniform.garments < 1) then
    return false, 'prison_uniform_not_configured'
  end
  local confinement = type(MZPrisonConfig.confinement) == 'table' and MZPrisonConfig.confinement or {}
  if confinement.enabled ~= true then return true end
  local found = false
  for facilityId, facility in pairs(type(MZPrisonConfig.facilities) == 'table' and MZPrisonConfig.facilities or {}) do
    if type(facility) == 'table' and facility.enabled == true then
      found = true
      local bucket = tonumber(facility.routingBucket)
      local orgCode = token(facility.orgCode, 2, 64, '^[a-z0-9_-]+$')
      local intakeFound = false
      for _, point in pairs(type(facility.intakePoints) == 'table' and facility.intakePoints or {}) do
        local coords = type(point) == 'table' and (point.coords or point) or nil
        if type(point) == 'table' and point.enabled == true and type(coords) == 'table'
          and tonumber(coords.x) and tonumber(coords.y) and tonumber(coords.z)
          and tonumber(point.radius) and tonumber(point.routingBucket) then intakeFound = true; break end
      end
      if not token(facilityId, 2, 64, '^[a-z0-9_-]+$') or not orgCode or not bucket
        or bucket < 0 or bucket % 1 ~= 0 or not intakeFound
        or not configuredCell(facility) or not hasAllowedArea(facility) then
        return false, 'facility_invalid:' .. tostring(facilityId)
      end
    end
  end
  if found then return true end
  return false, 'confinement_not_configured'
end

function Service.cleanupSource(source)
  source = tonumber(source)
  activityRates[source], confinementCorrections[source] = nil, nil
end
function Service.stop() locks, activityRates, confinementCorrections = {}, {}, {} end

MZPrison.Service = Service
