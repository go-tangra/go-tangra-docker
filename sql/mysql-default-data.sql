-- Description: 初始化默认用户、角色、菜单和API资源数据(MYSQL版)
-- Note: 需要有表结构之后再执行此脚本；执行前备份数据，MySQL需支持JSON字段（5.7+）
DELIMITER // -- 临时修改语句结束符，适配存储过程
SET FOREIGN_KEY_CHECKS = 0; -- 关闭外键检查，允许TRUNCATE关联表
START TRANSACTION; -- 开启事务，保证数据原子性

-- 一次性清理相关表（修复原脚本重复truncate sys_permissions的错误）
TRUNCATE TABLE sys_menus AUTO_INCREMENT = 1;

-- ==============================================
-- 15. 插入后台菜单/目录（JSON字段meta直接适配MySQL）
-- ==============================================
INSERT INTO sys_menus(id, parent_id, type, name, path, redirect, component, status, created_at, meta)
VALUES (1, null, 'CATALOG', 'Dashboard', '/dashboard', null, 'BasicLayout', 'ON', NOW(),
        '{"order":-1, "title":"page.dashboard.title", "icon":"lucide:layout-dashboard", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (2, 1, 'MENU', 'Analytics', 'analytics', null, 'dashboard/analytics/index.vue', 'ON', NOW(),
        '{"order":-1, "title":"page.dashboard.analytics", "icon":"lucide:area-chart", "affixTab": true, "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),

       (10, null, 'CATALOG', 'TenantManagement', '/tenant', null, 'BasicLayout', 'ON', NOW(),
        '{"order":2000, "title":"menu.tenant.moduleName", "icon":"lucide:building-2", "keepAlive":true, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (11, 10, 'MENU', 'TenantMemberManagement', 'tenants', null, 'app/tenant/tenant/index.vue', 'ON', NOW(),
        '{"order":1, "title":"menu.tenant.member", "icon":"lucide:building-2", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),

       (20, null, 'CATALOG', 'OrganizationalPersonnelManagement', '/opm', null, 'BasicLayout', 'ON', NOW(),
        '{"order":2001, "title":"menu.opm.moduleName", "icon":"lucide:users", "keepAlive":true, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (21, 20, 'MENU', 'OrgUnitManagement', 'org-units', null, 'app/opm/org_unit/index.vue', 'ON', NOW(),
        '{"order":1, "title":"menu.opm.orgUnit", "icon":"lucide:building-2", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (22, 20, 'MENU', 'PositionManagement', 'positions', null, 'app/opm/position/index.vue', 'ON', NOW(),
        '{"order":3, "title":"menu.opm.position", "icon":"lucide:briefcase", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (23, 20, 'MENU', 'UserManagement', 'users', null, 'app/opm/users/index.vue', 'ON', NOW(),
        '{"order":4, "title":"menu.opm.user", "icon":"lucide:users", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (24, 20, 'MENU', 'UserDetail', 'users/detail/:id', null, 'app/opm/users/detail/index.vue', 'ON', NOW(),
        '{"order":1, "title":"menu.opm.userDetail", "icon":"", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":true, "hideInTab":false}'),

       (30, null, 'CATALOG', 'PermissionManagement', '/permission', null, 'BasicLayout', 'ON', NOW(),
        '{"order":2002, "title":"menu.permission.moduleName", "icon":"lucide:shield-check", "keepAlive":true, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (31, 30, 'MENU', 'PermissionPointsManagement', 'permissions', null, 'app/permission/permission/index.vue', 'ON', NOW(),
        '{"order":1, "title":"menu.permission.permission", "icon":"lucide:shield-ellipsis", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (32, 30, 'MENU', 'RoleManagement', 'roles', null, 'app/permission/role/index.vue', 'ON', NOW(),
        '{"order":2, "title":"menu.permission.role", "icon":"lucide:shield-user", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (33, 30, 'MENU', 'MenuManagement', 'menus', null, 'app/permission/menu/index.vue', 'ON', NOW(),
        '{"order":3, "title":"menu.permission.menu", "icon":"lucide:square-menu", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (34, 30, 'MENU', 'APIManagement', 'apis', null, 'app/permission/api/index.vue', 'ON', NOW(),
        '{"order":4, "title":"menu.permission.api", "icon":"lucide:route", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),

       (40, null, 'CATALOG', 'InternalMessageManagement', '/internal-message', null, 'BasicLayout', 'ON', NOW(),
        '{"order":2003, "title":"menu.internalMessage.moduleName", "icon":"lucide:mail", "keepAlive":true, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (41, 40, 'MENU', 'InternalMessageList', 'messages', null, 'app/internal_message/message/index.vue', 'ON', NOW(),
        '{"order": 1, "title":"menu.internalMessage.internalMessage", "icon":"lucide:message-circle-more", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (42, 40, 'MENU', 'InternalMessageCategoryManagement', 'categories', null,
        'app/internal_message/category/index.vue', 'ON', NOW(),
        '{"order":2, "title":"menu.internalMessage.internalMessageCategory", "icon":"lucide:calendar-check", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),

       (50, null, 'CATALOG', 'LogAuditManagement', '/log', null, 'BasicLayout', 'ON', NOW(),
        '{"order":2004, "title":"menu.log.moduleName", "icon":"lucide:activity", "keepAlive":true, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (51, 50, 'MENU', 'LoginAuditLog', 'login-audit-logs', null, 'app/log/login_audit_log/index.vue', 'ON', NOW(),
        '{"order":1, "title":"menu.log.loginAuditLog", "icon":"lucide:user-lock", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (52, 50, 'MENU', 'ApiAuditLog', 'api-audit-logs', null, 'app/log/api_audit_log/index.vue', 'ON', NOW(),
        '{"order":2, "title":"menu.log.apiAuditLog", "icon":"lucide:file-clock", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),

       (60, null, 'CATALOG', 'System', '/system', null, 'BasicLayout', 'ON', NOW(),
        '{"order":2005, "title":"menu.system.moduleName", "icon":"lucide:settings", "keepAlive":true, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (61, 60, 'MENU', 'DictManagement', 'dict', null, 'app/system/dict/index.vue', 'ON', NOW(),
        '{"order":1, "title":"menu.system.dict", "icon":"lucide:library-big", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (62, 60, 'MENU', 'FileManagement', 'files', null, 'app/system/files/index.vue', 'ON', NOW(),
        '{"order":2, "title":"menu.system.file", "icon":"lucide:file-search", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (63, 60, 'MENU', 'TaskManagement', 'tasks', null, 'app/system/task/index.vue', 'ON', NOW(),
        '{"order":3, "title":"menu.system.task", "icon":"lucide:list-todo", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (64, 60, 'MENU', 'LoginPolicyManagement', 'login-policies', null,
        'app/system/login_policy/index.vue', 'ON', NOW(),
        '{"order":5, "title":"menu.system.loginPolicy", "icon":"lucide:shield-x", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),

       -- LCM (Certificate Lifecycle Management) Module
       (70, null, 'CATALOG', 'CertificateManagement', '/lcm', null, 'BasicLayout', 'ON', NOW(),
        '{"order":2006, "title":"lcm.menu.moduleName", "icon":"lucide:shield-check", "keepAlive":true, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (71, 70, 'MENU', 'MtlsCertificates', 'certificates', null, 'app/lcm/certificate/index.vue', 'ON', NOW(),
        '{"order":1, "title":"lcm.menu.mtlsCertificate", "icon":"lucide:file-key", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (72, 70, 'MENU', 'CertificateRequests', 'certificate-requests', null, 'app/lcm/mtls-certificate-request/index.vue', 'ON', NOW(),
        '{"order":2, "title":"lcm.menu.mtlsCertificateRequest", "icon":"lucide:file-plus", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (73, 70, 'MENU', 'CertificateJobs', 'jobs', null, 'app/lcm/certificate-job/index.vue', 'ON', NOW(),
        '{"order":3, "title":"lcm.menu.certificateJob", "icon":"lucide:file-check", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (74, 70, 'MENU', 'Issuers', 'issuers', null, 'app/lcm/issuer/index.vue', 'ON', NOW(),
        '{"order":4, "title":"lcm.menu.issuer", "icon":"lucide:building-2", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (75, 70, 'MENU', 'CertificatePermissions', 'permissions', null, 'app/lcm/certificate-permission/index.vue', 'ON', NOW(),
        '{"order":5, "title":"lcm.menu.certificatePermission", "icon":"lucide:key", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (76, 70, 'MENU', 'TenantSecrets', 'tenant-secrets', null, 'app/lcm/tenant-secret/index.vue', 'ON', NOW(),
        '{"order":6, "title":"lcm.menu.tenantSecret", "icon":"lucide:lock", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),
       (77, 70, 'MENU', 'LcmAuditLogs', 'audit-logs', null, 'app/lcm/audit-log/index.vue', 'ON', NOW(),
        '{"order":7, "title":"lcm.menu.auditLog", "icon":"lucide:file-clock", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false}'),

       -- Deployer (Certificate Deployment) Module
       (80, null, 'CATALOG', 'CertificateDeployment', '/deployer', null, 'BasicLayout', 'ON', NOW(),
        '{"order":2007, "title":"deployer.menu.moduleName", "icon":"lucide:rocket", "keepAlive":true, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false, "authority":["platform:admin", "tenant:manager"]}'),
       (81, 80, 'MENU', 'DeploymentTargets', 'targets', null, 'app/deployer/target/index.vue', 'ON', NOW(),
        '{"order":1, "title":"deployer.menu.target", "icon":"lucide:target", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false, "authority":["platform:admin", "tenant:manager"]}'),
       (82, 80, 'MENU', 'DeploymentJobs', 'jobs', null, 'app/deployer/job/index.vue', 'ON', NOW(),
        '{"order":2, "title":"deployer.menu.job", "icon":"lucide:briefcase", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false, "authority":["platform:admin", "tenant:manager"]}'),

       -- Warden (Secret Management) Module
       (90, null, 'CATALOG', 'SecretManagement', '/warden', null, 'BasicLayout', 'ON', NOW(),
        '{"order":2010, "title":"warden.menu.warden", "icon":"lucide:key-round", "keepAlive":true, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false, "authority":["platform:admin", "tenant:manager"]}'),
       (91, 90, 'MENU', 'WardenSecrets', 'secrets', null, 'app/warden/folder/index.vue', 'ON', NOW(),
        '{"order":1, "title":"warden.menu.secrets", "icon":"lucide:lock", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false, "authority":["platform:admin", "tenant:manager"]}'),
       (92, 90, 'MENU', 'WardenSearch', 'search', null, 'app/warden/secret/index.vue', 'ON', NOW(),
        '{"order":2, "title":"warden.menu.search", "icon":"lucide:search", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false, "authority":["platform:admin", "tenant:manager"]}'),

       -- IPAM (IP Address Management) Module
       (100, null, 'CATALOG', 'IPAM', '/ipam', null, 'BasicLayout', 'ON', NOW(),
        '{"order":2011, "title":"ipam.menu.moduleName", "icon":"lucide:network", "keepAlive":true, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false, "authority":["platform:admin", "tenant:manager"]}'),
       (101, 100, 'MENU', 'IpamSubnets', 'subnets', null, 'app/ipam/subnet/index.vue', 'ON', NOW(),
        '{"order":1, "title":"ipam.menu.subnet", "icon":"lucide:git-branch", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false, "authority":["platform:admin", "tenant:manager"]}'),
       (102, 100, 'MENU', 'IpamAddresses', 'ip-addresses', null, 'app/ipam/ip-address/index.vue', 'ON', NOW(),
        '{"order":2, "title":"ipam.menu.ipAddress", "icon":"lucide:hash", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false, "authority":["platform:admin", "tenant:manager"]}'),
       (103, 100, 'MENU', 'IpamVlans', 'vlans', null, 'app/ipam/vlan/index.vue', 'ON', NOW(),
        '{"order":3, "title":"ipam.menu.vlan", "icon":"lucide:layers", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false, "authority":["platform:admin", "tenant:manager"]}'),
       (104, 100, 'MENU', 'IpamDevices', 'devices', null, 'app/ipam/device/index.vue', 'ON', NOW(),
        '{"order":4, "title":"ipam.menu.device", "icon":"lucide:server", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false, "authority":["platform:admin", "tenant:manager"]}'),
       (105, 100, 'MENU', 'IpamLocations', 'locations', null, 'app/ipam/location/index.vue', 'ON', NOW(),
        '{"order":5, "title":"ipam.menu.location", "icon":"lucide:map-pin", "keepAlive":false, "hideInBreadcrumb":false, "hideInMenu":false, "hideInTab":false, "authority":["platform:admin", "tenant:manager"]}');
ALTER TABLE sys_menus AUTO_INCREMENT = (SELECT MAX(id) + 1 FROM sys_menus);

-- Add LCM menu permissions for platform admin (permission_id=2)
-- This ensures LCM menus are visible to platform admins
INSERT IGNORE INTO sys_permission_menus (permission_id, menu_id)
VALUES (2, 70), (2, 71), (2, 72), (2, 73), (2, 74), (2, 75), (2, 76), (2, 77);

-- Add Deployer menu permissions for platform admin (permission_id=2) and tenant manager (permission_id=3)
INSERT IGNORE INTO sys_permission_menus (permission_id, menu_id)
VALUES (2, 80), (2, 81), (2, 82),  -- platform:admin
       (3, 80), (3, 81), (3, 82);  -- tenant:manager

-- Add Warden menu permissions for platform admin (permission_id=2) and tenant manager (permission_id=3)
INSERT IGNORE INTO sys_permission_menus (permission_id, menu_id)
VALUES (2, 90), (2, 91), (2, 92),  -- platform:admin
       (3, 90), (3, 91), (3, 92);  -- tenant:manager

-- Add IPAM menu permissions for platform admin (permission_id=2) and tenant manager (permission_id=3)
INSERT IGNORE INTO sys_permission_menus (permission_id, menu_id)
VALUES (2, 100), (2, 101), (2, 102), (2, 103), (2, 104), (2, 105),  -- platform:admin
       (3, 100), (3, 101), (3, 102), (3, 103), (3, 104), (3, 105);  -- tenant:manager

-- 事务提交+恢复外键检查+还原语句结束符
COMMIT;
SET FOREIGN_KEY_CHECKS = 1;
DELIMITER ;
