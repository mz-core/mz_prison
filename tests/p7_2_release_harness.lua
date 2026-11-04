local function expect(condition, message) if not condition then error(message, 2) end end
local sentence = {
  public_id = 'sentence:release-test', target_citizenid = 'PRISONER1', org_code = 'police',
  remaining_seconds = 0, status = 'release_pending', property_status = 'retained'
}
local histories, delivery = {}, nil
local restoreCalls, finishCalls, markCalls, expectedCount, events, buckets = 0, 0, 0, nil, {}, {}
local restoreFailure = true

local function countEvents(name)
  local count = 0
  for _, event in ipairs(events) do if event.name == name then count = count + 1 end end
  return count
end
local function lastEvent(name)
  for index = #events, 1, -1 do if events[index].name == name then return events[index] end end
end
local atExit = true

MZPrisonConfig = {
  tickSeconds = 30, jobsEnabled = false, activityRateLimit = {}, jobs = {},
  manualReleaseEnabled = true, manualReleaseReasons = { court = { enabled = true } },
  releasePoints = {
    exit_a = {
      enabled = true, orgCode = 'police', coords = { x = 10.0, y = 20.0, z = 30.0 },
      heading = 90.0, routingBucket = 0, radius = 3.0
    }
  }
}

function SetPlayerRoutingBucket(source, value) buckets[#buckets + 1] = { source = source, value = value } end
function TriggerClientEvent(name, source, payload) events[#events + 1] = { name = name, source = source, payload = payload } end
function GetPlayerPed(source) return source end
function GetPlayerRoutingBucket() return 0 end
function GetEntityCoords()
  return atExit and { x = 10.0, y = 20.0, z = 30.0 } or { x = 100.0, y = 100.0, z = 100.0 }
end

MZPrison = {
  Prepare = { ready = true },
  Bridge = {
    resolveIdentity = function(source)
      if source == 1 then return { source = 1, sessionId = 11, characterId = 111, citizenid = 'OFFICER1', active = true } end
      if source == 4 then return { source = 4, sessionId = 44, characterId = 444, citizenid = 'PRISONER1', active = true } end
      return nil, 'identity_unavailable'
    end,
    getSource = function(citizenid) return citizenid == 'PRISONER1' and 4 or nil, 'target_offline' end,
    restoreProperty = function(_, sentenceId, count)
      restoreCalls = restoreCalls + 1
      expectedCount = count
      if restoreFailure then return nil, 'inventory_busy' end
      return { sentenceId = sentenceId, items = { { item = 'phone' } }, replayed = restoreCalls > 2 }
    end,
    removeUniform = function() return {} end,
    audit = function() return true end
  },
  Repository = {
    getHistoryOperation = function(id) return histories[id] end,
    getPendingReleaseHistory = function()
      for _, row in pairs(histories) do
        if row.action == 'time_complete' or row.action == 'manual_release' then return row end
      end
    end,
    getById = function(id) return id == sentence.public_id and sentence or nil end,
    getCurrent = function(citizenid)
      return citizenid == 'PRISONER1' and sentence.status ~= 'released' and sentence or nil
    end,
    listProperty = function() return { { item = 'phone', status = 'retained' } } end,
    listActivities = function() return {} end,
    listPending = function() return sentence.status ~= 'released' and { sentence } or {} end,
    beginRelease = function(_, history)
      histories[history.operationId] = {
        operation_id = history.operationId, request_fingerprint = history.requestFingerprint,
        sentence_public_id = history.sentenceId, action = history.action
      }
      return true
    end,
    setError = function(_, code) sentence.last_error = code; return true end,
    finishRelease = function(_, history, nextDelivery)
      finishCalls = finishCalls + 1
      sentence.status, sentence.property_status, sentence.remaining_seconds = 'released', 'restored', 0
      histories[history.operationId] = {
        operation_id = history.operationId, request_fingerprint = history.requestFingerprint,
        sentence_public_id = history.sentenceId, action = history.action
      }
      if nextDelivery then
        delivery = {
          sentence_public_id = sentence.public_id, destination_id = nextDelivery.destinationId,
          target_citizenid = nextDelivery.targetCitizenid, status = 'pending'
        }
      end
      return true
    end,
    getReleaseDelivery = function(id) return id == sentence.public_id and delivery or nil end,
    getPendingReleaseDelivery = function(citizenid)
      return citizenid == 'PRISONER1' and delivery and delivery.status == 'pending' and delivery or nil
    end,
    markReleaseDelivered = function(data)
      markCalls = markCalls + 1
      delivery.status, delivery.delivered_session_id = 'delivered', data.sessionId
      histories[data.history.operationId] = {
        operation_id = data.history.operationId, request_fingerprint = data.history.requestFingerprint,
        action = data.history.action
      }
      return true
    end
  }
}

dofile('server/service.lua')

MZPrison.Service.tickOnce()
expect(sentence.status == 'release_pending' and sentence.last_error == 'inventory_busy' and restoreCalls == 1,
  'falha de devolucao nao manteve soltura pendente')
expect(expectedCount == 1, 'contagem esperada nao foi enviada ao owner do inventario')

restoreFailure = false
MZPrison.Service.tickOnce()
expect(sentence.status == 'released' and sentence.property_status == 'restored'
  and restoreCalls == 2 and finishCalls == 1, 'retomada nao concluiu devolucao/soltura')
local releaseEvent = lastEvent('mz_prison:client:release')
expect(delivery and delivery.status == 'pending' and releaseEvent
  and releaseEvent.payload.destinationId == 'exit_a' and buckets[1].value == 0,
  'destino configurado nao foi despachado pelo servidor')

local beforeResumeRelease = countEvents('mz_prison:client:release')
local resumedOk = MZPrison.Service.resumeSource(4)
expect(resumedOk == true and countEvents('mz_prison:client:release') == beforeResumeRelease + 1
  and restoreCalls == 2, 'reconnect nao retomou destino pendente ou repetiu devolucao')

atExit = false
local distantOk, distantError = MZPrison.Service.acknowledgeRelease(4, {
  sentenceId = sentence.public_id, destinationId = 'exit_a'
})
expect(distantOk == false and distantError == 'release_destination_not_reached' and markCalls == 0,
  'cliente confirmou destino sem estar no ponto/bucket')
atExit = true

local ackOk, ack = MZPrison.Service.acknowledgeRelease(4, {
  sentenceId = sentence.public_id, destinationId = 'exit_a'
})
expect(ackOk == true and ack.status == 'delivered' and markCalls == 1, 'ack de soltura nao foi persistido')

local replayOk = MZPrison.Service.acknowledgeRelease(4, {
  sentenceId = sentence.public_id, destinationId = 'exit_a'
})
expect(replayOk == true and markCalls == 1, 'replay do ack duplicou a entrega')

local forgedOk, forgedError = MZPrison.Service.acknowledgeRelease(1, {
  sentenceId = sentence.public_id, destinationId = 'exit_a'
})
expect(forgedOk == false and forgedError == 'release_delivery_not_found', 'outro personagem confirmou a soltura')

sentence.status, sentence.property_status, sentence.remaining_seconds = 'release_pending', 'retained', 15
delivery = nil
histories = { existing = {
  operation_id = 'auto_release:sentence:release-test', request_fingerprint = 'existing', action = 'time_complete'
} }
local conflictOk, conflictError = MZPrison.Service.releasePrisoner(1, 'PRISONER1', {
  reasonCode = 'court', operationId = 'manual_release_request_001', orgCode = 'police'
})
expect(conflictOk == false and conflictError == 'release_operation_pending', 'operacao de soltura concorrente foi aceita')

sentence.status, sentence.property_status, sentence.remaining_seconds = 'active', 'retained', 15
histories, delivery = {}, nil
local finishBefore = finishCalls
local manualOk, manual = MZPrison.Service.releasePrisoner(1, 'PRISONER1', {
  reasonCode = 'court', operationId = 'manual_release_request_002', orgCode = 'police'
})
expect(manualOk == true and manual.status == 'released' and finishCalls == finishBefore + 1,
  'soltura manual configurada nao concluiu')
local manualReplayOk, manualReplay = MZPrison.Service.releasePrisoner(1, 'PRISONER1', {
  reasonCode = 'court', operationId = 'manual_release_request_002', orgCode = 'police'
})
expect(manualReplayOk == true and manualReplay.status == 'released' and finishCalls == finishBefore + 1,
  'replay da soltura manual duplicou a operacao')

sentence.status, sentence.property_status, sentence.remaining_seconds = 'active', 'retained', 15
histories, delivery = {}, nil
MZPrisonConfig.releasePoints.exit_b = {
  enabled = true, orgCode = 'police', coords = { x = 40.0, y = 50.0, z = 60.0 },
  routingBucket = 0, radius = 3.0
}
local ambiguousOk = MZPrison.Service.releasePrisoner(1, 'PRISONER1', {
  reasonCode = 'court', operationId = 'manual_release_request_003', orgCode = 'police'
})
expect(ambiguousOk == true and delivery == nil, 'destino ambiguo foi escolhido arbitrariamente')

print('mz_prison P7.2 release harness: PASS cases=11')
