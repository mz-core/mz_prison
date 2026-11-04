local function expect(condition, message)
  if not condition then error('[p7_prepare_harness] ' .. message, 2) end
end

local logs = {}
local function resetLogs() logs = {} end
local function contains(needle)
  for _, line in ipairs(logs) do
    if tostring(line):find(needle, 1, true) then return true end
  end
  return false
end

print = function(...)
  local parts = {}
  for index = 1, select('#', ...) do parts[#parts + 1] = tostring(select(index, ...)) end
  logs[#logs + 1] = table.concat(parts, ' ')
end

MZPrison = {}
MZPrisonConfig = { tickSeconds = 30 }

local function splitTopLevel(body)
  local parts, current, depth = {}, {}, 0
  for index = 1, #body do
    local char = body:sub(index, index)
    if char == '(' then
      depth = depth + 1
      current[#current + 1] = char
    elseif char == ')' then
      depth = depth - 1
      current[#current + 1] = char
    elseif char == ',' and depth == 0 then
      parts[#parts + 1] = table.concat(current)
      current = {}
    else
      current[#current + 1] = char
    end
  end
  if #current > 0 then parts[#parts + 1] = table.concat(current) end
  return parts
end

local function columnsList(value)
  local out = {}
  for item in tostring(value or ''):gmatch('[^,%s]+') do out[#out + 1] = item end
  return out
end

local function parseCreate(statement)
  local name = statement:match('CREATE%s+TABLE%s+IF%s+NOT%s+EXISTS%s+([%w_]+)')
  if not name then return nil end
  local body = statement:match('%((.*)%)%s*ENGINE')
  if not body then return nil end
  local model = { columns = {}, primary = {}, unique = {}, foreign = {} }
  for _, raw in ipairs(splitTopLevel(body)) do
    local part = raw:gsub('^%s+', ''):gsub('%s+$', '')
    local uniqueName, uniqueColumns = part:match('^UNIQUE%s+KEY%s+([%w_]+)%s*%(([^)]*)%)')
    if uniqueName then
      model.unique[#model.unique + 1] = table.concat(columnsList(uniqueColumns), ',')
    else
      local constraint, column, refTable, refColumn = part:match(
        '^CONSTRAINT%s+([%w_]+)%s+FOREIGN%s+KEY%s*%(([%w_]+)%)%s+REFERENCES%s+([%w_]+)%s*%(([%w_]+)%)')
      if constraint then
        model.foreign[#model.foreign + 1] = {
          column = column, refTable = refTable, refColumn = refColumn
        }
      elseif part:match('^PRIMARY%s+KEY') then
        model.primary = columnsList(part:match('%(([^)]*)%)'))
      elseif not part:match('^KEY%s+') then
        local columnName, columnType = part:match('^([%w_]+)%s+([%a]+)')
        if columnName then
          model.columns[columnName] = {
            dataType = columnType:lower(),
            length = tonumber(part:match('VARCHAR%s*%((%d+)%)'))
              or tonumber(part:match('CHAR%s*%((%d+)%)')) or 0,
            nullable = not part:match('%f[%a]NOT%s+NULL%f[%A]'),
            hasDefault = part:match('%f[%a]DEFAULT%f[%A]') ~= nil,
            extra = part:find('AUTO_INCREMENT', 1, true) and 'auto_increment' or ''
          }
          if part:match('%f[%a]PRIMARY%s+KEY%f[%A]') then
            model.primary[#model.primary + 1] = columnName
          end
        end
      end
    end
  end
  return name, model
end

local function deepCopy(value)
  if type(value) ~= 'table' then return value end
  local out = {}
  for key, entry in pairs(value) do out[key] = deepCopy(entry) end
  return out
end

local db, created, createCount = {}, {}, 0
local failCreate, onCreateHook = {}, nil

local function resetDb()
  db, created, createCount = {}, {}, 0
  failCreate, onCreateHook = {}, nil
end

local function columnsRows()
  local rows = {}
  for tableName, model in pairs(db) do
    for columnName, column in pairs(model.columns) do
      rows[#rows + 1] = {
        TABLE_NAME = tableName,
        COLUMN_NAME = columnName,
        DATA_TYPE = column.dataType,
        COLUMN_TYPE = column.dataType,
        IS_NULLABLE = column.nullable and 'YES' or 'NO',
        CHARACTER_MAXIMUM_LENGTH = column.length > 0 and column.length or nil,
        COLUMN_DEFAULT = column.hasDefault and 'default' or nil,
        EXTRA = column.extra or ''
      }
    end
  end
  return rows
end

local function indexRows()
  local rows = {}
  for tableName, model in pairs(db) do
    for position, columnName in ipairs(model.primary) do
      rows[#rows + 1] = {
        TABLE_NAME = tableName, INDEX_NAME = 'PRIMARY', NON_UNIQUE = 0,
        SEQ_IN_INDEX = position, COLUMN_NAME = columnName
      }
    end
    for index, csv in ipairs(model.unique) do
      local position = 0
      for columnName in tostring(csv):gmatch('[^,]+') do
        position = position + 1
        rows[#rows + 1] = {
          TABLE_NAME = tableName, INDEX_NAME = ('uq_%d'):format(index), NON_UNIQUE = 0,
          SEQ_IN_INDEX = position, COLUMN_NAME = columnName
        }
      end
    end
  end
  return rows
end

local function foreignRows()
  local rows = {}
  for tableName, model in pairs(db) do
    for index, fk in ipairs(model.foreign) do
      rows[#rows + 1] = {
        TABLE_NAME = tableName, CONSTRAINT_NAME = ('fk_%d'):format(index),
        COLUMN_NAME = fk.column,
        REFERENCED_TABLE_NAME = fk.refTable,
        REFERENCED_COLUMN_NAME = fk.refColumn
      }
    end
  end
  return rows
end

MySQL = {
  query = {
    await = function(sql)
      local text = tostring(sql or '')
      local upper = text:upper()
      if upper:match('^%s*SELECT 1 AS OK') then return { { ok = 1 } } end
      if upper:match('^%s*CREATE TABLE IF NOT EXISTS') then
        createCount = createCount + 1
        local name, model = parseCreate(text)
        expect(name ~= nil and model ~= nil, 'CREATE invalido: ' .. text:sub(1, 60))
        if onCreateHook then onCreateHook(name) end
        if failCreate[name] then
          error('CREATE command denied to user for table ' .. name, 0)
        end
        if db[name] then return {} end
        db[name] = model
        created[#created + 1] = name
        return {}
      end
      if upper:find('INFORMATION_SCHEMA.COLUMNS', 1, true) then return columnsRows() end
      if upper:find('INFORMATION_SCHEMA.STATISTICS', 1, true) then return indexRows() end
      if upper:find('INFORMATION_SCHEMA.KEY_COLUMN_USAGE', 1, true) then return foreignRows() end
      error('unexpected query: ' .. text:sub(1, 80), 0)
    end
  },
  single = { await = function() return nil end },
  update = { await = function() return 1 end },
  transaction = { await = function() return true end }
}

assert(loadfile('server/prepare.lua'))()
local Prepare = MZPrison.Prepare
local canonical

-- 1) MySQL indisponivel falha fechado.
local saved = MySQL
MySQL = nil
Prepare.ready, Prepare.state = false, 'idle'
local noMysqlOk, noMysqlError = Prepare.run()
expect(noMysqlOk == false and noMysqlError == 'mysql_not_ready', 'mysql indisponivel nao falhou fechado')
MySQL = saved

-- 2) banco vazio: cria as 6 tabelas e valida.
resetDb(); resetLogs()
Prepare.ready, Prepare.state = false, 'idle'
local createOk, createError = Prepare.run()
expect(createOk == true and Prepare.ready == true, 'banco vazio nao inicializou: ' .. tostring(createError))
expect(#created == 6, 'quantidade de tabelas prisionais criadas != 6')
expect(created[1] == 'mz_prison_sentences'
  and created[2] == 'mz_prison_sentence_charges'
  and created[6] == 'mz_prison_release_deliveries',
  'ordem/nomes das tabelas criadas divergiu do DDL canonico')
expect(contains('schema initialization started') and contains('schema validated'),
  'logs de inicializacao/validacao ausentes')
canonical = deepCopy(db)

-- 3) restart/reutilizacao: nao executa DDL e preserva registros.
db.mz_prison_sentences.rows = 1
local createCountBefore = createCount
Prepare.ready, Prepare.state = false, 'idle'
local reuseOk = Prepare.run()
expect(reuseOk == true, 'restart nao reutilizou o schema')
expect(createCount == createCountBefore, 'DDL executado em schema saudavel')
expect(db.mz_prison_sentences.rows == 1, 'registros existentes foram perdidos')

-- 4) schema legado sem charge_public_id falha com o codigo canonico.
db = deepCopy(canonical); created = {}; createCount = 0; resetLogs()
db.mz_prison_sentences.columns.charge_public_id = nil
Prepare.ready, Prepare.state = false, 'idle'
local legacyOk, legacyError = Prepare.run()
expect(legacyOk == false and legacyError == 'schema_outdated_missing_charge_public_id',
  'schema legado sem charge_public_id nao falhou fechado')

-- 5) UNIQUE obrigatorio ausente falha fechado.
db = deepCopy(canonical); created = {}; createCount = 0; resetLogs()
db.mz_prison_sentences.unique = {}
Prepare.ready, Prepare.state = false, 'idle'
local uniqueOk, uniqueError = Prepare.run()
expect(uniqueOk == false
  and tostring(uniqueError):find('mz_prison_sentences:unique(operation_id)', 1, true) ~= nil,
  'unique ausente nao falhou fechado')

-- 6) foreign key obrigatoria ausente falha fechado.
db = deepCopy(canonical); created = {}; createCount = 0; resetLogs()
db.mz_prison_property.foreign = {}
Prepare.ready, Prepare.state = false, 'idle'
local fkOk, fkError = Prepare.run()
expect(fkOk == false and tostring(fkError):find(
  'mz_prison_property:fk(sentence_public_id->mz_prison_sentences.public_id)', 1, true) ~= nil,
  'foreign key ausente nao falhou fechado')

-- 7) permissao CREATE negada + falha parcial + retry.
resetDb(); resetLogs()
failCreate.mz_prison_property = true
Prepare.ready, Prepare.state = false, 'idle'
local deniedOk, deniedError = Prepare.bootstrap()
expect(deniedOk == false and tostring(deniedError):find('create_failed:mz_prison_property', 1, true) ~= nil,
  'falha de CREATE nao identificou a tabela')
expect(tostring(deniedError):find('CREATE command denied', 1, true) ~= nil
  and tostring(deniedError):find('required: CREATE', 1, true) ~= nil,
  'falha de permissao nao indicou a permissao necessaria')
expect(db.mz_prison_sentences ~= nil and db.mz_prison_property == nil, 'estado de falha parcial inesperado')
expect(contains('schema initialization failed') and contains('schema_ready=false'),
  'logs de falha ausentes')

failCreate.mz_prison_property = false
Prepare.ready, Prepare.state = false, 'idle'
local retryOk, retryError = Prepare.run()
expect(retryOk == true and db.mz_prison_property ~= nil and db.mz_prison_release_deliveries ~= nil,
  'retry apos falha parcial nao concluiu: ' .. tostring(retryError))
local sentencesCreated = 0
for _, name in ipairs(created) do if name == 'mz_prison_sentences' then sentencesCreated = sentencesCreated + 1 end end
expect(sentencesCreated == 1, 'tabela existente foi recriada apos falha parcial')

-- 8) inicializacao simultanea e bloqueada.
resetDb(); resetLogs()
local reentrant
onCreateHook = function(name)
  if name == 'mz_prison_sentences' then reentrant = { Prepare.run() } end
end
Prepare.ready, Prepare.state = false, 'idle'
local concurrentOk = Prepare.run()
onCreateHook = nil
expect(concurrentOk == true, 'inicializacao principal falhou no teste de concorrencia')
expect(reentrant ~= nil and reentrant[1] == false
  and reentrant[2] == 'initialization_in_progress',
  'inicializacao simultanea nao foi bloqueada')

-- 9) bootstrap feliz emite os logs esperados.
resetDb(); resetLogs()
Prepare.ready, Prepare.state = false, 'idle'
Prepare.bootstrap()
expect(contains('database connection ready'), 'log database connection ready ausente')
expect(contains('schema initialization started'), 'log schema initialization started ausente')
expect(contains('schema validated'), 'log schema validated ausente')
expect(contains('schema_ready=true'), 'log final schema_ready=true ausente')

-- 10) servico prisional recusa operacoes antes do schema pronto.
Prepare.ready, Prepare.state = false, 'failed'
assert(loadfile('server/service.lua'))()
local serviceOk, serviceError = MZPrison.Service.getSentence('TARGET1')
expect(serviceOk == false and serviceError == 'prison_unavailable',
  'servico prisional aceitou leitura antes do schema pronto')

io.write('[p7_prepare_harness] PASS cases=10\n')
