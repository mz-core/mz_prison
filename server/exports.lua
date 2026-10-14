local function policeCaller()
  return type(GetInvokingResource) == 'function' and GetInvokingResource() == 'mz_police'
end

exports('RequestSentence', function(actorSource, targetSource, request)
  if not policeCaller() then return false, 'forbidden_caller' end
  return MZPrison.Service.requestSentence(actorSource, targetSource, request)
end)

exports('GetSentence', function(citizenid)
  if not policeCaller() then return false, 'forbidden_caller' end
  return MZPrison.Service.getSentence(citizenid)
end)

exports('ReduceSentence', function(actorSource, citizenid, request)
  if not policeCaller() then return false, 'forbidden_caller' end
  return MZPrison.Service.reduceSentence(actorSource, citizenid, request)
end)

exports('ReleasePrisoner', function(actorSource, citizenid, request)
  if not policeCaller() then return false, 'forbidden_caller' end
  return MZPrison.Service.releasePrisoner(actorSource, citizenid, request)
end)
