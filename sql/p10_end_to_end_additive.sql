-- P10 policial/prisional: migracao aditiva. Revisar e executar manualmente.
-- Nao remove nem altera dados existentes.

ALTER TABLE mz_prison_sentences
  ADD COLUMN IF NOT EXISTS facility_id VARCHAR(64) NULL AFTER property_status,
  ADD COLUMN IF NOT EXISTS intake_point_id VARCHAR(64) NULL AFTER facility_id,
  ADD COLUMN IF NOT EXISTS cell_id VARCHAR(64) NULL AFTER intake_point_id,
  ADD COLUMN IF NOT EXISTS previous_routing_bucket INT UNSIGNED NOT NULL DEFAULT 0 AFTER cell_id,
  ADD COLUMN IF NOT EXISTS confinement_status VARCHAR(24) NOT NULL DEFAULT 'not_applicable'
    AFTER previous_routing_bucket;
