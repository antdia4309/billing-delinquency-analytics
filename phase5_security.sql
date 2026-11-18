-- =====================================================================
-- Billing Delinquency Analytics - Phase 5: Roles and authorization
-- Roles, schemes, and assignments are configured in APEX, not with DDL.
-- This file documents the setup and holds the verification queries.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 21. Setup (APEX Shared Components)
-- ---------------------------------------------------------------------
-- Application Access Control -> Roles
--   Collector  (static ID: collector)  - works the collections queue
--   Manager    (static ID: manager)    - oversees notices and batch jobs
--   Note: APEX stores static IDs in lowercase. The built-in
--   "Is In Role or Group" scheme type matches on role NAME, so case
--   doesn't matter there; a hand-written PL/SQL check would need the
--   lowercase static ID.
--
-- Application Access Control -> User Role Assignments
--   COLLECTOR_DEMO   -> Collector
--   <your login>     -> Collector, Manager
--   (Assignments are not included in the app export; recreate them
--    after importing.)
--
-- Authorization Schemes (type: Is In Role or Group, Application Role,
-- validated once per page view)
--   Manager               -> Manager
--   Collector or Manager  -> Collector, Manager
--
-- Where they're applied:
--   Pages 5, 6, 7, 8 ............ Collector or Manager
--   Page 9 (Batch Runs) ......... Manager
--   Menu: Collections Queue, Dunning Notices -> Collector or Manager
--   Menu: Batch Runs ............ Manager
--   Page 8 GENERATE button ...... Manager
--   Page 8 "Generate notices" process ... Manager   <- the real control
--   Page 6 Audit History region . Manager
--   Page 6 refresh actions targeting Audit History ... Manager
--   Page 6 Contact History grid: delete operation ... Manager
--   Navigation Bar: Sign In entry, shown only to the public user


-- ---------------------------------------------------------------------
-- 22. Verification queries
-- ---------------------------------------------------------------------
-- Role assignments:
SELECT user_name, role_static_id
FROM   apex_appl_acl_user_roles
WHERE  application_id = 188112
ORDER  BY user_name, role_static_id;

-- Every page and region with an authorization scheme:
SELECT 'Page'   AS component, page_id, page_name AS name, authorization_scheme
FROM   apex_application_pages
WHERE  application_id = 188112 AND authorization_scheme IS NOT NULL
UNION ALL
SELECT 'Region', page_id, region_name, authorization_scheme
FROM   apex_application_page_regions
WHERE  application_id = 188112 AND authorization_scheme IS NOT NULL
ORDER  BY 2, 1;

-- Navigation menu entries and their schemes (this is how the unsaved
-- menu settings were caught):
SELECT list_name, entry_text, authorization_scheme
FROM   apex_application_list_entries
WHERE  application_id = 188112
ORDER  BY list_name, display_sequence;


-- ---------------------------------------------------------------------
-- 23. Security tests (run as COLLECTOR_DEMO)
-- ---------------------------------------------------------------------
-- 1. Menu: Batch Runs is not listed.
-- 2. URL attack: change the page alias in the URL to batch-runs
--    -> "You need the Manager role to do that. Access denied by Page
--       security check."
-- 3. Console attack: on Dunning Notices, run apex.submit('GENERATE')
--    in the browser console -> the page reloads with no
--    "notices created" message; the process's authorization stops it.
-- 4. Page 6: no Audit History region; the grid row menu has no
--    Delete Row.
-- 5. As a manager, Generate Notices still works.
