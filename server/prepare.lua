MZPrison = MZPrison or {}

local Prepare = { ready = false, error = nil }
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
    sentenced_by_citizenid VARCHAR(64) NOT NULL,
    last_error VARCHAR(64) NULL,
    started_at TIMESTAMP NULL,
    released_at TIMESTAMP NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_mz_prison_sentences_operation (operation_id),
    KEY idx_mz_prison_sentences_target_status (target_citizenid, status)
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
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]]
}

function Prepare.run()
  if Prepare.ready then return true end
  if not (MySQL and MySQL.query and type(MySQL.query.await) == 'function'
    and MySQL.single and type(MySQL.single.await) == 'function'
    and MySQL.update and type(MySQL.update.await) == 'function'
    and MySQL.transaction and type(MySQL.transaction.await) == 'function') then
    Prepare.error = 'mysql_not_ready'; return false, Prepare.error
  end
  local ok, columnOrError = pcall(function()
    for _, statement in ipairs(statements) do MySQL.query.await(statement) end
    return MySQL.single.await([[SELECT COLUMN_NAME FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'mz_prison_sentences'
        AND COLUMN_NAME = 'charge_public_id' LIMIT 1]])
  end)
  if ok ~= true then
    Prepare.error = tostring(columnOrError)
  elseif not columnOrError then
    Prepare.error = 'schema_outdated_missing_charge_public_id'
  else
    Prepare.ready, Prepare.error = true, nil
  end
  return Prepare.ready, Prepare.error
end

MZPrison.Prepare = Prepare
