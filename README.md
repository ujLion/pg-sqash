# Flyway Migration Squash Guide

poweshell script to squash postgress's flyway migration scripts

This guide explains how to squash multiple Flyway migrations into a single baseline migration using the provided PowerShell script.

## Overview

The `squash-migrations.ps1` script consolidates all existing Flyway migrations into a single baseline migration (`V1__baseline_squashed.sql`). This is useful when:

- You have accumulated many migrations and want to simplify the history
- New team members need to set up databases quickly
- You want to reduce application startup time
- You're starting a new development phase and want a clean slate

## Prerequisites

Ensure the following tools are installed and available in your PATH:

1. **PostgreSQL Client Tools**
   - `psql` - PostgreSQL command-line client
   - `pg_dump` - PostgreSQL backup utility
   - Download from: https://www.postgresql.org/download/

2. **Flyway CLI**
   - Download from: https://flywaydb.org/download
   - Or install via: `choco install flyway` (Windows)

## Usage

### Basic Usage

Navigate to the backend directory and run:

```powershell
cd backend
.\squash-migrations.ps1
```

### With Custom Database Parameters

```powershell
.\squash-migrations.ps1 `
    -DbHost "localhost" `
    -DbPort 5433 `
    -DbName "partner_dev" `
    -DbUser "postgres" `
    -DbPassword "your_password"
```

### Dry Run (Preview Changes)

To see what would happen without making any changes:

```powershell
.\squash-migrations.ps1 -DryRun
```

### Skip Backups (Not Recommended)

If you're absolutely sure and want to skip backup creation:

```powershell
.\squash-migrations.ps1 -SkipBackup
```

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-DbHost` | string | `localhost` | Database host |
| `-DbPort` | int | `5433` | Database port |
| `-DbName` | string | `partner_dev` | Database name |
| `-DbUser` | string | `postgres` | Database user |
| `-DbPassword` | string | `superduper` | Database password |
| `-DryRun` | switch | `$false` | Preview changes without executing |
| `-SkipBackup` | switch | `$false` | Skip creating backups (dangerous!) |

## What the Script Does

The script performs the following steps:

1. **Prerequisites Check**
   - Verifies `psql`, `pg_dump`, and `flyway` are installed
   - Tests database connectivity

2. **Display Current State**
   - Shows all current migrations in the database
   - Counts total migrations to be squashed

3. **Create Backups**
   - Backs up migration files to `src/main/resources/migration_archive/backup_TIMESTAMP/`
   - Creates full database dump to `squash_TIMESTAMP/db_backup_TIMESTAMP.dump`

4. **Export Schema**
   - Dumps current database schema (without data) to `squash_TIMESTAMP/schema_squashed.sql`
   - Excludes `flyway_schema_history` table

5. **Archive Old Migrations**
   - Moves existing migration files from `db/migration/` to `migration_archive/`

6. **Reset Flyway History**
   - Deletes all records from `flyway_schema_history` table

7. **Create New Baseline**
   - Copies schema dump to `db/migration/V1__baseline_squashed.sql`
   - Inserts baseline record into `flyway_schema_history`

8. **Repair and Verify**
   - Runs `flyway repair` to fix checksums
   - Displays final migration status

## Directory Structure After Squash

```
backend/
├── src/main/resources/
│   ├── db/migration/
│   │   └── V1__baseline_squashed.sql          ← New single migration
│   └── migration_archive/
│       ├── backup_YYYYMMDD_HHMMSS/             ← Timestamped backup
│       │   ├── V1__baseline_schema.sql
│       │   ├── V2__add_email_notification.sql
│       │   └── ... (all original migrations)
│       ├── V1__baseline_schema.sql             ← Original migrations
│       ├── V2__add_email_notification.sql
│       └── ...
└── squash_YYYYMMDD_HHMMSS/                     ← Work directory
    ├── db_backup_YYYYMMDD_HHMMSS.dump         ← Full DB backup
    └── schema_squashed.sql                     ← Schema export
```

## Example Run

```powershell
PS > cd backend
PS > .\squash-migrations.ps1

========================================
  Flyway Migration Squash Script
========================================

Checking prerequisites...
All prerequisites installed ✓
Testing database connection...
Database connection successful ✓

Current migration count: 32

Current migrations in database:
 version |                  description
---------+-----------------------------------------------
 1       | baseline schema
 2       | add email notification queue
 ...
 32      | rename order columns and add notes

This will squash 32 migrations into a single baseline.
Old migrations will be moved to migration_archive directory.

Are you sure you want to continue? (yes/no): yes

Creating backup of migration files...
  Backed up: V1__baseline_schema.sql
  Backed up: V2__add_email_notification_queue.sql
  ...
Backup created in: src/main/resources/migration_archive/backup_20251022_111700 ✓

Creating database backup...
Database backup created: squash_20251022_111700/db_backup_20251022_111700.dump (2.34 MB) ✓

Exporting current schema...
Schema exported: squash_20251022_111700/schema_squashed.sql (2170 lines) ✓

Removing old migration files from active directory...
  Moved: V1__baseline_schema.sql
  Moved: V2__add_email_notification_queue.sql
  ...
Old migrations archived ✓

Clearing Flyway schema history...
Cleared 32 migration records ✓

Creating new baseline migration...
Baseline migration created: src/main/resources/db/migration/V1__baseline_squashed.sql (65.58 KB) ✓

Registering baseline in Flyway history...
Baseline registered ✓

Repairing Flyway checksums...
Flyway checksums repaired ✓

Verifying migration squash...

Flyway Schema History:
 version |    description    |        installed_on
---------+-------------------+----------------------------
 1       | baseline squashed | 2025-10-22 11:17:42.790365

Migration files in active directory: 1

Flyway Info:
+-----------+---------+-------------------+------+---------------------+---------+----------+
| Category  | Version | Description       | Type | Installed On        | State   | Undoable |
+-----------+---------+-------------------+------+---------------------+---------+----------+
| Versioned | 1       | baseline squashed | SQL  | 2025-10-22 11:17:42 | Success | No       |
+-----------+---------+-------------------+------+---------------------+---------+----------+

✓ Migration squash completed successfully!

========================================
  Migration squash completed!
========================================

Backup location: squash_20251022_111700
Archive location: src/main/resources/migration_archive

Next migration should be: V2__your_description.sql
```

## After Squashing

### Creating New Migrations

After squashing, create new migrations starting with V2:

```sql
-- File: src/main/resources/db/migration/V2__add_new_feature.sql
ALTER TABLE users ADD COLUMN phone_verified BOOLEAN DEFAULT false;
```

### Applying to Other Environments

For other environments (staging, production) that already have all migrations applied:

1. **DO NOT** squash on production directly
2. Instead, use Flyway's baseline feature:

```powershell
# On the target environment
flyway baseline -baselineVersion=1 -baselineDescription="baseline squashed"

# Then apply any new migrations (V2+)
flyway migrate
```

### Restoring from Backup (If Needed)

If something goes wrong, restore from the backup:

```powershell
# Drop and recreate database
psql -h localhost -p 5433 -U postgres -c "DROP DATABASE partner_dev;"
psql -h localhost -p 5433 -U postgres -c "CREATE DATABASE partner_dev;"

# Restore from backup
pg_restore -h localhost -p 5433 -U postgres -d partner_dev squash_TIMESTAMP/db_backup_TIMESTAMP.dump

# Restore migration files
Copy-Item -Path src/main/resources/migration_archive/backup_TIMESTAMP/* `
          -Destination src/main/resources/db/migration/ -Force
```

## Troubleshooting

### Error: "Unable to connect to database"

- Verify database is running: `psql -h localhost -p 5433 -U postgres -d partner_dev`
- Check credentials in `.env` file
- Ensure PostgreSQL service is started

### Error: "psql command not found"

- Install PostgreSQL client tools
- Add to PATH: `C:\Program Files\PostgreSQL\16\bin`

### Error: "flyway command not found"

- Download Flyway CLI from https://flywaydb.org/download
- Extract and add to PATH

### Migration files not found

- Ensure you're running from the `backend` directory
- Check that migrations exist in `src/main/resources/db/migration/`

## Best Practices

1. **Always run a dry run first**: Use `-DryRun` to preview changes
2. **Backup before squashing**: Never use `-SkipBackup` in production
3. **Coordinate with team**: Ensure all team members are aware before squashing
4. **Test on development first**: Never squash directly on production
5. **Keep archives**: Don't delete `migration_archive` - it's your history
6. **Document the squash**: Update team documentation with squash date and reason

## Security Notes

- The script accepts database password as a parameter (stored in script history)
- For production use, consider using:
  - `.pgpass` file for password storage
  - Environment variables
  - Flyway configuration files with encrypted passwords
- Never commit database credentials to version control

## Additional Resources

- [Flyway Documentation](https://flywaydb.org/documentation/)
- [PostgreSQL Backup Documentation](https://www.postgresql.org/docs/current/backup.html)
- [Migration Best Practices](https://flywaydb.org/documentation/getstarted/firststeps/best-practices)
