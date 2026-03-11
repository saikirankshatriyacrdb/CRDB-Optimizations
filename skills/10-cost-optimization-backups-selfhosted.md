# CRDB Cost Optimization: Backups (Self-Hosted)

**When to use:** Reducing backup storage costs, designing backup schedules, or migrating to tiered object storage.

> Moving from "daily full, 30-day retention" to "weekly full + daily incremental, tiered storage" typically cuts 40–60% of backup storage cost.

---

## 1. Audit Current Backup Jobs

```sql
SHOW SCHEDULES;

SELECT job_id, job_type, description, status, created, finished, error
FROM [SHOW JOBS] WHERE job_type = 'BACKUP'
ORDER BY created DESC LIMIT 20;

SELECT MAX(finished) AS last_successful_backup
FROM [SHOW JOBS] WHERE job_type = 'BACKUP' AND status = 'succeeded';
```

---

## 2. Create a Tiered Backup Schedule

### AWS S3
```sql
-- CUSTOMIZE: schedule_name, db_name, bucket, path, credentials
CREATE SCHEDULE [schedule_name]
FOR BACKUP DATABASE [db_name]
    INTO 's3://[bucket]/[path]?AUTH=specified&AWS_ACCESS_KEY_ID=[key]&AWS_SECRET_ACCESS_KEY=[secret]'
    WITH revision_history
    RECURRING '@daily'       -- CUSTOMIZE: incremental frequency
    FULL BACKUP '@weekly'    -- CUSTOMIZE: full backup frequency
    WITH SCHEDULE OPTIONS first_run = 'now';
```

### GCP Cloud Storage
```sql
CREATE SCHEDULE [schedule_name]
FOR BACKUP DATABASE [db_name]
    INTO 'gs://[bucket]/[path]?AUTH=specified&CREDENTIALS=[base64_creds]'
    WITH revision_history
    RECURRING '@daily' FULL BACKUP '@weekly'
    WITH SCHEDULE OPTIONS first_run = 'now';
```

### Azure Blob Storage
```sql
CREATE SCHEDULE [schedule_name]
FOR BACKUP DATABASE [db_name]
    INTO 'azure-blob://[container]/[path]?AUTH=specified&AZURE_ACCOUNT_NAME=[account]&AZURE_ACCOUNT_KEY=[key]'
    WITH revision_history
    RECURRING '@daily' FULL BACKUP '@weekly'
    WITH SCHEDULE OPTIONS first_run = 'now';
```

### MinIO / S3-Compatible
```sql
CREATE SCHEDULE [schedule_name]
FOR BACKUP DATABASE [db_name]
    INTO 's3://[bucket]/[path]?AUTH=specified&AWS_ENDPOINT=http://[minio-host]:9000&AWS_ACCESS_KEY_ID=[key]&AWS_SECRET_ACCESS_KEY=[secret]'
    WITH revision_history
    RECURRING '@daily' FULL BACKUP '@weekly'
    WITH SCHEDULE OPTIONS first_run = 'now';
```

---

## 3. Backup Schedule by Criticality

| Tier | Full Backup | Incremental | Retention | Storage |
|---|---|---|---|---|
| **Critical** | Daily | Hourly | 30 days | Hot → Warm → Cold |
| **Standard** | Weekly | Daily | 14 days | Hot → Warm |
| **Dev/Non-prod** | Weekly | None | 7 days | Hot only |
| **Compliance** | Monthly | Weekly | 1–7 years | Cold → Archive |

---

## 4. Object Storage Tiering (All Providers)

| Days | AWS S3 | GCP Cloud Storage | Azure Blob | MinIO |
|---|---|---|---|---|
| 0–7d | STANDARD | Standard | Hot | STANDARD |
| 7–30d | STANDARD_IA | Nearline | Cool | Policy-based |
| 30–90d | GLACIER | Coldline | Cold | Policy-based |
| 90d+ | DEEP ARCHIVE | Archive | Archive | Policy-based |
| Expiry | Compliance boundary | Compliance boundary | Compliance boundary | Compliance boundary |

---

## 5. Locality-Aware Backups (Multi-Region)

```sql
-- CUSTOMIZE: locality values, bucket per region
BACKUP DATABASE [db_name]
    INTO LATEST IN 's3://[primary-bucket]/[path]?AUTH=specified&...'
    WITH revision_history,
         locality_aware_backup = (
             's3://[us-east-bucket]/[path]?AWS_REGION=us-east-1&...' AS 'region=us-east-1',
             's3://[eu-west-bucket]/[path]?AWS_REGION=eu-west-1&...' AS 'region=eu-west-1'
         );
```

---

## 6. Manage Schedules

```sql
PAUSE SCHEDULE [schedule_id];
RESUME SCHEDULE [schedule_id];
DROP SCHEDULE [schedule_id];
SHOW SCHEDULE [schedule_id];
```

---

## Customization Checklist
- [ ] Replace `[bucket]`, `[path]`, `[db_name]` with actual values
- [ ] Use `AUTH=implicit` (IAM role) over `AUTH=specified` (keys) where possible
- [ ] Set `RECURRING` based on RPO (hourly = tight, daily = standard)
- [ ] Apply object storage lifecycle rules immediately after first backup
- [ ] Alert on `status = 'failed'` in SHOW JOBS
- [ ] Test restore from backup in staging before relying on it for DR
- [ ] Use `WITH revision_history` only if point-in-time restore is required
