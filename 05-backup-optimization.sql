-- =============================================================================
-- 05-backup-optimization.sql
-- CockroachDB Cost Optimization Toolkit
-- Category: Backup Strategies and Cost Optimization
-- =============================================================================
--
-- PURPOSE:
--   Backup storage is often the second-largest cost after compute. This file
--   provides scheduled backup examples, monitoring queries, and S3 lifecycle
--   recommendations to minimize backup costs while maintaining your RPO/RTO.
--
-- KEY COST LEVERS:
--   1. Retention window: shorter = cheaper. Align to actual RPO/RTO.
--   2. Incremental vs full frequency: incrementals are very space-efficient.
--   3. Scope: database/table-level backups vs full cluster.
--   4. S3 storage class tiering: STANDARD -> IA -> GLACIER -> DEEP ARCHIVE.
--   5. Locality-aware backups: write to regional buckets to avoid egress.
--
-- PREREQUISITES:
--   - Admin SQL user
--   - Enterprise license (BACKUP is an enterprise feature)
--   - S3 bucket with appropriate IAM permissions
--
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. Scheduled Backup: Daily Full + Hourly Incremental (Recommended)
-- ---------------------------------------------------------------------------
-- This is the most cost-effective backup strategy for most workloads.
-- Daily full backups provide a restore baseline, and hourly incrementals
-- capture changes efficiently.
--
-- CockroachDB incrementals are very space-efficient: hourly incrementals
-- typically add only modest extra cost, not 24x the full backup size.
--
-- Replace the S3 URL, credentials, and database name with your own values.

-- ACTION: Create a daily full + hourly incremental backup schedule
--
-- CREATE SCHEDULE daily_full_backup
-- FOR BACKUP DATABASE mydb
--   INTO 's3://my-backup-bucket/crdb/mydb?AUTH=specified&AWS_ACCESS_KEY_ID=<key>&AWS_SECRET_ACCESS_KEY=<secret>'
--   WITH revision_history
--   RECURRING '@daily'
--   FULL BACKUP '@daily'
--   SCHEDULE OPTIONS first_run = 'now';
--
-- CREATE SCHEDULE hourly_incremental_backup
-- FOR BACKUP DATABASE mydb
--   INTO LATEST IN 's3://my-backup-bucket/crdb/mydb?AUTH=specified&AWS_ACCESS_KEY_ID=<key>&AWS_SECRET_ACCESS_KEY=<secret>'
--   WITH revision_history
--   RECURRING '@hourly'
--   FULL BACKUP '@daily'
--   SCHEDULE OPTIONS first_run = 'now';


-- ---------------------------------------------------------------------------
-- 2. Scheduled Backup: Weekly Full + Daily Incremental (Lower Cost)
-- ---------------------------------------------------------------------------
-- For less critical data where a longer RPO is acceptable.
-- Weekly full + daily incremental significantly reduces backup volume.

-- ACTION: Create a weekly full + daily incremental schedule
--
-- CREATE SCHEDULE weekly_full_backup
-- FOR BACKUP DATABASE mydb_archive
--   INTO 's3://my-backup-bucket/crdb/mydb_archive?AUTH=specified&AWS_ACCESS_KEY_ID=<key>&AWS_SECRET_ACCESS_KEY=<secret>'
--   RECURRING '@weekly'
--   FULL BACKUP '@weekly'
--   SCHEDULE OPTIONS first_run = 'now';


-- ---------------------------------------------------------------------------
-- 3. Locality-Aware Backup (Multi-Region Cost Savings)
-- ---------------------------------------------------------------------------
-- For multi-region clusters, locality-aware backups write each node's data
-- to the nearest regional S3 bucket. This eliminates cross-region data
-- transfer (egress) charges.

-- ACTION: Create a locality-aware backup
--
-- CREATE SCHEDULE locality_aware_backup
-- FOR BACKUP DATABASE mydb
--   INTO (
--     's3://us-east-backup/crdb/mydb?AUTH=specified&AWS_ACCESS_KEY_ID=<key>&AWS_SECRET_ACCESS_KEY=<secret>',
--     's3://us-west-backup/crdb/mydb?AUTH=specified&AWS_ACCESS_KEY_ID=<key>&AWS_SECRET_ACCESS_KEY=<secret>',
--     's3://eu-west-backup/crdb/mydb?AUTH=specified&AWS_ACCESS_KEY_ID=<key>&AWS_SECRET_ACCESS_KEY=<secret>'
--   )
--   WITH revision_history
--   RECURRING '@daily'
--   FULL BACKUP '@daily';


-- ---------------------------------------------------------------------------
-- 4. Backup Job Monitoring
-- ---------------------------------------------------------------------------
-- Use these queries to monitor backup health, duration, and size.

-- 4a. Show all scheduled backup jobs
SELECT
    id,
    label,
    schedule_status,
    recurrence,
    next_run,
    created
FROM [SHOW SCHEDULES]
WHERE label LIKE '%backup%'
   OR schedule_status IS NOT NULL
ORDER BY next_run;

-- 4b. Recent backup job history (last 7 days)
-- Shows whether backups are succeeding, how long they take, and their size.
--
-- WHAT TO LOOK FOR:
--   - status should be 'succeeded' for all recent backups.
--   - If a backup has status 'failed', check the error column.
--   - Long-running backups may indicate the cluster is undersized or
--     backups are running during peak hours.

SELECT
    job_id,
    job_type,
    description,
    status,
    created,
    finished,
    finished - created                   AS duration,
    error
FROM [SHOW JOBS]
WHERE job_type IN ('BACKUP', 'SCHEDULED BACKUP')
  AND created >= now() - INTERVAL '7 days'
ORDER BY created DESC
LIMIT 20;

-- 4c. Currently running backup jobs
SELECT
    job_id,
    job_type,
    description,
    status,
    created,
    now() - created                      AS running_for,
    fraction_completed
FROM [SHOW JOBS]
WHERE job_type IN ('BACKUP', 'SCHEDULED BACKUP')
  AND status = 'running';

-- 4d. Backup schedule details
SHOW SCHEDULES;


-- ---------------------------------------------------------------------------
-- 5. S3 Lifecycle Policy Recommendations
-- ---------------------------------------------------------------------------
-- CockroachDB writes backup files as plain S3 objects. You can use S3
-- lifecycle policies to automatically tier and expire old backups, which
-- is the most effective way to control long-term backup costs.
--
-- RECOMMENDED S3 LIFECYCLE POLICY:
--
--   {
--     "Rules": [
--       {
--         "ID": "TransitionToIA",
--         "Filter": { "Prefix": "crdb/" },
--         "Status": "Enabled",
--         "Transitions": [
--           {
--             "Days": 7,
--             "StorageClass": "STANDARD_IA"
--           }
--         ]
--       },
--       {
--         "ID": "TransitionToGlacier",
--         "Filter": { "Prefix": "crdb/" },
--         "Status": "Enabled",
--         "Transitions": [
--           {
--             "Days": 30,
--             "StorageClass": "GLACIER"
--           }
--         ]
--       },
--       {
--         "ID": "TransitionToDeepArchive",
--         "Filter": { "Prefix": "crdb/" },
--         "Status": "Enabled",
--         "Transitions": [
--           {
--             "Days": 90,
--             "StorageClass": "DEEP_ARCHIVE"
--           }
--         ]
--       },
--       {
--         "ID": "ExpireOldBackups",
--         "Filter": { "Prefix": "crdb/" },
--         "Status": "Enabled",
--         "Expiration": {
--           "Days": 365
--         }
--       }
--     ]
--   }
--
-- COST SAVINGS ESTIMATE:
--   - STANDARD:     $0.023/GB/month
--   - STANDARD_IA:  $0.0125/GB/month  (45% savings)
--   - GLACIER:      $0.004/GB/month   (83% savings)
--   - DEEP ARCHIVE: $0.00099/GB/month (96% savings)
--
-- IMPORTANT NOTES:
--   - GLACIER retrieval takes 3-5 hours (standard) or 5-12 hours (bulk).
--   - DEEP ARCHIVE retrieval takes 12-48 hours.
--   - Factor retrieval time into your RTO when choosing tiers.
--   - Always keep your most recent backup in STANDARD for fast restores.
--
-- TO APPLY THIS POLICY (AWS CLI):
--   aws s3api put-bucket-lifecycle-configuration \
--     --bucket my-backup-bucket \
--     --lifecycle-configuration file://lifecycle-policy.json


-- ---------------------------------------------------------------------------
-- 6. Backup Retention Best Practices Summary
-- ---------------------------------------------------------------------------
-- COMMON MISTAKE: Keeping 30+ days of full backups "just in case."
-- This is expensive and usually unnecessary.
--
-- RECOMMENDED APPROACH:
--   - Keep 7 days of full backups in STANDARD (fast restore for recent issues)
--   - Keep 30-90 days of incremental backups in STANDARD_IA
--   - Archive to GLACIER after 30 days
--   - Auto-expire after 365 days (or your compliance requirement)
--
-- SAVINGS EXAMPLE:
--   - 100GB database with daily fulls = ~3TB/month in STANDARD = $69/month
--   - Same database with 7-day retention + lifecycle = ~$15-20/month
--   - Savings: ~$50/month or ~$600/year per database


-- =============================================================================
-- END OF 05-backup-optimization.sql
-- =============================================================================
