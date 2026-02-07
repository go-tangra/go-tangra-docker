-- Deployer Module Refactoring Migration
-- This script migrates the deployer module from single-target architecture
-- to multi-configuration target groups.

-- Migration Plan:
-- 1. Create new deployer_target_configs table (from existing deployer_targets)
-- 2. Create new deployer_targets table (groups)
-- 3. Create deployer_target_configurations junction table
-- 4. Migrate data
-- 5. Update deployer_jobs table structure

-- =============================================================================
-- Step 1: Rename deployer_targets to deployer_target_configs
-- =============================================================================

-- Rename the existing table
ALTER TABLE deployer_targets RENAME TO deployer_target_configs;

-- Rename status enum values from TARGET_STATUS to CONFIG_STATUS
-- Note: In PostgreSQL, we need to update the enum type or do string replacement
-- This depends on the database being used. For PostgreSQL:
UPDATE deployer_target_configs SET status = REPLACE(status, 'TARGET_STATUS', 'CONFIG_STATUS');

-- =============================================================================
-- Step 2: Create new deployer_targets table (for groups)
-- =============================================================================

CREATE TABLE deployer_targets (
    id VARCHAR(36) PRIMARY KEY,
    tenant_id INT NOT NULL,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    auto_deploy_on_renewal BOOLEAN DEFAULT FALSE,
    certificate_filters JSONB,
    create_by INT,
    update_by INT,
    create_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    update_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(tenant_id, name)
);

-- Create indexes
CREATE INDEX idx_deployer_targets_tenant_id ON deployer_targets(tenant_id);
CREATE INDEX idx_deployer_targets_auto_deploy ON deployer_targets(auto_deploy_on_renewal);

-- =============================================================================
-- Step 3: Create junction table for M:N relationship
-- =============================================================================

CREATE TABLE deployer_target_configurations (
    deployment_target_id VARCHAR(36) NOT NULL,
    target_configuration_id VARCHAR(36) NOT NULL,
    PRIMARY KEY (deployment_target_id, target_configuration_id),
    FOREIGN KEY (deployment_target_id) REFERENCES deployer_targets(id) ON DELETE CASCADE,
    FOREIGN KEY (target_configuration_id) REFERENCES deployer_target_configs(id) ON DELETE CASCADE
);

-- =============================================================================
-- Step 4: Migrate data - Create one group per existing config
-- =============================================================================

-- Insert one deployment target group for each existing config
INSERT INTO deployer_targets (id, tenant_id, name, description, auto_deploy_on_renewal, certificate_filters, create_by, update_by, create_time, update_time)
SELECT
    CONCAT(SUBSTRING(id, 1, 28), 'group'), -- Generate a related ID for the group
    tenant_id,
    CONCAT(name, ' (Group)'),
    description,
    auto_deploy_on_renewal,
    certificate_filters,
    create_by,
    update_by,
    create_time,
    update_time
FROM deployer_target_configs;

-- Create links between migrated groups and configs
INSERT INTO deployer_target_configurations (deployment_target_id, target_configuration_id)
SELECT
    CONCAT(SUBSTRING(dtc.id, 1, 28), 'group'),
    dtc.id
FROM deployer_target_configs dtc;

-- =============================================================================
-- Step 5: Update deployer_target_configs - Remove migrated columns
-- =============================================================================

-- Remove columns that moved to deployer_targets
ALTER TABLE deployer_target_configs DROP COLUMN IF EXISTS auto_deploy_on_renewal;
ALTER TABLE deployer_target_configs DROP COLUMN IF EXISTS certificate_filters;

-- =============================================================================
-- Step 6: Update deployer_jobs table structure
-- =============================================================================

-- Add new columns
ALTER TABLE deployer_jobs ADD COLUMN deployment_target_id VARCHAR(36);
ALTER TABLE deployer_jobs ADD COLUMN target_configuration_id VARCHAR(36);
ALTER TABLE deployer_jobs ADD COLUMN parent_job_id VARCHAR(36);

-- Add new status value for partial completion
-- This may need adjustment based on your database enum handling

-- Migrate existing target_id to target_configuration_id
UPDATE deployer_jobs SET target_configuration_id = target_id;

-- Create indexes for new columns
CREATE INDEX idx_deployer_jobs_deployment_target_id ON deployer_jobs(deployment_target_id);
CREATE INDEX idx_deployer_jobs_target_configuration_id ON deployer_jobs(target_configuration_id);
CREATE INDEX idx_deployer_jobs_parent_job_id ON deployer_jobs(parent_job_id);

-- Add foreign keys (optional - may be done by ENT)
-- ALTER TABLE deployer_jobs ADD FOREIGN KEY (deployment_target_id) REFERENCES deployer_targets(id);
-- ALTER TABLE deployer_jobs ADD FOREIGN KEY (target_configuration_id) REFERENCES deployer_target_configs(id);
-- ALTER TABLE deployer_jobs ADD FOREIGN KEY (parent_job_id) REFERENCES deployer_jobs(id);

-- Drop old target_id column after migration is verified
-- ALTER TABLE deployer_jobs DROP COLUMN target_id;

-- =============================================================================
-- Cleanup (run after verifying migration)
-- =============================================================================

-- Uncomment to finalize migration:
-- DROP INDEX IF EXISTS idx_deployer_jobs_target_id;
-- ALTER TABLE deployer_jobs DROP COLUMN target_id;

-- =============================================================================
-- Rollback script (if needed)
-- =============================================================================

-- To rollback:
-- 1. DROP TABLE deployer_target_configurations;
-- 2. DROP TABLE deployer_targets;
-- 3. ALTER TABLE deployer_target_configs RENAME TO deployer_targets;
-- 4. ALTER TABLE deployer_jobs DROP COLUMN deployment_target_id;
-- 5. ALTER TABLE deployer_jobs DROP COLUMN target_configuration_id;
-- 6. ALTER TABLE deployer_jobs DROP COLUMN parent_job_id;
-- 7. Restore auto_deploy_on_renewal and certificate_filters columns
