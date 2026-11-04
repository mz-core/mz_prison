-- P7.4B -- migracao aditiva preparada, NAO executada automaticamente.
-- O bootstrap do mz_prison cria/valida esta tabela com o mesmo DDL em
-- server/prepare.lua. Use este arquivo apenas quando o usuario MySQL nao
-- puder executar CREATE/REFERENCES e o operador autorizar a aplicacao manual.

CREATE TABLE IF NOT EXISTS mz_prison_sentence_charges (
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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
