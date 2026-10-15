MZPrison = MZPrison or {}

local Service = {}
local locks = {}

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
  ruleCode = token(ruleCode, 2, 64, '^[a-z0-9_-]+$')
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
  return out
end

local function atIntakePoint(source)
  if type(GetPlayerPed) ~= 'function' or type(GetEntityCoords) ~= 'function' then
    return false, 'position_unavailable'
  end
  local ped = GetPlayerPed(source)
  if not ped or ped <= 0 then return false, 'position_unavailable' end
  local position = GetEntityCoords(ped)
  local x, y, z = position and tonumber(position.x), position and tonumber(position.y), position and tonumber(position.z)
  if not x or not y or not z then return false, 'position_unavailable' end
  local bucket = type(GetPlayerRoutingBucket) == 'function' and GetPlayerRoutingBucket(source) or nil
  for _, point in pairs(MZPrisonConfig.intakePoints) do
    local coords = type(point) == 'table' and (point.coords or point) or nil
    local px, py, pz = coords and tonumber(coords.x), coords and tonumber(coords.y), coords and tonumber(coords.z)
    local radius = type(point) == 'table' and tonumber(point.radius) or nil
    radius = radius or tonumber(MZPrisonConfig.intakeMaximumDistance) or 3.0
    local pointBucket = type(point) == 'table' and tonumber(point.routingBucket) or nil
    if px and py and pz and radius > 0 and radius <= 25
      and (not pointBucket or bucket == pointBucket)
      and ((x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2) <= radius ^ 2 then return true end
  end
  return false, 'intake_point_required'
end

local function releaseSentence(sentence, actor, operationId, requestFingerprint, action)
  local replayed, replayError = historyReplay(operationId, requestFingerprint)
  if replayed == nil then return false, replayError end
  if not replayed then
    local begun = MZPrison.Repository.beginRelease(sentence, {
      operationId = operationId, requestFingerprint = requestFingerprint,
      sentenceId = sentence.public_id, action = action,
      actorCitizenid = actor and actor.citizenid or nil
    })
    if not begun then return false, 'persistence_failed' end
  end
  sentence = MZPrison.Repository.getById(sentence.public_id)
  if tostring(sentence.status) == 'released' then return true, sentenceResponse(sentence) end
  local targetSource, sourceError = MZPrison.Bridge.getSource(sentence.target_citizenid)
  if not targetSource then MZPrison.Repository.setError(sentence.public_id, sourceError); return false, sourceError end
  local restored, restoreError = MZPrison.Bridge.restoreProperty(targetSource, sentence.public_id)
  if not restored then MZPrison.Repository.setError(sentence.public_id, restoreError); return false, restoreError end
  local finishOperation = operationId .. ':property'
  local finishFingerprint = fingerprint(sentence.public_id, 'property_restored')
  local finishReplay, finishError = historyReplay(finishOperation, finishFingerprint)
  if finishReplay == nil then return false, finishError end
  if not finishReplay and not MZPrison.Repository.finishRelease(sentence.public_id, {
    operationId = finishOperation, requestFingerprint = finishFingerprint,
    sentenceId = sentence.public_id, action = 'property_restored',
    actorCitizenid = actor and actor.citizenid or nil,
    details = { itemCount = #(restored.items or {}) }
  }) then return false, 'persistence_failed' end
  sentence = MZPrison.Repository.getById(sentence.public_id)
  MZPrison.Bridge.audit('released', actor, sentence, {
    operationId = operationId, result = 'released', status = sentence.status
  })
  return true, sentenceResponse(sentence)
end

function Service.requestSentence(actorSource, targetSource, request)
  if not closed(request, {
    chargeId = true, ruleCode = true, ruleName = true, sentenceSeconds = true,
    legalVersion = true, caseId = true, operationId = true, orgCode = true
  }) then
    return false, 'invalid_request'
  end
  if MZPrisonConfig.intakeEnabled ~= true or type(MZPrisonConfig.intakePoints) ~= 'table'
    or next(MZPrisonConfig.intakePoints) == nil then return false, 'intake_not_configured' end
  local actor, actorError = MZPrison.Bridge.resolveIdentity(actorSource)
  if not actor then return false, actorError end
  local target, targetError = MZPrison.Bridge.resolveIdentity(targetSource)
  if not target then return false, targetError end
  if actor.citizenid == target.citizenid then return false, 'self_sentence_forbidden' end
  local atPoint, pointError = atIntakePoint(target.source)
  if not atPoint then return false, pointError end
  local orgCode = token(request.orgCode, 2, 64, '^[a-z0-9_-]+$')
  local caseId = token(request.caseId, 8, 160)
  local chargeId = token(request.chargeId, 8, 160)
  local operationId = token(request.operationId, 16, 64, '^[%w_-]+$')
  local ruleName = trim(request.ruleName)
  local legalVersion = trim(request.legalVersion)
  local sentenceSeconds = tonumber(request.sentenceSeconds)
  sentenceSeconds = sentenceSeconds and math.floor(sentenceSeconds) or nil
  if not orgCode or not caseId or not chargeId or not operationId or ruleName == ''
    or #ruleName > 160 or legalVersion == '' or #legalVersion > 64
    or not sentenceSeconds or sentenceSeconds <= 0 then
    return false, 'invalid_request'
  end
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
      local created = MZPrison.Repository.createSentence({
        publicId = publicId, operationId = operationId, targetCitizenid = target.citizenid,
        caseId = caseId, chargeId = chargeId, orgCode = orgCode,
        ruleCode = sentenceRule.code, ruleName = ruleName,
        legalVersion = legalVersion, durationSeconds = sentenceSeconds,
        clockMode = MZPrisonConfig.clockMode, actorCitizenid = actor.citizenid,
        history = {
          operationId = operationId, requestFingerprint = requestFingerprint,
          sentenceId = publicId, action = 'sentence_created', actorCitizenid = actor.citizenid,
          details = { chargeId = chargeId, ruleCode = sentenceRule.code, durationSeconds = sentenceSeconds }
        }
      })
      if not created then return false, 'persistence_failed' end
      sentence = MZPrison.Repository.getById(publicId)
    end
    if tostring(sentence.status) == 'intake_pending' then
      local retained, retainError = MZPrison.Bridge.retainProperty(target.source, publicId)
      if not retained then
        MZPrison.Repository.setError(publicId, retainError)
        MZPrison.Bridge.audit('intake_failed', actor, sentence, { operationId = operationId, result = 'pending', reason = retainError })
        return false, retainError
      end
      local propertyOperation = operationId .. ':property'
      local propertyFingerprint = fingerprint(publicId, 'property_retained')
      if not MZPrison.Repository.activateWithProperty(publicId, retained.items or {}, {
        operationId = propertyOperation, requestFingerprint = propertyFingerprint,
        sentenceId = publicId, action = 'property_retained', actorCitizenid = actor.citizenid,
        details = { itemCount = #(retained.items or {}) }
      }) then return false, 'persistence_failed' end
      sentence = MZPrison.Repository.getById(publicId)
    end
    MZPrison.Bridge.audit('sentence_started', actor, sentence, { operationId = operationId, result = 'active', status = sentence.status })
    return true, sentenceResponse(sentence)
  end)
end

function Service.getSentence(citizenid)
  citizenid = token(citizenid, 2, 64)
  if not citizenid then return false, 'invalid_citizenid' end
  local character, characterError = MZPrison.Bridge.getCharacter(citizenid)
  if not character then return false, characterError end
  local sentence = MZPrison.Repository.getCurrent(citizenid)
  return true, sentence and sentenceResponse(sentence) or { active = false, citizenid = citizenid }
end

function Service.reduceSentence(actorSource, citizenid, request)
  if not closed(request, { ruleCode = true, operationId = true, orgCode = true }) then return false, 'invalid_request' end
  local actor, actorError = MZPrison.Bridge.resolveIdentity(actorSource)
  if not actor then return false, actorError end
  citizenid = token(citizenid, 2, 64)
  local orgCode = token(request.orgCode, 2, 64, '^[a-z0-9_-]+$')
  local operationId = token(request.operationId, 16, 64, '^[%w_-]+$')
  if not citizenid or not orgCode or not operationId then return false, 'invalid_request' end
  local reduction, ruleError = rule('reductionRules', orgCode, request.ruleCode)
  if not reduction then return false, ruleError end
  local requestFingerprint = fingerprint(citizenid, orgCode, reduction.code, reduction.seconds)
  return withLock('citizen:' .. citizenid, function()
    local replayed, replayError = historyReplay(operationId, requestFingerprint)
    if replayed == nil then return false, replayError end
    local sentence = MZPrison.Repository.getCurrent(citizenid)
    if not sentence then return false, 'active_sentence_not_found' end
    if tostring(sentence.org_code) ~= orgCode then return false, 'organization_mismatch' end
    if replayed then return true, sentenceResponse(sentence) end
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
  if not closed(request, { reasonCode = true, operationId = true, orgCode = true }) then return false, 'invalid_request' end
  if MZPrisonConfig.manualReleaseEnabled ~= true then return false, 'manual_release_disabled' end
  local actor, actorError = MZPrison.Bridge.resolveIdentity(actorSource)
  if not actor then return false, actorError end
  citizenid = token(citizenid, 2, 64)
  local orgCode = token(request.orgCode, 2, 64, '^[a-z0-9_-]+$')
  local operationId = token(request.operationId, 16, 64, '^[%w_-]+$')
  local reasonCode = token(request.reasonCode, 2, 64, '^[a-z0-9_-]+$')
  local reason = reasonCode and type(MZPrisonConfig.manualReleaseReasons) == 'table'
    and MZPrisonConfig.manualReleaseReasons[reasonCode] or nil
  if not citizenid or not orgCode or not operationId or type(reason) ~= 'table' or reason.enabled ~= true then
    return false, 'release_reason_not_configured'
  end
  local requestFingerprint = fingerprint(citizenid, orgCode, reasonCode)
  return withLock('citizen:' .. citizenid, function()
    local sentence = MZPrison.Repository.getCurrent(citizenid)
    if not sentence then return false, 'active_sentence_not_found' end
    if tostring(sentence.org_code) ~= orgCode then return false, 'organization_mismatch' end
    return releaseSentence(sentence, actor, operationId, requestFingerprint, 'manual_release')
  end)
end

function Service.tickOnce()
  local seconds = math.max(1, math.floor(tonumber(MZPrisonConfig.tickSeconds) or 30))
  for _, candidate in ipairs(MZPrison.Repository.listPending()) do
    withLock('citizen:' .. tostring(candidate.target_citizenid), function()
      local sentence = MZPrison.Repository.getById(candidate.public_id)
      if not sentence then return false end
      if tostring(sentence.status) == 'active' then
        local source = MZPrison.Bridge.getSource(sentence.target_citizenid)
        if source then sentence = MZPrison.Repository.tick(sentence.public_id, seconds) end
      end
      if sentence and tostring(sentence.status) == 'release_pending' then
        local operationId = ('auto_release:%s'):format(sentence.public_id)
        releaseSentence(sentence, nil, operationId, fingerprint(sentence.public_id, 'time_complete'), 'time_complete')
      end
      return true
    end)
  end
end

function Service.stop() locks = {} end

MZPrison.Service = Service
