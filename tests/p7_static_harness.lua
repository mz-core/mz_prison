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
expect(config:find('intakeEnabled = false', 1, true), 'intake foi ativado sem coordenadas')
expect(service:find('intake_point_required', 1, true), 'proximidade do intake nao e validada no servidor')
expect(config:find('sentenceRulesEnabled = false', 1, true), 'penas foram ativadas sem aprovacao')
expect(config:find('sentenceRules = {}', 1, true) and config:find('jobs = {}', 1, true), 'valores legais foram inventados')
expect(prepare:find('mz_prison_sentences', 1, true) and prepare:find('mz_prison_property', 1, true), 'schema prisional incompleto')
expect(service:find("clockMode = MZPrisonConfig.clockMode", 1, true), 'clock server-side ausente')
expect(not service:find('request.duration', 1, true) and not service:find('request.durationSeconds', 1, true), 'duracao do client foi aceita')
expect(exportsSource:find("GetInvokingResource() == 'mz_police'", 1, true), 'caller policial nao esta allowlisted')
expect(not service:find('RegisterNetEvent', 1, true), 'mutacao prisional exposta diretamente ao client')

print('mz_prison P7 static harness: PASS cases=11')
