--
-- NextDR Supabase Database Schema 
-- NDR-SCHEMA-VERSION: 1.1.10
-- NDR-UPGRADE-FROM: 1.1.9
-- NDR-SCHEMA-TYPE: INCR
-- NDR-FULL-BASELINE-SCHEMA-SHA256: bc2e5bcb91696e4fa61aaef00e760c0c63e59aa10c08673f9a7e227bbf71160e
-- NDR-FULL-UPGRADE-SCHEMA-SHA256: c0c650127737d2e15bb5d4a70959fd6e8379a085b4cfc405770b70c9a0ef9ec4
--

create table "public"."step_execution_messages" (
    "id" uuid not null default gen_random_uuid(),
    "recovery_run_id" bigint not null,
    "step_execution_id" bigint not null,
    "severity" text not null,
    "code" text not null,
    "message" text not null,
    "retryable" boolean not null default false,
    "context" jsonb default '{}'::jsonb,
    "emitted_at" timestamp with time zone not null default now(),
    "created_at" timestamp with time zone not null default now()
);


alter table "public"."step_execution_messages" enable row level security;

alter table "public"."user_license" add column "capacity_limits" jsonb not null default '{}'::jsonb;

alter table "public"."user_license" add column "customer_email" text;

alter table "public"."user_license" add column "expires_at" timestamp with time zone;

alter table "public"."user_license" add column "features" jsonb not null default '{}'::jsonb;

alter table "public"."user_license" add column "license_token" text;

CREATE INDEX idx_step_execution_messages_run_id ON public.step_execution_messages USING btree (recovery_run_id);

CREATE INDEX idx_step_execution_messages_severity ON public.step_execution_messages USING btree (severity);

CREATE INDEX idx_step_execution_messages_step_exec_id ON public.step_execution_messages USING btree (step_execution_id);

CREATE UNIQUE INDEX step_execution_messages_pkey ON public.step_execution_messages USING btree (id);

alter table "public"."step_execution_messages" add constraint "step_execution_messages_pkey" PRIMARY KEY using index "step_execution_messages_pkey";

alter table "public"."step_execution_messages" add constraint "step_execution_messages_recovery_run_id_fkey" FOREIGN KEY (recovery_run_id) REFERENCES recovery_plan_execution(id) ON DELETE CASCADE not valid;

alter table "public"."step_execution_messages" validate constraint "step_execution_messages_recovery_run_id_fkey";

alter table "public"."step_execution_messages" add constraint "step_execution_messages_severity_check" CHECK ((severity = ANY (ARRAY['INFO'::text, 'WARNING'::text, 'ERROR'::text]))) not valid;

alter table "public"."step_execution_messages" validate constraint "step_execution_messages_severity_check";

alter table "public"."step_execution_messages" add constraint "step_execution_messages_step_execution_id_fkey" FOREIGN KEY (step_execution_id) REFERENCES recovery_step_execution(step_execution_id) ON DELETE CASCADE not valid;

alter table "public"."step_execution_messages" validate constraint "step_execution_messages_step_execution_id_fkey";

create policy "Authenticated users can access step_execution_messages"
on "public"."step_execution_messages"
as permissive
for all
to authenticated
using ((role() = 'authenticated'::text))
with check ((role() = 'authenticated'::text));