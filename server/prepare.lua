MZPrison = MZPrison or {}

-- Preparacao do schema prisional (P7).
--
-- Fonte unica de DDL: a lista `statements` abaixo. Este arquivo nao duplica o
-- schema em SQL: o MESMO DDL e usado para criar e para derivar o contrato de
-- validacao comparado com information_schema.
--
-- Garantias:
--  - apenas CREATE TABLE IF NOT EXISTS (nunca DROP/DELETE/TRUNCATE/ALTER);
--  - banco saudavel nao recebe DDL: valida primeiro e reutiliza;
--  - valida colunas, tipos, tamanhos, nulabilidade, PK, UNIQUE e FKs;
--  - estrutura incompativel falha fechado, sem "consertar" automaticamente;
--  - o servico prisional so roda com Prepare.ready == true.

local Prepare = {
  ready = false,
  state = 'idle',
  error = nil
}

local statements = {
  [[CREATE TABLE IF NOT EXISTS mz_prison_sentences (
    public_id VARCHAR(96) NOT NULL PRIMARY KEY,
    operation_id VARCHAR(64) NOT NULL,
    target_citizenid VARCHAR(64) NOT NULL,
    case_public_id VARCHAR(160) NOT NULL,
    charge_public_id VARCHAR(160) NOT NULL,
    org_code VARCHAR(64) NOT NULL,
    rule_code VARCHAR(64) NOT NULL,
    rule_name VARCHAR(160) NOT NULL,
    legal_version VARCHAR(64) NOT NULL,
    duration_seconds INT UNSIGNED NOT NULL,
    remaining_seconds INT UNSIGNED NOT NULL,
    clock_mode VARCHAR(16) NOT NULL,
    status VARCHAR(24) NOT NULL DEFAULT 'intake_pending',
    property_status VARCHAR(24) NOT NULL DEFAULT 'pending',
    facility_id VARCHAR(64) NULL,
    intake_point_id VARCHAR(64) NULL,
    cell_id VARCHAR(64) NULL,
    previous_routing_bucket INT UNSIGNED NOT NULL DEFAULT 0,
    confinement_status VARCHAR(24) NOT NULL DEFAULT 'not_applicable',
    sentenced_by_citizenid VARCHAR(64) NOT NULL,
    last_error VARCHAR(64) NULL,
    started_at TIMESTAMP NULL,
    released_at TIMESTAMP NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_mz_prison_sentences_operation (operation_id),
    KEY idx_mz_prison_sentences_target_status (target_citizenid, status)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
  [[CREATE TABLE IF NOT EXISTS mz_prison_sentence_charges (
    sentence_public_id VARCHAR(96) NOT NULL,
    charge_public_id VARCHAR(160) NOT NULL,
    rule_code VARCHAR(64) NOT NULL,
    rule_name VARCHAR(160) NOT NULL,
    legal_version VARCHAR(64) NOT NULL,
    sentence_seconds INT UNSIGNED NOT NULL,
    is_primary TINYINT UNSIGNED NOT NULL DEFAULT 0,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (sentence_public_id, charge_public_id),
    UNIQUE KEY uq_mz_prison_sentence_charge (charge_public_id),
    CONSTRAINT fk_mz_prison_sentence_charge_sentence FOREIGN KEY (sentence_public_id)
      REFERENCES mz_prison_sentences(public_id) ON DELETE RESTRICT
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
  [[CREATE TABLE IF NOT EXISTS mz_prison_property (
    sentence_public_id VARCHAR(96) NOT NULL,
    retained_slot INT UNSIGNED NOT NULL,
    instance_uid VARCHAR(64) NULL,
    item VARCHAR(64) NOT NULL,
    amount INT UNSIGNED NOT NULL,
    original_inventory_type VARCHAR(32) NOT NULL,
    original_slot INT UNSIGNED NULL,
    status VARCHAR(24) NOT NULL DEFAULT 'retained',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (sentence_public_id, retained_slot),
    KEY idx_mz_prison_property_uid (instance_uid),
    CONSTRAINT fk_mz_prison_property_sentence FOREIGN KEY (sentence_public_id)
      REFERENCES mz_prison_sentences(public_id) ON DELETE RESTRICT
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
  [[CREATE TABLE IF NOT EXISTS mz_prison_history (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    operation_id VARCHAR(160) NOT NULL,
    request_fingerprint VARCHAR(64) NOT NULL,
    sentence_public_id VARCHAR(96) NOT NULL,
    action VARCHAR(64) NOT NULL,
    actor_citizenid VARCHAR(64) NULL,
    details_json LONGTEXT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_mz_prison_history_operation (operation_id),
    KEY idx_mz_prison_history_sentence (sentence_public_id, id),
    CONSTRAINT fk_mz_prison_history_sentence FOREIGN KEY (sentence_public_id)
      REFERENCES mz_prison_sentences(public_id) ON DELETE RESTRICT
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
  [[CREATE TABLE IF NOT EXISTS mz_prison_activities (
    public_id VARCHAR(96) NOT NULL PRIMARY KEY,
    operation_id VARCHAR(160) NOT NULL,
    sentence_public_id VARCHAR(96) NOT NULL,
    target_citizenid VARCHAR(64) NOT NULL,
    job_code VARCHAR(64) NOT NULL,
    point_id VARCHAR(64) NOT NULL,
    duration_seconds INT UNSIGNED NOT NULL,
    reduction_seconds INT UNSIGNED NOT NULL,
    status VARCHAR(24) NOT NULL DEFAULT 'in_progress',
    started_session_id BIGINT UNSIGNED NOT NULL,
    available_at TIMESTAMP NOT NULL,
    completed_at TIMESTAMP NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_mz_prison_activities_operation (operation_id),
    KEY idx_mz_prison_activities_sentence (sentence_public_id, status, created_at),
    CONSTRAINT fk_mz_prison_activities_sentence FOREIGN KEY (sentence_public_id)
      REFERENCES mz_prison_sentences(public_id) ON DELETE RESTRICT
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
  [[CREATE TABLE IF NOT EXISTS mz_prison_release_deliveries (
    sentence_public_id VARCHAR(96) NOT NULL PRIMARY KEY,
    destination_id VARCHAR(64) NOT NULL,
    target_citizenid VARCHAR(64) NOT NULL,
    status VARCHAR(24) NOT NULL DEFAULT 'pending',
    delivered_session_id BIGINT UNSIGNED NULL,
    delivered_at TIMESTAMP NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    KEY idx_mz_prison_release_delivery_target (target_citizenid, status),
    CONSTRAINT fk_mz_prison_release_delivery_sentence FOREIGN KEY (sentence_public_id)
      REFERENCES mz_prison_sentences(public_id) ON DELETE RESTRICT
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]]
}

local WAIT_ATTEMPTS = 120
local WAIT_INTERVAL_MS = 500
local LEGACY_CHARGE_COLUMN = 'mz_prison_sentences.charge_public_id:missing'

local function trim(value)
  return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function sanitize(value)
  local message = tostring(value or ''):gsub('[\r\n]+', ' ')
  if #message > 320 then message = message:sub(1, 320) .. '...' end
  return message
end

local function log(message)
  print(('[mz_prison] %s'):format(tostring(message)))
end

local function mysqlReady()
  return MySQL and MySQL.query and type(MySQL.query.await) == 'function'
    and MySQL.single and type(MySQL.single.await) == 'function'
    and MySQL.update and type(MySQL.update.await) == 'function'
    and MySQL.transaction and type(MySQL.transaction.await) == 'function'
end

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
  if not name then return nil, 'create_prefix' end
  local body = statement:match('%((.*)%)%s*ENGINE')
  if not body then return nil, 'create_body' end
  local model = { columns = {}, primary = {}, unique = {}, foreign = {} }
  for _, raw in ipairs(splitTopLevel(body)) do
    local part = trim(raw)
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
          local length = tonumber(part:match('VARCHAR%s*%((%d+)%)'))
            or tonumber(part:match('CHAR%s*%((%d+)%)')) or 0
          model.columns[columnName] = {
            dataType = columnType:lower(),
            length = length,
            nullable = not part:match('%f[%a]NOT%s+NULL%f[%A]')
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

local function fetchActual(names)
  local marks = {}
  for index = 1, #names do marks[index] = '?' end
  local clause = table.concat(marks, ',')
  local actual = { columns = {}, primary = {}, unique = {}, foreign = {} }

  local columnRows = MySQL.query.await(([[SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, COLUMN_TYPE,
    IS_NULLABLE, CHARACTER_MAXIMUM_LENGTH, COLUMN_DEFAULT, EXTRA
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN (%s)]]):format(clause), names) or {}
  for _, row in ipairs(columnRows) do
    local tableName = tostring(row.TABLE_NAME or row.table_name or '')
    local columnName = tostring(row.COLUMN_NAME or row.column_name or '')
    if tableName ~= '' and columnName ~= '' then
      actual.columns[tableName] = actual.columns[tableName] or {}
      local defaultValue = row.COLUMN_DEFAULT
      actual.columns[tableName][columnName] = {
        dataType = tostring(row.DATA_TYPE or row.data_type or ''):lower(),
        length = tonumber(row.CHARACTER_MAXIMUM_LENGTH or row.character_maximum_length) or 0,
        nullable = tostring(row.IS_NULLABLE or row.is_nullable or ''):upper() == 'YES',
        hasDefault = defaultValue ~= nil and tostring(defaultValue):lower() ~= 'null',
        extra = tostring(row.EXTRA or row.extra or ''):lower()
      }
    end
  end

  local indexRows = MySQL.query.await(([[SELECT TABLE_NAME, INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME
    FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN (%s)
    ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX]]):format(clause), names) or {}
  local grouped, nonUniqueByIndex = {}, {}
  for _, row in ipairs(indexRows) do
    local tableName = tostring(row.TABLE_NAME or row.table_name or '')
    local indexName = tostring(row.INDEX_NAME or row.index_name or '')
    local columnName = tostring(row.COLUMN_NAME or row.column_name or '')
    local position = tonumber(row.SEQ_IN_INDEX or row.seq_in_index)
    if tableName ~= '' and indexName ~= '' and columnName ~= '' and position then
      grouped[tableName] = grouped[tableName] or {}
      grouped[tableName][indexName] = grouped[tableName][indexName] or {}
      grouped[tableName][indexName][position] = columnName
      nonUniqueByIndex[tableName] = nonUniqueByIndex[tableName] or {}
      nonUniqueByIndex[tableName][indexName] = tonumber(row.NON_UNIQUE or row.non_unique)
    end
  end
  for tableName, indexes in pairs(grouped) do
    actual.primary[tableName] = {}
    actual.unique[tableName] = {}
    for indexName, byPosition in pairs(indexes) do
      local ordered = {}
      for position = 1, #byPosition do ordered[#ordered + 1] = byPosition[position] end
      local csv = table.concat(ordered, ',')
      if indexName == 'PRIMARY' then
        actual.primary[tableName] = ordered
      elseif tonumber(nonUniqueByIndex[tableName] and nonUniqueByIndex[tableName][indexName]) == 0 then
        actual.unique[tableName][csv] = true
      end
    end
  end

  local foreignRows = MySQL.query.await(([[SELECT TABLE_NAME, COLUMN_NAME,
    REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
    FROM information_schema.KEY_COLUMN_USAGE
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN (%s)
      AND REFERENCED_TABLE_NAME IS NOT NULL]]):format(clause), names) or {}
  for _, row in ipairs(foreignRows) do
    local tableName = tostring(row.TABLE_NAME or row.table_name or '')
    local columnName = tostring(row.COLUMN_NAME or row.column_name or '')
    if tableName ~= '' and columnName ~= '' then
      actual.foreign[tableName] = actual.foreign[tableName] or {}
      actual.foreign[tableName][columnName] = {
        refTable = tostring(row.REFERENCED_TABLE_NAME or row.referenced_table_name or ''),
        refColumn = tostring(row.REFERENCED_COLUMN_NAME or row.referenced_column_name or '')
      }
    end
  end

  return actual
end

local function validate(expected, actual)
  local problems = {}
  for tableName, model in pairs(expected) do
    local columns = actual.columns[tableName]
    if not columns or next(columns) == nil then
      problems[#problems + 1] = ('%s:missing'):format(tableName)
    else
      for columnName, spec in pairs(model.columns) do
        local column = columns[columnName]
        if not column then
          problems[#problems + 1] = ('%s.%s:missing'):format(tableName, columnName)
        else
          if column.dataType ~= spec.dataType then
            problems[#problems + 1] = ('%s.%s:type=%s~=%s'):format(
              tableName, columnName, column.dataType, spec.dataType)
          end
          if spec.length > 0 and column.length < spec.length then
            problems[#problems + 1] = ('%s.%s:length=%d<%d'):format(
              tableName, columnName, column.length, spec.length)
          end
          if column.nullable ~= spec.nullable then
            problems[#problems + 1] = ('%s.%s:nullable=%s'):format(
              tableName, columnName, tostring(column.nullable))
          end
        end
      end
      for columnName, column in pairs(columns) do
        if not model.columns[columnName] then
          local autoIncrement = column.extra:find('auto_increment', 1, true) ~= nil
          if not column.nullable and not column.hasDefault and not autoIncrement then
            problems[#problems + 1] = ('%s.%s:unexpected_required'):format(tableName, columnName)
          end
        end
      end
      local expectedPrimary = model.primary
      local actualPrimary = actual.primary[tableName] or {}
      if #expectedPrimary > 0
        and table.concat(expectedPrimary, ',') ~= table.concat(actualPrimary, ',') then
        problems[#problems + 1] = ('%s:primary(%s)'):format(
          tableName, table.concat(expectedPrimary, ','))
      end
      local uniqueSets = actual.unique[tableName] or {}
      for _, csv in ipairs(model.unique) do
        if uniqueSets[csv] ~= true then
          problems[#problems + 1] = ('%s:unique(%s)'):format(tableName, csv)
        end
      end
      local foreignColumns = actual.foreign[tableName] or {}
      for _, fk in ipairs(model.foreign) do
        local found = foreignColumns[fk.column]
        if not found or found.refTable ~= fk.refTable or found.refColumn ~= fk.refColumn then
          problems[#problems + 1] = ('%s:fk(%s->%s.%s)'):format(
            tableName, fk.column, fk.refTable, fk.refColumn)
        end
      end
    end
  end
  return #problems == 0, problems
end

local function expectedSchema()
  local expected, names = {}, {}
  for _, statement in ipairs(statements) do
    local name, model = parseCreate(statement)
    if not name then return nil, nil, 'ddl_parse_failed:' .. tostring(model) end
    expected[name] = model
    names[#names + 1] = name
  end
  return expected, names
end

local function validateSafe(expected, names)
  local ok, valid, problems = pcall(function() return validate(expected, fetchActual(names)) end)
  if ok ~= true then return false, { fatal = true, error = sanitize(valid) } end
  return valid, problems
end

local function schemaFailure(problems)
  local detail
  if type(problems) == 'table' and problems.fatal then
    detail = problems.error
  else
    detail = table.concat(problems or {}, ',')
  end
  if tostring(detail):find(LEGACY_CHARGE_COLUMN, 1, true) then
    return 'schema_outdated_missing_charge_public_id'
  end
  return 'schema_invalid:' .. sanitize(detail)
end

local function createTables()
  for index, statement in ipairs(statements) do
    if not trim(statement):upper():match('^CREATE TABLE IF NOT EXISTS ') then
      return false, ('unsafe_statement:%d'):format(index)
    end
    local ok, err = pcall(function() MySQL.query.await(statement) end)
    if ok ~= true then
      local tableName = statement:match('CREATE%s+TABLE%s+IF%s+NOT%s+EXISTS%s+([%w_]+)')
        or ('statement_%d'):format(index)
      local message = sanitize(err)
      local hint = ''
      local lower = message:lower()
      if lower:find('denied', 1, true) or lower:find('permission', 1, true) then
        hint = ' | required: CREATE and REFERENCES on the server database'
      end
      return false, ('create_failed:%s:%s%s'):format(tableName, message, hint)
    end
  end
  return true
end

local function prepareSchema()
  log('schema initialization started')
  local expected, names, parseError = expectedSchema()
  if not expected then return false, parseError end

  local valid, problems = validateSafe(expected, names)
  if valid == true then
    log('schema validated')
    return true
  end
  if type(problems) == 'table' and problems.fatal then
    return false, 'validation_failed:' .. sanitize(problems.error)
  end

  local created, createError = createTables()
  if not created then return false, createError end

  local validAfter, problemsAfter = validateSafe(expected, names)
  if validAfter ~= true then return false, schemaFailure(problemsAfter) end
  log('schema validated')
  return true
end

local function connectionReady()
  local ok, result = pcall(function() return MySQL.query.await('SELECT 1 AS ok') end)
  if ok ~= true then return false, sanitize(result) end
  if type(result) ~= 'table' or #result == 0 then return false, 'mysql_probe_empty' end
  return true
end

local function waitForConnection()
  if not mysqlReady() then return false, 'mysql_client_unavailable' end
  local lastError
  for attempt = 1, WAIT_ATTEMPTS do
    local ready, err = connectionReady()
    if ready == true then return true end
    lastError = err
    if attempt == 1 then log('waiting for database connection') end
    if type(Wait) ~= 'function' then break end
    Wait(WAIT_INTERVAL_MS)
  end
  return false, 'database_connection_timeout:' .. sanitize(lastError or 'unknown')
end

function Prepare.run()
  if Prepare.ready == true then return true end
  if Prepare.state == 'waiting' or Prepare.state == 'running' then
    return false, 'initialization_in_progress'
  end
  if not mysqlReady() then
    Prepare.ready, Prepare.state, Prepare.error = false, 'failed', 'mysql_not_ready'
    return false, Prepare.error
  end

  Prepare.state, Prepare.error = 'running', nil
  local ok, result, errorValue = pcall(prepareSchema)
  if ok ~= true then
    Prepare.ready, Prepare.state, Prepare.error = false, 'failed', 'schema_exception:' .. sanitize(result)
  elseif result == true then
    Prepare.ready, Prepare.state, Prepare.error = true, 'ready', nil
  else
    Prepare.ready, Prepare.state, Prepare.error = false, 'failed', sanitize(errorValue)
  end
  return Prepare.ready, Prepare.error
end

function Prepare.bootstrap()
  if Prepare.ready == true then
    log('schema_ready=true')
    return true
  end
  if Prepare.state == 'waiting' or Prepare.state == 'running' then
    return false, 'initialization_in_progress'
  end

  Prepare.state = 'waiting'
  local connected, connectionError = waitForConnection()
  Prepare.state = 'idle'
  if not connected then
    Prepare.ready, Prepare.state, Prepare.error = false, 'failed', sanitize(connectionError)
    log(('schema initialization failed: %s'):format(Prepare.error))
    log('schema_ready=false')
    return false, Prepare.error
  end

  log('database connection ready')
  local ready, errorValue = Prepare.run()
  if ready == true then
    log('schema_ready=true')
    return true
  end
  log(('schema initialization failed: %s'):format(tostring(errorValue)))
  log('schema_ready=false')
  return false, errorValue
end

MZPrison.Prepare = Prepare
