-- Author: PB and Claude
-- Date: 2025-11-22
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ---
-- ntt/sql/create-email-index-progress-table.sql

-- Create progress tracking table for Elasticsearch email ingestion
-- Tracks which blobs have been indexed, failed, or are pending

CREATE TABLE IF NOT EXISTS email_index_progress (
    blobid TEXT PRIMARY KEY REFERENCES blobs(blobid),

    -- Processing status
    status TEXT NOT NULL CHECK (status IN ('pending', 'success', 'failed')),

    -- Email format detected (eml, emlx, mbox, msg, maildir, etc.)
    email_format TEXT,

    -- Error information for failed blobs
    error_message TEXT,
    error_type TEXT,  -- parse_error, encoding_error, es_error, etc.

    -- Elasticsearch index name where document was indexed
    es_index TEXT,

    -- Timestamps
    indexed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for querying
CREATE INDEX idx_email_index_progress_status
  ON email_index_progress(status);

CREATE INDEX idx_email_index_progress_format
  ON email_index_progress(email_format)
  WHERE email_format IS NOT NULL;

CREATE INDEX idx_email_index_progress_failed
  ON email_index_progress(error_type)
  WHERE status = 'failed';

-- Comment on table
COMMENT ON TABLE email_index_progress IS
  'Tracks Elasticsearch indexing progress for email blobs. Used by ntt-es ingestion pipeline.';

COMMENT ON COLUMN email_index_progress.status IS
  'pending: not yet processed, success: indexed to ES, failed: error during processing';

COMMENT ON COLUMN email_index_progress.email_format IS
  'Detected email format: eml, emlx, mbox, msg, maildir, dbx, tnef, etc.';
