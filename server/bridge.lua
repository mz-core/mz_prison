MZPrison = MZPrison or {}

local Bridge = {}

local function call(resource, exportName, ...)
  if GetResourceState(resource) ~= 'started' then return nil, resource .. '_unavailable' end
  local proxy, args = exports[resource], table.pack(...)
  local fn = proxy and proxy[exportName]
  if type(fn) ~= 'function' then return nil, 'contract_unavailable' end
  local result = table.pack(pcall(function() return fn(proxy, table.unpack(args, 1, args.n)) end))
  if result[1] ~= true then return nil, 'contract_failed' end
  return table.unpack(result, 2, result.n)
end

function Bridge.resolveIdentity(source)
  local result, callError = call('mz_core', 'ResolvePlayerIdentity', source)
  if type(result) ~= 'table' or result.ok ~= true then
    return nil, type(result) == 'table' and tostring(result.error or 'identity_unavailable')
      or callError or 'identity_unavailable'
  end
  local identity = {
    source = tonumber(result.source), sessionId = tonumber(result.sessionId or result.session_id),
    characterId = tonumber(result.characterId or result.character_id),
    citizenid = tostring(result.citizenid or ''), active = result.active == true
  }
  if identity.source ~= tonumber(source) or not identity.sessionId or not identity.characterId
    or identity.citizenid == '' or identity.active ~= true then return nil, 'identity_inconsistent' end
  return identity
end

function Bridge.getCharacter(citizenid)
  local result, callError = call('mz_core', 'GetCharacterByCitizenId', citizenid)
  if type(result) ~= 'table' then return nil, callError or 'citizen_not_found' end
  return result
end

function Bridge.getSource(citizenid)
  local result, callError = call('mz_core', 'GetSourceByCitizenId', citizenid)
  result = tonumber(result)
  if not result or result <= 0 then return nil, callError or 'target_offline' end
  return result
end

function Bridge.retainProperty(targetSource, sentenceId)
  local ok, value = call('mz_inventory', 'RetainPrisonerProperty', targetSource, sentenceId)
  if ok ~= true then return nil, tostring(value or 'property_retain_failed') end
  return value
end

function Bridge.getProperty(targetSource, sentenceId)
  local ok, value = call('mz_inventory', 'GetPrisonerProperty', targetSource, sentenceId)
  if ok ~= true then return nil, tostring(value or 'property_read_failed') end
  return value
end

function Bridge.restoreProperty(targetSource, sentenceId)
  local ok, value = call('mz_inventory', 'RestorePrisonerProperty', targetSource, sentenceId)
  if ok ~= true then return nil, tostring(value or 'property_restore_failed') end
  return value
end

function Bridge.audit(action, actor, sentence, fields)
  fields = type(fields) == 'table' and fields or {}
  return call('mz_core', 'CreateDetailedLog', 'prison', ('prison.%s'):format(action), {
    actor = actor and { type = 'character', id = actor.citizenid, citizenid = actor.citizenid }
      or { type = 'system', id = 'mz_prison' },
    target = sentence and {
      type = 'character', id = sentence.target_citizenid or sentence.targetCitizenid,
      citizenid = sentence.target_citizenid or sentence.targetCitizenid
    } or nil,
    context = {
      sentenceId = sentence and (sentence.public_id or sentence.publicId),
      caseId = sentence and (sentence.case_public_id or sentence.caseId),
      operationId = fields.operationId
    },
    meta = { result = fields.result, reason = fields.reason, status = fields.status }
  })
end

MZPrison.Bridge = Bridge
