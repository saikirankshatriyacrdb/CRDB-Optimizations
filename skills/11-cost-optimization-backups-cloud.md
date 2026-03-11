# CRDB Cost Optimization: Backups (CockroachDB Cloud)

**When to use:** Reducing backup line item costs on CockroachDB Cloud, or designing a hybrid managed + self-managed backup strategy.

---

## Managed vs Self-Managed Strategy

| | Managed (CRL-operated) | Self-Managed (Your bucket) |
|---|---|---|
| Always on | ✅ Can't disable | Optional |
| Fast restore | ✅ Cloud Console | Depends on restore speed |
| Cost control | ⚠️ Retention drives cost | ✅ Full control via lifecycle |
| Long-term archival | ❌ Expensive | ✅ Tiered object storage |
| Compliance copy | ❌ Limited | ✅ Full control |

**Recommended:** Keep managed retention SHORT (7 days) for fast restore. Use self-managed for long-term archival.

---

## 1. Audit Current Backup State

```sql
SELECT job_id, job_type, description, status, created, finished, error
FROM [SHOW JOBS] WHERE job_type = 'BACKUP'
ORDER BY created DESC LIMIT 20;

-- Alert check: no successful backup in 25h
SELECT
    CASE WHEN MAX(finished) < now() - INTERVAL '25 hours'
         THEN '⚠️ NO RECENT BACKUP' ELSE '✅ Backup OK' END AS status,
    MAX(finished) AS last_backup
FROM [SHOW JOBS] WHERE job_type = 'BACKUP' AND status = 'succeeded';
```

---

## 2. Self-Managed Backup Schedule

### AWS S3
```sql
-- CUSTOMIZE: schedule_name, db_name, bucket, path
CREATE SCHEDULE [schedule_name]
FOR BACKUP DATABASE [db_name]
    INTO 's3://[your-bucket]/crdb/[db_name]?AUTH=implicit'
    WITH revision_history
    RECURRING '@daily' FULL BACKUP '@weekly'
    WITH SCHEDULE OPTIONS first_run = 'now';
```

### GCP Cloud Storage
```sql
CREATE SCHEDULE [schedule_name]
FOR BACKUP DATABASE [db_name]
    INTO 'gs://[your-bucket]/crdb/[db_name]?AUTH=implicit'
    WITH revision_history
    RECURRING '@daily' FULL BACKUP '@weekly'
    WITH SCHEDULE OPTIONS first_run = 'now';
```

### Azure Blob Storage
```sql
CREATE SCHEDULE [schedule_name]
FOR BACKUP DATABASE [db_name]
    INTO 'azure-blob://[container]/crdb/[db_name]?AUTH=specified&AZURE_ACCOUNT_NAME=[account]&AZURE_ACCOUNT_KEY=[key]'
    WITH revision_history
    RECURRING '@daily' FULL BACKUP '@weekly'
    WITH SCHEDULE OPTIONS first_run = 'now';
```

---

## 3. Object Storage Tiering by Provider

| Day Range | AWS S3 | GCP Cloud Storage | Azure Blob | Savings |
|---|---|---|---|---|
| 0–7 days | STANDARD | Standard | Hot | Baseline |
| 7–30 days | STANDARD_IA | Nearline | Cool | ~40% |
| 30–90 days | GLACIER | Coldline | Cold | ~70% |
| 90+ days | DEEP ARCHIVE | Archive | Archive | ~90% |
| Expiry | Delete | Delete | Delete | Compliance boundary |

### Lifecycle Rule Pattern (apply in provider console)
```
Prefix: crdb/[db_name]/          ← CUSTOMIZE: match your backup path
After 7 days   → Warm tier
After 30 days  → Cold tier
After 90 days  → Archive tier
After [N] days → Delete (N = compliance retention period)
```

---

## 4. Recommended Retention Split

```
Managed retention:    7 days    (fast restore via Cloud Console)    ← CUSTOMIZE
Self-managed:         90 days   (standard compliance)               ← CUSTOMIZE
Self-managed archive: 1–7 yrs   (regulatory archive)                ← CUSTOMIZE
```

---

## 5. Locality-Aware Backups (Multi-Region Cloud)

```sql
-- CUSTOMIZE: locality values must match cluster locality settings
BACKUP DATABASE [db_name]
    INTO LATEST IN 's3://[primary-bucket]/[path]?AUTH=implicit'
    WITH revision_history,
         locality_aware_backup = (
             's3://[us-bucket]/[path]?AWS_REGION=us-east-1' AS 'region=us-east-1',
             'gs://[eu-bucket]/[path]?AUTH=implicit' AS 'region=eu-west-1'
         );
```

---

## 6. Monitor Backup Health

```sql
SELECT job_id, description, status, error, created, finished
FROM [SHOW JOBS] WHERE job_type = 'BACKUP' AND status = 'failed'
  AND created >= now() - INTERVAL '24 hours';

SHOW SCHEDULES;
-- Check: schedule_status = 'ACTIVE', last_run, next_run
```

---

## Customization Checklist
- [ ] Set managed backup retention in Cloud Console → Backup Settings (recommend: 7 days)
- [ ] Replace `[your-bucket]`, `[db_name]` with actual values
- [ ] Use `AUTH=implicit` for IAM-role auth (more secure, no keys in SQL)
- [ ] Apply object storage lifecycle rules immediately
- [ ] Set compliance boundary in lifecycle expiry rule
- [ ] Test restore from self-managed backup before relying on it for DR
- [ ] Use `revision_history` only if point-in-time restore required (~20–30% extra storage)
- [ ] For multi-region, always use `locality_aware_backup` to avoid egress charges
