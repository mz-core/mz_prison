local function read(path)
  local file = assert(io.open(path, 'rb'))
  local value = file:read('*a')
  file:close()
  return value
end
local function expect(condition, message) if not condition then error(message, 2) end end

local manifest, config = read('fxmanifest.lua'), read('config.lua')
local prepare, service, exportsSource = read('server/prepare.lua'), read('server/service.lua'), read('server/exports.lua')

expect(manifest:find("name 'mz_prison'", 1, true), 'resource prisional ausente')
expect(manifest:find("'mz_core'", 1, true) and manifest:find("'mz_inventory'", 1, true), 'owners obrigatorios ausentes')
expect(config:find('intakeEnabled = false', 1, true) and config:find('facilities = {', 1, true)
  and config:find('bolingbroke', 1, true), 'facility de staging ausente')
expect(config:find('confinement = {', 1, true) and service:find('dispatchConfinement', 1, true),
  'confinamento server-side ausente')
expect(service:find('intake_point_required', 1, true), 'proximidade do intake nao e validada no servidor')
expect(config:find('sentenceRulesEnabled = true', 1, true)
  and config:find("legalVersion = 'MZ-RP-STAGING-2'", 1, true)
  and config:find('HOMICIDIO_DOLOSO', 1, true), 'catalogo prisional de staging ausente')
expect(config:find('cells = {', 1, true) and config:find('allowedAreas = {', 1, true),
  'cela/area permitida de staging ausente')
expect(config:find('jobsEnabled = true', 1, true) and config:find('activityRateLimit = { maximum = 6', 1, true)
  and config:find('bolingbroke_yard', 1, true), 'atividade de staging ausente')
local releaseStart = config:find('releasePoints = {', 1, true)
expect(releaseStart ~= nil and config:find('enabled = true', releaseStart, true) ~= nil,
  'destino de soltura de staging ausente')
expect(prepare:find('mz_prison_sentences', 1, true) and prepare:find('mz_prison_property', 1, true), 'schema prisional incompleto')
expect(prepare:find('mz_prison_activities', 1, true) and prepare:find('mz_prison_release_deliveries', 1, true),
  'persistencia de atividades/soltura incompleta')
expect(prepare:find('charge_public_id VARCHAR(160) NOT NULL', 1, true), 'schema nao persiste identificador canonico da acusacao P6')
expect(prepare:find('confinement_status VARCHAR(24)', 1, true), 'schema nao persiste estado do confinamento')
expect(prepare:find('schema_outdated_missing_charge_public_id', 1, true), 'schema legado nao falha fechado')
expect(service:find("clockMode = MZPrisonConfig.clockMode", 1, true), 'clock server-side ausente')
expect(not service:find('request.duration', 1, true) and not service:find('request.durationSeconds', 1, true), 'duracao do client foi aceita')
expect(service:find("return false, 'sentence_rule_mismatch'", 1, true), 'snapshot legal P6 nao e confrontado com a configuracao P7')
expect(exportsSource:find("GetInvokingResource() == 'mz_police'", 1, true), 'caller policial nao esta allowlisted')
expect(not service:find('RegisterNetEvent', 1, true), 'mutacao prisional exposta diretamente ao client')
expect(manifest:find("'client/status.lua'", 1, true), 'hud de status prisional ausente')
expect(service:find('mz_prison:client:sentence', 1, true), 'evento de status prisional ausente')

print('mz_prison P7 static harness: PASS cases=18')
