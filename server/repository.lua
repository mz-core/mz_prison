MZPrison = MZPrison or {}

local Repository = {}

local function encode(value)
  local ok, result = pcall(json.encode, value or {})
  return ok and result or '{}'
end

local function history(data)
  return {
    query = [[INSERT INTO mz_prison_history
      (operation_id, request_fingerprint, sentence_public_id, action, actor_citizenid, details_json)
      VALUES (?, ?, ?, ?, ?, ?)]],
    parameters = {
      data.operationId, data.requestFingerprint, data.sentenceId,
      data.action, data.actorCitizenid, encode(data.details)
    }
  }
end

local function transaction(statements)
  local ok, value = pcall(function() return MySQL.transaction.await(statements) end)
  return ok == true and value == true
end

function Repository.getHistoryOperation(operationId)
  return MySQL.single.await('SELECT * FROM mz_prison_history WHERE operation_id = ? LIMIT 1', { operationId })
end

function Repository.getByOperation(operationId)
  return MySQL.single.await('SELECT * FROM mz_prison_sentences WHERE operation_id = ? LIMIT 1', { operationId })
end

function Repository.getById(publicId)
  return MySQL.single.await('SELECT * FROM mz_prison_sentences WHERE public_id = ? LIMIT 1', { publicId })
end

function Repository.getCurrent(citizenid)
  return MySQL.single.await([[SELECT * FROM mz_prison_sentences
    WHERE target_citizenid = ? AND status IN ('intake_pending', 'active', 'release_pending')
    ORDER BY created_at DESC LIMIT 1]], { citizenid })
end

function Repository.createSentence(data)
  return transaction({ {
    query = [[INSERT INTO mz_prison_sentences
      (public_id, operation_id, target_citizenid, case_public_id, charge_public_id, org_code, rule_code,
       rule_name, legal_version, duration_seconds, remaining_seconds, clock_mode,
       status, property_status, sentenced_by_citizenid)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'intake_pending', 'pending', ?)]],
    parameters = {
      data.publicId, data.operationId, data.targetCitizenid, data.caseId, data.chargeId, data.orgCode,
      data.ruleCode, data.ruleName, data.legalVersion, data.durationSeconds,
      data.durationSeconds, data.clockMode, data.actorCitizenid
    }
  }, history(data.history) })
end

function Repository.activateWithProperty(sentenceId, items, historyData)
  local statements = {}
  for _, item in ipairs(items or {}) do
    statements[#statements + 1] = {
      query = [[INSERT INTO mz_prison_property
        (sentence_public_id, retained_slot, instance_uid, item, amount,
         original_inventory_type, original_slot, status)
        VALUES (?, ?, ?, ?, ?, ?, ?, 'retained')
        ON DUPLICATE KEY UPDATE instance_uid = VALUES(instance_uid), item = VALUES(item),
          amount = VALUES(amount), original_inventory_type = VALUES(original_inventory_type),
          original_slot = VALUES(original_slot), status = 'retained']],
      parameters = {
        sentenceId, item.retainedSlot, item.instanceUid ~= '' and item.instanceUid or nil,
        item.item, item.amount, item.originalInventoryType, item.originalSlot
      }
    }
  end
  statements[#statements + 1] = {
    query = [[UPDATE mz_prison_sentences SET status = 'active', property_status = 'retained',
      last_error = NULL, started_at = COALESCE(started_at, CURRENT_TIMESTAMP)
      WHERE public_id = ? AND status = 'intake_pending']],
    parameters = { sentenceId }
  }
  statements[#statements + 1] = history(historyData)
  return transaction(statements)
end

function Repository.setError(sentenceId, errorCode)
  return (MySQL.update.await('UPDATE mz_prison_sentences SET last_error = ? WHERE public_id = ?', {
    tostring(errorCode or ''):sub(1, 64), sentenceId
  }) or 0) > 0
end

function Repository.reduce(sentence, seconds, historyData)
  local remaining = math.max(0, math.floor(tonumber(sentence.remaining_seconds) or 0) - seconds)
  local status = remaining == 0 and 'release_pending' or 'active'
  local ok = transaction({ {
    query = [[UPDATE mz_prison_sentences SET remaining_seconds = ?, status = ?, last_error = NULL
      WHERE public_id = ? AND status = 'active' AND remaining_seconds = ?]],
    parameters = { remaining, status, sentence.public_id, sentence.remaining_seconds }
  }, history(historyData) })
  return ok, remaining
end

function Repository.beginRelease(sentence, historyData)
  return transaction({ {
    query = [[UPDATE mz_prison_sentences SET status = 'release_pending', last_error = NULL
      WHERE public_id = ? AND status IN ('active', 'release_pending')]],
    parameters = { sentence.public_id }
  }, history(historyData) })
end

function Repository.finishRelease(sentenceId, historyData)
  return transaction({ {
    query = [[UPDATE mz_prison_property SET status = 'restored'
      WHERE sentence_public_id = ? AND status = 'retained']],
    parameters = { sentenceId }
  }, {
    query = [[UPDATE mz_prison_sentences SET status = 'released', property_status = 'restored',
      remaining_seconds = 0, last_error = NULL, released_at = CURRENT_TIMESTAMP
      WHERE public_id = ? AND status = 'release_pending']],
    parameters = { sentenceId }
  }, history(historyData) })
end

function Repository.tick(sentenceId, seconds)
  MySQL.update.await([[UPDATE mz_prison_sentences
    SET status = IF(remaining_seconds <= ?, 'release_pending', status),
      remaining_seconds = GREATEST(0, remaining_seconds - ?)
    WHERE public_id = ? AND status = 'active']], { seconds, seconds, sentenceId })
  return Repository.getById(sentenceId)
end

function Repository.listPending()
  return MySQL.query.await([[SELECT * FROM mz_prison_sentences
    WHERE status IN ('active', 'release_pending') ORDER BY updated_at ASC]]) or {}
end

function Repository.listProperty(sentenceId)
  return MySQL.query.await([[SELECT retained_slot, instance_uid, item, amount,
    original_inventory_type, original_slot, status FROM mz_prison_property
    WHERE sentence_public_id = ? ORDER BY retained_slot ASC]], { sentenceId }) or {}
end

MZPrison.Repository = Repository
