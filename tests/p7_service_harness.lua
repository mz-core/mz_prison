local function expect(condition, message) if not condition then error(message, 2) end end

MZPrisonConfig = {
  clockMode = 'online', tickSeconds = 30, intakeEnabled = false, intakeMaximumDistance = 3.0,
  intakePoints = {}, releasePoints = {},
  sentenceRulesEnabled = false, legalVersion = 'test-v1', jurisdictions = { police = { enabled = true } },
  sentenceRules = { custodial = { enabled = true, name = 'Custodial', durationSeconds = 120 } },
  reductionRulesEnabled = false,
  reductionRules = { work = { enabled = true, name = 'Work credit', seconds = 60 } },
  manualReleaseEnabled = false, manualReleaseReasons = {}, jobsEnabled = false, jobs = {}
}

local sentences, byOperation, histories, property = {}, {}, {}, {}
local retainCalls, restoreCalls, audits, target2Online = 0, 0, 0, false

function GetPlayerPed(source) return source end
function GetEntityCoords(source) return source == 2 and { x = 10.0, y = 20.0, z = 30.0 } or { x = 11.0, y = 20.0, z = 30.0 } end
function GetPlayerRoutingBucket() return 0 end

MZPrison = {
  Bridge = {
    resolveIdentity = function(source)
      return { source = source, sessionId = source * 10, characterId = source * 100,
        citizenid = source == 1 and 'OFFICER1' or source == 2 and 'TARGET1' or 'TARGET2', active = true }
    end,
    getCharacter = function(citizenid) return { citizenid = citizenid } end,
    getSource = function(citizenid)
      if citizenid == 'TARGET1' then return 2 end
      if citizenid == 'TARGET2' and target2Online then return 3 end
      return nil, 'target_offline'
    end,
    retainProperty = function(_, sentenceId)
      retainCalls = retainCalls + 1
      return { items = { { retainedSlot = 1, instanceUid = 'UID1', item = 'phone', amount = 1,
        originalInventoryType = 'main', originalSlot = 1 } } }
    end,
    restoreProperty = function(_, sentenceId)
      restoreCalls = restoreCalls + 1
      return { sentenceId = sentenceId, items = property[sentenceId] or {} }
    end,
    audit = function() audits = audits + 1 end
  }
}

MZPrison.Repository = {
  getHistoryOperation = function(id) return histories[id] end,
  getByOperation = function(id) return byOperation[id] end,
  getById = function(id) return sentences[id] end,
  getCurrent = function(citizenid)
    for _, value in pairs(sentences) do
      if value.target_citizenid == citizenid and value.status ~= 'released' then return value end
    end
  end,
  createSentence = function(data)
    local row = {
      public_id = data.publicId, operation_id = data.operationId,
      target_citizenid = data.targetCitizenid, case_public_id = data.caseId,
      org_code = data.orgCode, rule_code = data.ruleCode, rule_name = data.ruleName,
      duration_seconds = data.durationSeconds, remaining_seconds = data.durationSeconds,
      status = 'intake_pending', property_status = 'pending'
    }
    sentences[row.public_id], byOperation[row.operation_id] = row, row
    histories[data.history.operationId] = { requestFingerprint = data.history.requestFingerprint }
    return true
  end,
  activateWithProperty = function(id, items, history)
    sentences[id].status, sentences[id].property_status = 'active', 'retained'
    property[id] = items
    histories[history.operationId] = { requestFingerprint = history.requestFingerprint }
    return true
  end,
  setError = function(id, errorCode) sentences[id].last_error = errorCode; return true end,
  listProperty = function(id) return property[id] or {} end,
  reduce = function(sentence, seconds, history)
    sentence.remaining_seconds = math.max(0, sentence.remaining_seconds - seconds)
    sentence.status = sentence.remaining_seconds == 0 and 'release_pending' or 'active'
    histories[history.operationId] = { requestFingerprint = history.requestFingerprint }
    return true, sentence.remaining_seconds
  end,
  beginRelease = function(sentence, history)
    sentence.status = 'release_pending'
    histories[history.operationId] = { requestFingerprint = history.requestFingerprint }
    return true
  end,
  finishRelease = function(id, history)
    sentences[id].status, sentences[id].property_status, sentences[id].remaining_seconds = 'released', 'restored', 0
    histories[history.operationId] = { requestFingerprint = history.requestFingerprint }
    return true
  end,
  tick = function(id, seconds)
    local sentence = sentences[id]
    sentence.remaining_seconds = math.max(0, sentence.remaining_seconds - seconds)
    if sentence.remaining_seconds == 0 then sentence.status = 'release_pending' end
    return sentence
  end,
  listPending = function()
    local out = {}
    for _, value in pairs(sentences) do
      if value.status == 'active' or value.status == 'release_pending' then out[#out + 1] = value end
    end
    return out
  end
}

dofile('server/service.lua')

local request = { ruleCode = 'custodial', caseId = 'case:0001', operationId = 'sentence_request_001', orgCode = 'police' }
local disabledOk, disabledError = MZPrison.Service.requestSentence(1, 2, request)
expect(disabledOk == false and disabledError == 'intake_not_configured', 'intake sem coordenadas foi aceito')

MZPrisonConfig.intakeEnabled = true
MZPrisonConfig.intakePoints = { booking = { coords = { x = 100.0, y = 100.0, z = 100.0 }, radius = 2.0 } }
local pointOk, pointError = MZPrison.Service.requestSentence(1, 2, request)
expect(pointOk == false and pointError == 'intake_point_required', 'intake fora do ponto foi aceito')
MZPrisonConfig.intakePoints = { booking = { coords = { x = 10.0, y = 20.0, z = 30.0 }, radius = 2.0 } }
local rulesOk, rulesError = MZPrison.Service.requestSentence(1, 2, request)
expect(rulesOk == false and rulesError == 'rules_disabled', 'regra de sentenca desabilitada foi aceita')
MZPrisonConfig.sentenceRulesEnabled = true

local invalidOk, invalidError = MZPrison.Service.requestSentence(1, 2, {
  ruleCode = 'custodial', caseId = 'case:0001', operationId = 'sentence_request_002',
  orgCode = 'police', durationSeconds = 1
})
expect(invalidOk == false and invalidError == 'invalid_request', 'duracao client-authoritative foi aceita')

local createdOk, sentence = MZPrison.Service.requestSentence(1, 2, request)
expect(createdOk == true and sentence.status == 'active' and sentence.remaining_seconds == 120
  and retainCalls == 1, 'sentenca/intake falhou')
local replayOk = MZPrison.Service.requestSentence(1, 2, request)
expect(replayOk == true and retainCalls == 1, 'replay repetiu retencao')

local duplicateOk, duplicateError = MZPrison.Service.requestSentence(1, 2, {
  ruleCode = 'custodial', caseId = 'case:0002', operationId = 'sentence_request_003', orgCode = 'police'
})
expect(duplicateOk == false and duplicateError == 'active_sentence_exists', 'segunda sentenca ativa foi aceita')

local reductionDisabledOk, reductionDisabledError = MZPrison.Service.reduceSentence(1, 'TARGET1', {
  ruleCode = 'work', operationId = 'reduction_request_001', orgCode = 'police'
})
expect(reductionDisabledOk == false and reductionDisabledError == 'rules_disabled', 'reducao desabilitada foi aceita')
MZPrisonConfig.reductionRulesEnabled = true
local reducedOk, reduced = MZPrison.Service.reduceSentence(1, 'TARGET1', {
  ruleCode = 'work', operationId = 'reduction_request_001', orgCode = 'police'
})
expect(reducedOk == true and reduced.remaining_seconds == 60, 'reducao configurada falhou')
local releasedOk, released = MZPrison.Service.reduceSentence(1, 'TARGET1', {
  ruleCode = 'work', operationId = 'reduction_request_002', orgCode = 'police'
})
expect(releasedOk == true and released.status == 'released' and restoreCalls == 1, 'soltura/devolucao falhou')

local manualOk, manualError = MZPrison.Service.releasePrisoner(1, 'TARGET1', {
  reasonCode = 'court', operationId = 'release_request_001', orgCode = 'police'
})
expect(manualOk == false and manualError == 'manual_release_disabled', 'soltura manual desabilitada foi aceita')

local target2Request = { ruleCode = 'custodial', caseId = 'case:0002', operationId = 'sentence_request_004', orgCode = 'police' }
local target2Created = MZPrison.Service.requestSentence(1, 3, target2Request)
expect(target2Created == true, 'segunda identidade nao recebeu sentenca')
local target2Id = 'sentence:sentence_request_004'
MZPrison.Service.tickOnce()
expect(sentences[target2Id].remaining_seconds == 120, 'tempo offline foi contado')
target2Online = true
MZPrison.Service.tickOnce()
expect(sentences[target2Id].remaining_seconds == 90 and audits >= 4, 'tempo online/reconnect nao foi contado')

print('mz_prison P7 service harness: PASS cases=13')
