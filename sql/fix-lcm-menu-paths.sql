-- Fix LCM menu component paths and permission associations in the database
-- Run this against your PostgreSQL database to correct the paths and permissions

-- Fix component paths
UPDATE sys_menus SET component = 'app/lcm/mtls-certificate-request/index.vue'
WHERE component = 'app/lcm/certificate_request/index.vue';

UPDATE sys_menus SET component = 'app/lcm/certificate-job/index.vue'
WHERE component = 'app/lcm/job/index.vue';

UPDATE sys_menus SET component = 'app/lcm/certificate-permission/index.vue'
WHERE component = 'app/lcm/permission/index.vue';

UPDATE sys_menus SET component = 'app/lcm/tenant-secret/index.vue'
WHERE component = 'app/lcm/tenant_secret/index.vue';

UPDATE sys_menus SET component = 'app/lcm/audit-log/index.vue'
WHERE component = 'app/lcm/audit_log/index.vue';

-- Add LCM menu permissions for platform admin (permission_id=2)
-- Use ON CONFLICT to avoid duplicate inserts
INSERT INTO sys_permission_menus (permission_id, menu_id) VALUES
(2, 70), (2, 71), (2, 72), (2, 73), (2, 74), (2, 75), (2, 76), (2, 77)
ON CONFLICT DO NOTHING;
