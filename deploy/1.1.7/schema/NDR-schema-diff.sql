--
-- NextDR Supabase Database Schema 
-- NDR-SCHEMA-VERSION: 1.1.7
-- NDR-UPGRADE-FROM: 1.1.6
-- NDR-SCHEMA-TYPE: INCR
-- NDR-FULL-BASELINE-SCHEMA-SHA256: 2d0680a79c3f1c85d7c1d291912bf222dcc9033ad5d6c64be1040cf0f631e16d
-- NDR-FULL-UPGRADE-SCHEMA-SHA256: a014ddade1f0a50fe4857374b544b02d12671e796f0ce1fa2a5fd2d9720d853c
--

alter table "public"."datacenters2" add column "manual_snapshot_cleanup" boolean not null default false;