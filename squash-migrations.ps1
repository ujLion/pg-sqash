# **⚠️ WARNING: This guide and any accompanying scripts are provided "AS IS" with NO WARRANTIES. 
# Running the described migration squash procedure can cause DATA LOSS, irreversible changes to databases, 
# and may require restoring from backups. Always verify backups, test in non-production environments first, 
# and coordinate with your team before proceeding. The authors are not responsible for any damage or data loss.**


# Flyway Migration Squash Script for Windows/PowerShell
# This script squashes all existing Flyway migrations into a single baseline migration
# WARNING: This should only be run when you're certain you want to consolidate migrations

param(
    [switch]$DryRun = $false,
    [switch]$SkipBackup = $false
)

# --- Load .env if present ---
$envFile = ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]*)=(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            if ($value -match '^".*"$' -or $value -match "^'.*'$") {
                $value = $value.Substring(1, $value.Length - 2)
            }
            [System.Environment]::SetEnvironmentVariable($key, $value)
        }
    }
}
else {
    Write-Error ".env file not found."
    exit 1
}

# --- Assign from environment ---
$DbHost = $env:DB_HOST
$DbPort = $env:DB_PORT
$DbName = $env:DB_NAME
$DbUser = $env:DB_USER
$DbPassword = $env:DB_PASSWORD

# --- Validate required vars ---
if (-not $DbHost -or -not $DbPort -or -not $DbName -or -not $DbUser) {
    Write-Error "Missing required DB environment variables."
    exit 1
}

# Color output functions
function Write-Success { Write-Host $args -ForegroundColor Green }
function Write-Info { Write-Host $args -ForegroundColor Cyan }
function Write-Warning { Write-Host $args -ForegroundColor Yellow }
function Write-Error { Write-Host $args -ForegroundColor Red }

# Check if required tools are installed
function Test-Prerequisites {
    Write-Info "Checking prerequisites..."

    $tools = @("psql", "pg_dump", "flyway")
    $missing = @()

    foreach ($tool in $tools) {
        if (!(Get-Command $tool -ErrorAction SilentlyContinue)) {
            $missing += $tool
        }
    }

    if ($missing.Count -gt 0) {
        Write-Error "Missing required tools: $($missing -join ', ')"
        Write-Info "Please install:"
        Write-Info "  - PostgreSQL client tools (psql, pg_dump)"
        Write-Info "  - Flyway CLI"
        exit 1
    }

    Write-Success "All prerequisites installed ✓"
}

# Test database connection
function Test-DatabaseConnection {
    Write-Info "Testing database connection..."

    $env:PGPASSWORD = $DbPassword
    $testQuery = "SELECT version();"
    $result = psql -h $DbHost -p $DbPort -U $DbUser -d $DbName -c $testQuery 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to connect to database"
        Write-Error $result
        exit 1
    }

    Write-Success "Database connection successful ✓"
}

# Get current migration count
function Get-MigrationCount {
    $env:PGPASSWORD = $DbPassword
    $query = "SELECT COUNT(*) FROM flyway_schema_history WHERE success = true;"
    $count = psql -h $DbHost -p $DbPort -U $DbUser -d $DbName -t -A -c $query

    return [int]$count.Trim()
}

# Display current migrations
function Show-CurrentMigrations {
    Write-Info "`nCurrent migrations in database:"

    $env:PGPASSWORD = $DbPassword
    $query = "SELECT version, description, installed_on FROM flyway_schema_history ORDER BY installed_rank;"
    psql -h $DbHost -p $DbPort -U $DbUser -d $DbName -c $query
}

# Create backup of migration files
function Backup-Migrations {
    param([string]$BackupDir)

    if ($SkipBackup) {
        Write-Warning "Skipping migration backup (--SkipBackup flag set)"
        return
    }

    Write-Info "Creating backup of migration files..."

    $migrationDir = "src/main/resources/db/migration"
    $archiveDir = "src/main/resources/migration_archive"

    # Create archive directory if it doesn't exist
    if (!(Test-Path $archiveDir)) {
        New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
    }

    # Get all migration files
    $migrationFiles = Get-ChildItem -Path $migrationDir -Filter "V*.sql"

    if ($migrationFiles.Count -eq 0) {
        Write-Warning "No migration files found to backup"
        return
    }

    # Move files to archive with timestamp
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupSubDir = Join-Path $archiveDir "backup_$timestamp"

    New-Item -ItemType Directory -Path $backupSubDir -Force | Out-Null

    foreach ($file in $migrationFiles) {
        if ($DryRun) {
            Write-Info "  [DRY RUN] Would move: $($file.Name) -> $backupSubDir"
            continue
        }

        # Move (not copy) to avoid duplicate backups and leave only archived copy
        $destFile = Join-Path $backupSubDir $file.Name
        if (Test-Path $destFile) {
            Write-Warning "  Overwriting existing in archive: $($file.Name)"
        }
        Move-Item -Path $file.FullName -Destination $backupSubDir -Force
        Write-Info "  Moved: $($file.Name)"
    }

    Write-Success "Old migrations moved to archive: $backupSubDir ✓"
}

# Create database backup
function Backup-Database {
    param([string]$BackupFile)

    if ($SkipBackup) {
        Write-Warning "Skipping database backup (--SkipBackup flag set)"
        return
    }

    Write-Info "Creating database backup..."

    $env:PGPASSWORD = $DbPassword
    pg_dump -h $DbHost -p $DbPort -U $DbUser -d $DbName -F c -b -v -f $BackupFile 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Database backup failed"
        exit 1
    }

    $size = (Get-Item $BackupFile).Length / 1MB
    Write-Success "Database backup created: $BackupFile ($([math]::Round($size, 2)) MB) ✓"
}

# Create schema dump
function Export-SchemaOnly {
    param([string]$OutputFile)

    Write-Info "Exporting current schema..."

    $env:PGPASSWORD = $DbPassword
    pg_dump -h $DbHost -p $DbPort -U $DbUser -d $DbName `
        --schema-only `
        --no-owner `
        --no-privileges `
        --no-tablespaces `
        -T flyway_schema_history `
        -f $OutputFile 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Schema export failed"
        exit 1
    }

    # --- Sanitize exported schema: remove lines beginning with \restrict or \unrestrict ---
    if (Test-Path $OutputFile) {
        $origLines = Get-Content $OutputFile
        $filteredLines = $origLines | Where-Object { -not ($_ -match '^\s*\\(un)?restrict') }
        $removedCount = $origLines.Count - $filteredLines.Count

        if ($removedCount -gt 0) {
            Set-Content -Path $OutputFile -Value $filteredLines -Encoding UTF8
            Write-Info "Removed $removedCount lines beginning with '\restrict' or '\unrestrict' from: $OutputFile"
        } else {
            Write-Info "No '\restrict' or '\unrestrict' lines found in: $OutputFile"
        }
    }

    $lines = (Get-Content $OutputFile | Measure-Object -Line).Lines
    Write-Success "Schema exported: $OutputFile ($lines lines) ✓"
}

# Clear Flyway schema history
function Clear-FlywayHistory {
    Write-Warning "Clearing Flyway schema history..."

    if ($DryRun) {
        Write-Info "[DRY RUN] Would execute: DELETE FROM flyway_schema_history;"
        return 0
    }

    $env:PGPASSWORD = $DbPassword
    $query = "DELETE FROM flyway_schema_history;"
    $result = psql -h $DbHost -p $DbPort -U $DbUser -d $DbName -c $query 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to clear Flyway history"
        Write-Error $result
        exit 1
    }

    # Extract number of deleted rows
    if ($result -match "DELETE (\d+)") {
        $deletedCount = $matches[1]
        Write-Success "Cleared $deletedCount migration records ✓"
        return $deletedCount
    }

    return 0
}

# Remove old migration files
function Remove-OldMigrations {
    Write-Info "Removing old migration files from active directory..."

    $migrationDir = "src/main/resources/db/migration"
    $archiveDir = "src/main/resources/migration_archive"

    # Create archive if it doesn't exist
    if (!(Test-Path $archiveDir)) {
        New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
    }

    # Move old migrations to archive
    $oldMigrations = Get-ChildItem -Path $migrationDir -Filter "V*.sql"

    if ($DryRun) {
        Write-Info "[DRY RUN] Would move $($oldMigrations.Count) files to archive"
        foreach ($file in $oldMigrations) {
            Write-Info "  [DRY RUN] Would move: $($file.Name)"
        }
        return
    }

    foreach ($file in $oldMigrations) {
        # Check if file already exists in archive
        $destFile = Join-Path $archiveDir $file.Name
        if (Test-Path $destFile) {
            Write-Warning "  Overwriting existing: $($file.Name)"
        }
        Move-Item -Path $file.FullName -Destination $archiveDir -Force
        Write-Info "  Moved: $($file.Name)"
    }

    Write-Success "Old migrations archived ✓"
}

# Create new baseline migration
function New-BaselineMigration {
    param([string]$SquashedFile)

    Write-Info "Creating new baseline migration..."

    $migrationDir = "src/main/resources/db/migration"
    $baselineFile = Join-Path $migrationDir "V1__baseline_squashed.sql"

    if ($DryRun) {
        Write-Info "[DRY RUN] Would copy: $SquashedFile -> $baselineFile"
        return
    }

    # Ensure migration directory exists
    if (!(Test-Path $migrationDir)) {
        New-Item -ItemType Directory -Path $migrationDir -Force | Out-Null
    }

    Copy-Item -Path $SquashedFile -Destination $baselineFile -Force

    $size = (Get-Item $baselineFile).Length / 1KB
    Write-Success "Baseline migration created: $baselineFile ($([math]::Round($size, 2)) KB) ✓"
}

# Insert baseline record into Flyway history
function Set-FlywayBaseline {
    Write-Info "Registering baseline in Flyway history..."

    if ($DryRun) {
        Write-Info "[DRY RUN] Would insert baseline record into flyway_schema_history"
        return
    }

    $env:PGPASSWORD = $DbPassword
    $query = @"
INSERT INTO flyway_schema_history
    (installed_rank, version, description, type, script, checksum, installed_by, installed_on, execution_time, success)
VALUES
    (1, '1', 'baseline squashed', 'SQL', 'V1__baseline_squashed.sql', 0, '$DbUser', now(), 0, true);
"@

    $result = psql -h $DbHost -p $DbPort -U $DbUser -d $DbName -c $query 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to insert baseline record"
        Write-Error $result
        exit 1
    }

    Write-Success "Baseline registered ✓"
}

# Repair Flyway checksums
function Repair-FlywayChecksums {
    Write-Info "Repairing Flyway checksums..."

    if ($DryRun) {
        Write-Info "[DRY RUN] Would run: flyway repair"
        return
    }

    $flywayUrl = "jdbc:postgresql://${DbHost}:${DbPort}/${DbName}"
    $locations = "filesystem:src/main/resources/db/migration"

    flyway -url="$flywayUrl" -user="$DbUser" -password="$DbPassword" -locations="$locations" repair

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Flyway repair reported issues (this may be normal)"
    } else {
        Write-Success "Flyway checksums repaired ✓"
    }
}

# Verify final state
function Test-MigrationSquash {
    Write-Info "`nVerifying migration squash..."

    # Check Flyway history
    $env:PGPASSWORD = $DbPassword
    $query = "SELECT version, description, installed_on FROM flyway_schema_history ORDER BY installed_rank;"
    Write-Info "`nFlyway Schema History:"
    psql -h $DbHost -p $DbPort -U $DbUser -d $DbName -c $query

    # Check migration files
    $migrationDir = "src/main/resources/db/migration"
    $migrationCount = (Get-ChildItem -Path $migrationDir -Filter "V*.sql" | Measure-Object).Count

    Write-Info "`nMigration files in active directory: $migrationCount"

    # Verify using Flyway
    $flywayUrl = "jdbc:postgresql://${DbHost}:${DbPort}/${DbName}"
    $locations = "filesystem:src/main/resources/db/migration"

    Write-Info "`nFlyway Info:"
    flyway -url="$flywayUrl" -user="$DbUser" -password="$DbPassword" -locations="$locations" info

    if ($migrationCount -eq 1) {
        Write-Success "`n✓ Migration squash completed successfully!"
    } else {
        Write-Warning "`n⚠ Warning: Expected 1 migration file, found $migrationCount"
    }
}

# Main execution
function Main {
    Write-Host "`n========================================" -ForegroundColor Magenta
    Write-Host "  Flyway Migration Squash Script" -ForegroundColor Magenta
    Write-Host "========================================`n" -ForegroundColor Magenta

    if ($DryRun) {
        Write-Warning "**DRY RUN MODE** - No changes will be made`n"
    }

    # Prerequisites
    Test-Prerequisites
    Test-DatabaseConnection

    # Show current state
    $currentCount = Get-MigrationCount
    Write-Info "`nCurrent migration count: $currentCount"

    if ($currentCount -eq 0) {
        Write-Warning "No migrations found in database. Nothing to squash."
        exit 0
    }

    if ($currentCount -eq 1) {
        Write-Warning "Only 1 migration exists. Consider if squashing is necessary."
        $continue = Read-Host "Continue anyway? (y/N)"
        if ($continue -ne "y") {
            Write-Info "Aborted by user."
            exit 0
        }
    }

    Show-CurrentMigrations

    # Confirmation
    if (!$DryRun) {
        Write-Warning "`nThis will squash $currentCount migrations into a single baseline."
        Write-Warning "Old migrations will be moved to migration_archive directory."
        $confirm = Read-Host "`nAre you sure you want to continue? (yes/no)"

        if ($confirm -ne "yes") {
            Write-Info "Aborted by user."
            exit 0
        }
    }

    # Setup directories
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $workDir = "squash_$timestamp"

    if (!(Test-Path $workDir) -and !$DryRun) {
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    }

    $dbBackupFile = Join-Path $workDir "db_backup_$timestamp.dump"
    $schemaFile = Join-Path $workDir "schema_squashed.sql"

    # Execute squash steps
    try {
        # Step 1: Backups
        Backup-Migrations -BackupDir $workDir
        Backup-Database -BackupFile $dbBackupFile

        # Step 2: Export current schema
        Export-SchemaOnly -OutputFile $schemaFile

        # Step 3: Clear and reset
        Remove-OldMigrations
        Clear-FlywayHistory

        # Step 4: Create new baseline
        New-BaselineMigration -SquashedFile $schemaFile
        Set-FlywayBaseline
        Repair-FlywayChecksums

        # Step 5: Verify
        Test-MigrationSquash

        Write-Success "`n========================================"
        Write-Success "  Migration squash completed!"
        Write-Success "========================================`n"

        Write-Info "Backup location: $workDir"
        Write-Info "Archive location: src/main/resources/migration_archive"
        Write-Info "`nNext migration should be: V2__your_description.sql`n"

    } catch {
        Write-Error "`n========================================"
        Write-Error "  Migration squash FAILED!"
        Write-Error "========================================`n"
        Write-Error "Error: $_"
        Write-Info "`nRestore from backup if needed:"
        Write-Info "  pg_restore -h $DbHost -p $DbPort -U $DbUser -d $DbName $dbBackupFile"
        exit 1
    }
}

# Run main function
Main
