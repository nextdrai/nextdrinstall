--
-- NextDR Supabase Database Schema 
-- NDR-SCHEMA-VERSION: 1.1.8
-- NDR-UPGRADE-FROM: 1.1.7
-- NDR-SCHEMA-TYPE: INCR
-- NDR-FULL-BASELINE-SCHEMA-SHA256: a014ddade1f0a50fe4857374b544b02d12671e796f0ce1fa2a5fd2d9720d853c
-- NDR-FULL-UPGRADE-SCHEMA-SHA256: cbb394d173fea07cfbc94ed814af41cf8fcf5a822c80d0bb80dd87ad2ea7ed35
--

create type "public"."app_action" as enum ('read', 'create', 'update', 'delete', 'execute', 'approve', 'manual_step', 'verify', 'manage');

create type "public"."app_resource" as enum ('dashboard', 'datacenter', 'applications', 'recovery_plans', 'settings', 'license');

create type "public"."app_role" as enum ('admin', 'operator', 'approver', 'viewer');

drop trigger if exists "add_license_after_profile_insert" on "public"."user_profiles";

alter table "public"."application_groups" drop constraint "application_groups_project_id_fkey";

alter table "public"."datacenters2" drop constraint "datacenters2_project_id_key";

drop index if exists "public"."datacenters2_project_id_key";

create table "public"."enrichment_audit_log" (
    "id" uuid not null default gen_random_uuid(),
    "tenant_user_id" uuid not null,
    "plan_id" uuid not null,
    "generation_id" uuid not null,
    "step_id" uuid,
    "call_type" text not null,
    "provider_type" text not null,
    "model" text not null,
    "prompt_token_count" integer,
    "completion_token_count" integer,
    "total_token_count" integer,
    "latency_ms" integer,
    "repair_attempted" boolean not null default false,
    "fallback_used" boolean not null default false,
    "status" text not null,
    "error_summary" text,
    "created_at" timestamp with time zone not null default now()
);


alter table "public"."enrichment_audit_log" enable row level security;

create table "public"."recovery_plan_step_generations" (
    "id" uuid not null default gen_random_uuid(),
    "plan_id" uuid not null,
    "app_group_id" bigint not null,
    "backup_run_id" uuid not null,
    "approval_phases" jsonb not null default '[]'::jsonb,
    "status" text not null default 'queued'::text,
    "error" text,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
);


alter table "public"."recovery_plan_step_generations" enable row level security;

create table "public"."recovery_step_dependencies" (
    "id" uuid not null default gen_random_uuid(),
    "plan_id" uuid not null,
    "generation_id" uuid not null,
    "step_id" uuid not null,
    "depends_on_step_id" uuid not null,
    "dependency_type" text not null default 'requires'::text,
    "created_at" timestamp with time zone not null default now()
);


alter table "public"."recovery_step_dependencies" enable row level security;

create table "public"."resource_backup_mode_result" (
    "id" uuid not null default gen_random_uuid(),
    "resource_backup_id" uuid not null,
    "backup_mode" text not null,
    "preflight_status" text not null default 'pending'::text,
    "preflight_details" jsonb,
    "execution_status" text not null default 'pending'::text,
    "external_backup_id" text,
    "artifact_meta" jsonb,
    "error_code" text,
    "error_message" text,
    "started_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
);


alter table "public"."resource_backup_mode_result" enable row level security;

create table "public"."role_permissions" (
    "role" app_role not null,
    "resource" app_resource not null,
    "action" app_action not null,
    "allowed" boolean not null default true,
    "created_at" timestamp with time zone not null default now()
);


alter table "public"."role_permissions" enable row level security;

alter table "public"."recovery_plans_new" add column "ai_summary" text;

alter table "public"."recovery_plans_new" add column "estimated_total_minutes" integer;

alter table "public"."recovery_plans_new" add column "region_quota_fallback_enabled" boolean not null default false;

alter table "public"."recovery_plans_new" add column "rto_achievable" boolean;

alter table "public"."recovery_plans_new" add column "rto_risk_message" text;

alter table "public"."recovery_steps_new" add column "estimated_duration_minutes" integer;

alter table "public"."recovery_steps_new" add column "prechecks" jsonb;

alter table "public"."recovery_steps_new" add column "resource_id" text;

alter table "public"."recovery_steps_new" add column "risks" jsonb;

alter table "public"."recovery_steps_new" add column "rollback_instructions" text;

alter table "public"."recovery_steps_new" add column "suggested_assignee" text;

alter table "public"."recovery_steps_new" add column "updated_at" timestamp with time zone not null default now();

alter table "public"."recovery_steps_new" add column "validation_checks" jsonb;

alter table "public"."resource_backup" add column "overall_status" text;

alter table "public"."resource_backup" add column "selected_modes" text[];

CREATE UNIQUE INDEX datacenters2_project_id_notnull_key ON public.datacenters2 USING btree (project_id) WHERE (project_id IS NOT NULL);

CREATE UNIQUE INDEX enrichment_audit_log_pkey ON public.enrichment_audit_log USING btree (id);

CREATE INDEX idx_enrichment_audit_log_generation ON public.enrichment_audit_log USING btree (generation_id);

CREATE INDEX idx_enrichment_audit_log_plan ON public.enrichment_audit_log USING btree (plan_id);

CREATE INDEX idx_enrichment_audit_log_tenant ON public.enrichment_audit_log USING btree (tenant_user_id, created_at DESC);

CREATE INDEX idx_rbmr_backup_mode ON public.resource_backup_mode_result USING btree (backup_mode);

CREATE INDEX idx_rbmr_external_backup_id ON public.resource_backup_mode_result USING btree (external_backup_id);

CREATE INDEX idx_rbmr_mode_status_completed ON public.resource_backup_mode_result USING btree (backup_mode, execution_status, completed_at DESC);

CREATE INDEX idx_rbmr_resource_backup_id ON public.resource_backup_mode_result USING btree (resource_backup_id);

CREATE INDEX idx_recovery_plan_step_generations_plan_id ON public.recovery_plan_step_generations USING btree (plan_id);

CREATE INDEX idx_recovery_plan_step_generations_status ON public.recovery_plan_step_generations USING btree (plan_id, status) WHERE (status = 'generating'::text);

CREATE INDEX idx_resource_backup_resource_id ON public.resource_backup USING btree (resource_id);

CREATE INDEX idx_rsd_depends_on ON public.recovery_step_dependencies USING btree (depends_on_step_id);

CREATE INDEX idx_rsd_plan_generation ON public.recovery_step_dependencies USING btree (plan_id, generation_id);

CREATE INDEX idx_rsd_step_id ON public.recovery_step_dependencies USING btree (step_id);

CREATE UNIQUE INDEX rbmr_pkey ON public.resource_backup_mode_result USING btree (id);

CREATE UNIQUE INDEX rbmr_unique_mode_per_backup ON public.resource_backup_mode_result USING btree (resource_backup_id, backup_mode);

CREATE UNIQUE INDEX recovery_plan_step_generations_pkey ON public.recovery_plan_step_generations USING btree (id);

CREATE UNIQUE INDEX recovery_step_dependencies_pkey ON public.recovery_step_dependencies USING btree (id);

CREATE UNIQUE INDEX recovery_step_dependencies_step_id_depends_on_step_id_key ON public.recovery_step_dependencies USING btree (step_id, depends_on_step_id);

CREATE UNIQUE INDEX role_permissions_pkey ON public.role_permissions USING btree (role, resource, action);

alter table "public"."enrichment_audit_log" add constraint "enrichment_audit_log_pkey" PRIMARY KEY using index "enrichment_audit_log_pkey";

alter table "public"."recovery_plan_step_generations" add constraint "recovery_plan_step_generations_pkey" PRIMARY KEY using index "recovery_plan_step_generations_pkey";

alter table "public"."recovery_step_dependencies" add constraint "recovery_step_dependencies_pkey" PRIMARY KEY using index "recovery_step_dependencies_pkey";

alter table "public"."resource_backup_mode_result" add constraint "rbmr_pkey" PRIMARY KEY using index "rbmr_pkey";

alter table "public"."role_permissions" add constraint "role_permissions_pkey" PRIMARY KEY using index "role_permissions_pkey";

alter table "public"."datacenters2" add constraint "datacenters2_hypervisor_type_check" CHECK ((hypervisor_type = ANY (ARRAY['GCP'::text, 'GENERIC'::text]))) not valid;

alter table "public"."datacenters2" validate constraint "datacenters2_hypervisor_type_check";

alter table "public"."enrichment_audit_log" add constraint "enrichment_audit_log_call_type_check" CHECK ((call_type = ANY (ARRAY['step_enrichment'::text, 'plan_summary'::text]))) not valid;

alter table "public"."enrichment_audit_log" validate constraint "enrichment_audit_log_call_type_check";

alter table "public"."enrichment_audit_log" add constraint "enrichment_audit_log_generation_id_fkey" FOREIGN KEY (generation_id) REFERENCES recovery_plan_step_generations(id) ON DELETE CASCADE not valid;

alter table "public"."enrichment_audit_log" validate constraint "enrichment_audit_log_generation_id_fkey";

alter table "public"."enrichment_audit_log" add constraint "enrichment_audit_log_status_check" CHECK ((status = ANY (ARRAY['success'::text, 'parse_failed'::text, 'secret_rejected'::text, 'db_write_failed'::text, 'provider_error'::text]))) not valid;

alter table "public"."enrichment_audit_log" validate constraint "enrichment_audit_log_status_check";

alter table "public"."enrichment_audit_log" add constraint "enrichment_audit_log_step_id_fkey" FOREIGN KEY (step_id) REFERENCES recovery_steps_new(id) ON DELETE SET NULL not valid;

alter table "public"."enrichment_audit_log" validate constraint "enrichment_audit_log_step_id_fkey";

alter table "public"."enrichment_audit_log" add constraint "enrichment_audit_log_tenant_user_id_fkey" FOREIGN KEY (tenant_user_id) REFERENCES auth.users(id) ON DELETE CASCADE not valid;

alter table "public"."enrichment_audit_log" validate constraint "enrichment_audit_log_tenant_user_id_fkey";

alter table "public"."recovery_plan_step_generations" add constraint "recovery_plan_step_generations_status_check" CHECK ((status = ANY (ARRAY['queued'::text, 'generating'::text, 'completed'::text, 'failed'::text]))) not valid;

alter table "public"."recovery_plan_step_generations" validate constraint "recovery_plan_step_generations_status_check";

alter table "public"."recovery_step_dependencies" add constraint "no_self_dependency" CHECK ((step_id <> depends_on_step_id)) not valid;

alter table "public"."recovery_step_dependencies" validate constraint "no_self_dependency";

alter table "public"."recovery_step_dependencies" add constraint "recovery_step_dependencies_dependency_type_check" CHECK ((dependency_type = ANY (ARRAY['requires'::text, 'soft_requires'::text, 'approval_gate'::text]))) not valid;

alter table "public"."recovery_step_dependencies" validate constraint "recovery_step_dependencies_dependency_type_check";

alter table "public"."recovery_step_dependencies" add constraint "recovery_step_dependencies_depends_on_step_id_fkey" FOREIGN KEY (depends_on_step_id) REFERENCES recovery_steps_new(id) ON DELETE CASCADE not valid;

alter table "public"."recovery_step_dependencies" validate constraint "recovery_step_dependencies_depends_on_step_id_fkey";

alter table "public"."recovery_step_dependencies" add constraint "recovery_step_dependencies_generation_id_fkey" FOREIGN KEY (generation_id) REFERENCES recovery_plan_step_generations(id) ON DELETE CASCADE not valid;

alter table "public"."recovery_step_dependencies" validate constraint "recovery_step_dependencies_generation_id_fkey";

alter table "public"."recovery_step_dependencies" add constraint "recovery_step_dependencies_plan_id_fkey" FOREIGN KEY (plan_id) REFERENCES recovery_plans_new(id) ON DELETE CASCADE not valid;

alter table "public"."recovery_step_dependencies" validate constraint "recovery_step_dependencies_plan_id_fkey";

alter table "public"."recovery_step_dependencies" add constraint "recovery_step_dependencies_step_id_depends_on_step_id_key" UNIQUE using index "recovery_step_dependencies_step_id_depends_on_step_id_key";

alter table "public"."recovery_step_dependencies" add constraint "recovery_step_dependencies_step_id_fkey" FOREIGN KEY (step_id) REFERENCES recovery_steps_new(id) ON DELETE CASCADE not valid;

alter table "public"."recovery_step_dependencies" validate constraint "recovery_step_dependencies_step_id_fkey";

alter table "public"."resource_backup" add constraint "resource_backup_overall_status_check" CHECK (((overall_status IS NULL) OR (overall_status = ANY (ARRAY['in_progress'::text, 'completed'::text, 'failed'::text])))) not valid;

alter table "public"."resource_backup" validate constraint "resource_backup_overall_status_check";

alter table "public"."resource_backup_mode_result" add constraint "rbmr_backup_mode_check" CHECK ((backup_mode = ANY (ARRAY['db_export'::text, 'local_snapshot'::text, 'enhanced_backup'::text]))) not valid;

alter table "public"."resource_backup_mode_result" validate constraint "rbmr_backup_mode_check";

alter table "public"."resource_backup_mode_result" add constraint "rbmr_execution_status_check" CHECK ((execution_status = ANY (ARRAY['pending'::text, 'skipped'::text, 'succeeded'::text, 'failed'::text]))) not valid;

alter table "public"."resource_backup_mode_result" validate constraint "rbmr_execution_status_check";

alter table "public"."resource_backup_mode_result" add constraint "rbmr_preflight_status_check" CHECK ((preflight_status = ANY (ARRAY['pending'::text, 'skipped'::text, 'succeeded'::text, 'failed'::text]))) not valid;

alter table "public"."resource_backup_mode_result" validate constraint "rbmr_preflight_status_check";

alter table "public"."resource_backup_mode_result" add constraint "rbmr_resource_backup_id_fkey" FOREIGN KEY (resource_backup_id) REFERENCES resource_backup(id) ON DELETE CASCADE not valid;

alter table "public"."resource_backup_mode_result" validate constraint "rbmr_resource_backup_id_fkey";

alter table "public"."resource_backup_mode_result" add constraint "rbmr_unique_mode_per_backup" UNIQUE using index "rbmr_unique_mode_per_backup";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.authorize(p_resource app_resource, p_action app_action)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
    from public.user_profiles up
    join public.role_permissions rp on rp.role = up.role::public.app_role
    where up.id = auth.uid()
      and up.status = 'active'
      and rp.resource = p_resource
      and rp.allowed = true
      and (rp.action = p_action or rp.action = 'manage'::public.app_action)
  );
$function$
;

CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    claims jsonb;
    v_role public.app_role;
BEGIN
    SELECT role
      INTO v_role
    FROM public.user_profiles
    WHERE id = (event->>'user_id')::uuid
      AND status = 'active';

    claims := COALESCE(event->'claims', '{}'::jsonb);
    IF v_role IS NOT NULL THEN
        claims := jsonb_set(claims, '{app_role}', to_jsonb(v_role::text), true);
    END IF;

    RETURN jsonb_set(event, '{claims}', claims, true);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.seed_initial_admin(p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    UPDATE public.user_profiles
    SET role = 'admin',
        updated_at = now()
    WHERE id = p_user_id;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.updated_at = now();
  return new;
end;
$function$
;

create policy "Users can view own enrichment audit rows"
on "public"."enrichment_audit_log"
as permissive
for select
to public
using ((tenant_user_id = uid()));


create policy "rbac_recovery_plans_select"
on "public"."recovery_plans"
as permissive
for select
to authenticated
using (authorize('recovery_plans'::app_resource, 'read'::app_action));


create policy "authenticated can read role permissions"
on "public"."role_permissions"
as permissive
for select
to authenticated
using (true);


create policy "settings managers can modify role permissions"
on "public"."role_permissions"
as permissive
for all
to authenticated
using (authorize('settings'::app_resource, 'manage'::app_action))
with check (authorize('settings'::app_resource, 'manage'::app_action));


create policy "rbac_smtp_settings_modify"
on "public"."smtp_settings"
as permissive
for all
to authenticated
using (authorize('settings'::app_resource, 'manage'::app_action))
with check (authorize('settings'::app_resource, 'manage'::app_action));


create policy "rbac_smtp_settings_select"
on "public"."smtp_settings"
as permissive
for select
to authenticated
using (authorize('settings'::app_resource, 'read'::app_action));


CREATE TRIGGER trg_recovery_steps_new_updated_at BEFORE UPDATE ON public.recovery_steps_new FOR EACH ROW EXECUTE FUNCTION set_updated_at();