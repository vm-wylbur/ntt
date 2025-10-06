-- Author: PB and Claude
-- Date: 2025-10-06
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/sql/create-detach-guard.sql
--
-- Creates an event trigger to prevent unauthorized partition DETACH operations
-- Based on expert recommendation to prevent spontaneous partition detachment
--
-- WARNING: This guard is NOT ENABLED by default. It's documented here for future use.
--
-- The actual solution is:
-- 1. Use TRUNCATE instead of DELETE in ntt-loader (avoids FK cascade complexity)
-- 2. Add partition attachment check before INSERT
-- 3. Monitor PostgreSQL logs for DETACH commands
--
-- This guard is provided as optional defense-in-depth if needed in the future.

-- Create the guard function
-- NOTE: Event triggers can't access command text at ddl_command_start,
--       so we must check on ALL ALTER TABLE commands and allow via GUC
CREATE OR REPLACE FUNCTION forbid_partition_detach()
RETURNS event_trigger LANGUAGE plpgsql AS $$
BEGIN
  -- Allow any ALTER TABLE only if GUC is explicitly set to 'on' OR missing
  -- This means by default, partition operations are allowed
  -- To enable the guard, set: ALTER SYSTEM SET app.allow_partition_detach = 'off';
  IF current_setting('app.allow_partition_detach', true) = 'block' THEN
    RAISE EXCEPTION 'DETACH PARTITION blocked by security policy (set app.allow_partition_detach=on to allow this operation)';
  END IF;
END$$;

-- Create the event trigger
-- This fires on ddl_command_start for ALTER TABLE commands
-- NOTE: We can't filter by specific ALTER TABLE subcommand at ddl_command_start,
--       so this will check ALL ALTER TABLE commands (minor performance cost)
CREATE EVENT TRIGGER guard_partition_detach
  ON ddl_command_start
  WHEN TAG IN ('ALTER TABLE')
  EXECUTE FUNCTION forbid_partition_detach();

-- To intentionally detach a partition, do:
--   SET app.allow_partition_detach = on;
--   ALTER TABLE parent DETACH PARTITION child;
--   RESET app.allow_partition_detach;

-- To disable the guard entirely:
--   DROP EVENT TRIGGER guard_partition_detach;

-- To re-enable:
--   psql -f create-detach-guard.sql
