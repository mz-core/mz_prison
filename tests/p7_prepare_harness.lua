local function expect(condition, message) if not condition then error(message, 2) end end

local columnPresent = false
local createCalls = 0

MySQL = {
  query = { await = function() createCalls = createCalls + 1; return {} end },
  single = { await = function() return columnPresent and { COLUMN_NAME = 'charge_public_id' } or nil end },
  update = { await = function() return 0 end },
  transaction = { await = function() return true end }
}

dofile('server/prepare.lua')

local legacyOk, legacyError = MZPrison.Prepare.run()
expect(legacyOk == false and legacyError == 'schema_outdated_missing_charge_public_id',
  'schema legado foi aceito sem a coluna canonica')

columnPresent = true
local readyOk, readyError = MZPrison.Prepare.run()
expect(readyOk == true and readyError == nil and createCalls == 6, 'schema atualizado nao ficou pronto')

print('mz_prison P7 prepare harness: PASS cases=2')
