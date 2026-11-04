local function expect(condition, message) if not condition then error(message, 2) end end
local now, timer, bucket, atPoint = 1000, 0, 7, true
local activities, histories = {}, {}
local sentence = {
  public_id = 'sentence:activity-test', target_citizenid = 'PRISONER1', org_code = 'police',
  remaining_seconds = 300, status = 'active', property_status = 'retained'
}
os.time = function() return now end
function GetGameTimer() timer = timer + 1; return timer end
function GetPlayerPed(source) return source end
function GetPlayerRoutingBucket() return bucket end
function GetEntityCoords() return atPoint and { x = 10.0, y = 20.0, z = 30.0 } or { x = 100.0, y = 100.0, z = 100.0 } end

MZPrisonConfig = {
  jobsEnabled = false, activityRateLimit = { maximum = 50, windowMs = 5000 }, jobs = {},
  releasePoints = {}, tickSeconds = 30
}

local function summary(jobCode)
  local count, seconds, latest = 0, 0, 0
  for _, activity in pairs(activities) do
    if activity.job_code == jobCode and activity.status == 'completed' then
      count, seconds = count + 1, seconds + activity.reduction_seconds
      latest = math.max(latest, activity.completed_at or 0)
    end
  end
  return { completed_count = count, reduction_seconds = seconds, last_completed_at = latest }
end

MZPrison = {
  Prepare = { ready = true },
  Bridge = {
    resolveIdentity = function(source)
      if source ~= 4 then return nil, 'identity_unavailable' end
      return { source = 4, sessionId = 44, characterId = 444, citizenid = 'PRISONER1', active = true }
    end,
    audit = function() return true end
  },
  Repository = {
    getHistoryOperation = function(id) return histories[id] end,
    getCurrent = function(citizenid) return citizenid == 'PRISONER1' and sentence or nil end,
    getById = function(id) return id == sentence.public_id and sentence or nil end,
    listProperty = function() return {} end,
    listActivities = function()
      local out = {}; for _, row in pairs(activities) do out[#out + 1] = row end; return out
    end,
    getActivityByOperation = function(id)
      for _, row in pairs(activities) do if row.operation_id == id then return row end end
    end,
    getActivity = function(id) return activities[id] end,
    getActiveActivity = function()
      for _, row in pairs(activities) do if row.status == 'in_progress' then return row end end
    end,
    getActivitySummary = function(_, jobCode) return summary(jobCode) end,
    createActivity = function(data)
      activities[data.publicId] = {
        public_id = data.publicId, operation_id = data.operationId, sentence_public_id = data.sentenceId,
        target_citizenid = data.targetCitizenid, job_code = data.jobCode, point_id = data.pointId,
        duration_seconds = data.durationSeconds, reduction_seconds = data.reductionSeconds,
        status = 'in_progress', available_at_epoch = data.availableAt
      }
      histories[data.history.operationId] = { request_fingerprint = data.history.requestFingerprint }
      return true
    end,
    completeActivity = function(sentenceRow, activity, remaining, history)
      activity.status, activity.completed_at = 'completed', now
      sentenceRow.remaining_seconds = remaining
      histories[history.operationId] = { request_fingerprint = history.requestFingerprint }
      return true
    end
  }
}

dofile('server/service.lua')

local disabledOk, disabledError = MZPrison.Service.startActivity(4, {
  jobCode = 'cleaning', pointId = 'block_a', requestId = 'activity-request-001'
})
expect(disabledOk == false and disabledError == 'activities_disabled', 'atividades desabilitadas foram aceitas')

MZPrisonConfig.jobsEnabled = true
MZPrisonConfig.jobs.cleaning = {
  enabled = true, durationSeconds = 10, reductionSeconds = 30,
  maximumCompletionsPerSentence = 1, maximumReductionSecondsPerSentence = 30, cooldownSeconds = 0,
  points = { block_a = { enabled = true, coords = { x = 10.0, y = 20.0, z = 30.0 }, radius = 2.0, routingBucket = 7 } }
}
bucket = 0
local bucketOk, bucketError = MZPrison.Service.startActivity(4, {
  jobCode = 'cleaning', pointId = 'block_a', requestId = 'activity-request-002'
})
expect(bucketOk == false and bucketError == 'activity_bucket_required', 'routing bucket incorreto foi aceito')
bucket = 7

local startedOk, activity = MZPrison.Service.startActivity(4, {
  jobCode = 'cleaning', pointId = 'block_a', requestId = 'activity-request-003'
})
expect(startedOk == true and activity.status == 'in_progress', 'atividade configurada nao iniciou')

local duplicateOk, duplicateError = MZPrison.Service.startActivity(4, {
  jobCode = 'cleaning', pointId = 'block_a', requestId = 'activity-request-004'
})
expect(duplicateOk == false and duplicateError == 'activity_already_active', 'atividade simultanea foi aceita')

local earlyOk, earlyError = MZPrison.Service.completeActivity(4, {
  activityId = activity.public_id, requestId = 'complete-request-001'
})
expect(earlyOk == false and earlyError == 'activity_incomplete', 'duracao server-side foi ignorada')

now = 1010; atPoint = false
local distanceOk, distanceError = MZPrison.Service.completeActivity(4, {
  activityId = activity.public_id, requestId = 'complete-request-002'
})
expect(distanceOk == false and distanceError == 'activity_point_required', 'conclusao distante foi aceita')
atPoint = true

local completedOk, completed = MZPrison.Service.completeActivity(4, {
  activityId = activity.public_id, requestId = 'complete-request-003'
})
expect(completedOk == true and completed.remaining_seconds == 270 and activity.status == 'completed',
  'conclusao nao aplicou reducao atomica')

local replayOk, replay = MZPrison.Service.completeActivity(4, {
  activityId = activity.public_id, requestId = 'complete-request-004'
})
expect(replayOk == true and replay.status == 'completed' and sentence.remaining_seconds == 270,
  'replay duplicou reducao')

MZPrison.Service.stop(); dofile('server/service.lua')
local restartOk, restarted = MZPrison.Service.startActivity(4, {
  jobCode = 'cleaning', pointId = 'block_a', requestId = 'activity-request-003'
})
expect(restartOk == true and restarted.status == 'completed', 'replay apos restart nao foi idempotente')

local limitOk, limitError = MZPrison.Service.startActivity(4, {
  jobCode = 'cleaning', pointId = 'block_a', requestId = 'activity-request-005'
})
expect(limitOk == false and limitError == 'activity_limit_reached', 'limite configurado foi excedido')

local forgedOk, forgedError = MZPrison.Service.completeActivity(4, {
  activityId = 'activity:invented', requestId = 'complete-request-005'
})
expect(forgedOk == false and forgedError == 'activity_not_found', 'atividade arbitraria foi aceita')

MZPrison.Service.stop(); dofile('server/service.lua')
MZPrisonConfig.activityRateLimit.maximum = 1
MZPrison.Service.completeActivity(4, { activityId = 'activity:invented', requestId = 'spam-request-001' })
local spamOk, spamError = MZPrison.Service.completeActivity(4, {
  activityId = 'activity:invented', requestId = 'spam-request-002'
})
expect(spamOk == false and spamError == 'rate_limited', 'antispam configurado nao bloqueou repeticao')

print('mz_prison P7.1 activities harness: PASS cases=11')
