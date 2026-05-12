--
-- NextDR Supabase Database Schema
-- NDR-SCHEMA-VERSION: 1.1.7
-- NDR-UPGRADE-FROM: 0.0.0
-- NDR-SCHEMA-TYPE: FULL
--

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: app_role; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.app_role AS ENUM (
    'admin',
    'operator',
    'approver',
    'viewer'
);


--
-- Name: app_resource; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.app_resource AS ENUM (
    'dashboard',
    'datacenter',
    'applications',
    'recovery_plans',
    'settings',
    'license'
);


--
-- Name: app_action; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.app_action AS ENUM (
    'read',
    'create',
    'update',
    'delete',
    'execute',
    'approve',
    'manual_step',
    'verify',
    'manage'
);


--
-- Name: pricing_plan_interval; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.pricing_plan_interval AS ENUM (
    'day',
    'week',
    'month',
    'year'
);


--
-- Name: pricing_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.pricing_type AS ENUM (
    'one_time',
    'recurring'
);


--
-- Name: subscription_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.subscription_status AS ENUM (
    'trialing',
    'active',
    'canceled',
    'incomplete',
    'incomplete_expired',
    'past_due',
    'unpaid'
);


--
-- Name: check_step_approval(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_step_approval(step_id uuid) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM recovery_steps_new
        WHERE id = step_id
        AND requires_approval = true
        AND (
            approval_metadata->>'approval_status' IS NULL
            OR approval_metadata->>'approval_status' = 'pending'
        )
    );
END;
$$;

--
-- Name: create_user_license_on_profile_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_user_license_on_profile_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- Insert a new license row with the same ID as the profile
  INSERT INTO public.user_license (id, license_key, "isActive")
  VALUES (NEW.id, NULL, FALSE);

  RETURN NEW;
END;
$$;

--
-- Name: ensure_user_profiles(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ensure_user_profiles() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$BEGIN
    INSERT INTO user_profiles (id, email, role)
    SELECT id, email, 'viewer'
    FROM auth.users u
    WHERE NOT EXISTS (
        SELECT 1 FROM user_profiles p WHERE p.id = u.id
    );
END;$$;


--
-- Name: handle_new_user(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_new_user() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$BEGIN
    -- Check if profile already exists
    IF NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE id = NEW.id) THEN
        INSERT INTO public.user_profiles (id, email, role)
        VALUES (NEW.id, NEW.email, 'admin');
    END IF;
    RETURN NEW;
END;$$;


--
-- Name: handle_user_deletion(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_user_deletion() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    -- Log the deletion in an audit table if needed
    -- For now, we'll just let the CASCADE handle the user_profiles deletion
    RETURN OLD;
END;
$$;


--
-- Name: is_admin(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_admin(user_id uuid) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $_$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = $1 AND role = 'admin'
  );
END;
$_$;


--
-- Name: log_license_action(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_license_action() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  insert into license_logs (license_id, action, metadata)
  values (
    new.id,
    case
      when new.status != old.status then 'status_change'
      when new.usage_count > old.usage_count then 'usage'
      else 'update'
    end,
    jsonb_build_object(
      'old_status', old.status,
      'new_status', new.status,
      'old_usage_count', old.usage_count,
      'new_usage_count', new.usage_count
    )
  );
  return new;
end;
$$;


--
-- Name: log_user_action(text, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_user_action(action text, entity_id uuid, details jsonb DEFAULT '{}'::jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    log_id UUID;
BEGIN
    INSERT INTO audit_logs (
        user_id,
        action,
        entity_type,
        entity_id,
        details
    )
    VALUES (
        auth.uid(),
        action,
        'user',
        entity_id,
        details
    )
    RETURNING id INTO log_id;
    
    RETURN log_id;
END;
$$;


--
-- Name: log_user_profile_deletion(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_user_profile_deletion() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    PERFORM public.log_user_action(
        'user_deleted',
        OLD.id,
        jsonb_build_object(
            'email', OLD.email,
            'role', OLD.role,
            'status', OLD.status
        )
    );
    RETURN OLD;
END;
$$;


--
-- Name: log_user_profile_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_user_profile_update() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    IF OLD.role != NEW.role THEN
        PERFORM public.log_user_action(
            'role_update',
            NEW.id,
            jsonb_build_object(
                'old_role', OLD.role,
                'new_role', NEW.role
            )
        );
    END IF;

    IF OLD.status != NEW.status THEN
        PERFORM public.log_user_action(
            'status_update',
            NEW.id,
            jsonb_build_object(
                'old_status', OLD.status,
                'new_status', NEW.status
            )
        );
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: resolve_step_assignees(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resolve_step_assignees(step_id uuid) RETURNS TABLE(user_id uuid, email text, role text, status text)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    WITH step_info AS (
        SELECT assignee_type, assignee_id
        FROM recovery_steps_new
        WHERE id = step_id
    )
    SELECT 
        u.id as user_id,
        u.email,
        p.role,
        p.status
    FROM step_info s
    LEFT JOIN LATERAL (
        SELECT id, email, role, status
        FROM user_profiles
        WHERE s.assignee_type = 'user' AND id = s.assignee_id
        UNION ALL
        SELECT up.id, up.email, up.role, up.status
        FROM group_members gm
        JOIN user_profiles up ON up.id = gm.user_id
        WHERE s.assignee_type = 'group' AND gm.group_id = s.assignee_id
    ) u ON true;
END;
$$;


--
-- Name: update_customer_profile_timestamp(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_customer_profile_timestamp() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  new.updated_at = timezone('utc'::text, now());
  return new;
end;
$$;


--
-- Name: update_modified_column(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_modified_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


--
-- Name: update_user_role(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_user_role(user_id uuid, new_role text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    -- Check if the current user is an admin
    IF NOT EXISTS (
        SELECT 1 FROM user_profiles
        WHERE id = auth.uid() AND role = 'admin'
    ) THEN
        RAISE EXCEPTION 'Only admins can update user roles';
    END IF;

    -- Update the user's role
    UPDATE user_profiles
    SET role = new_role,
        updated_at = NOW()
    WHERE id = user_id;

    -- Update the user's custom claims
    UPDATE auth.users
    SET raw_user_meta_data = jsonb_set(
        COALESCE(raw_user_meta_data, '{}'::jsonb),
        '{role}',
        to_jsonb(new_role)
    )
    WHERE id = user_id;
END;
$$;


--
-- Name: authorize(public.app_resource, public.app_action); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.authorize(p_resource public.app_resource, p_action public.app_action) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;


--
-- Name: custom_access_token_hook(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.custom_access_token_hook(event jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;


--
-- Name: seed_initial_admin(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.seed_initial_admin(p_user_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
    UPDATE public.user_profiles
    SET role = 'admin',
        updated_at = now()
    WHERE id = p_user_id;
END;
$$;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: activity_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activity_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    action text NOT NULL,
    entity_type text NOT NULL,
    entity_id text,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: agent_commands; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_commands (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    command text
);


--
-- Name: COLUMN agent_commands.command; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.agent_commands.command IS 'agent command';


--
-- Name: agent_commands_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.agent_commands ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.agent_commands_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: agent_response; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_response (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    response text,
    command_id bigint
);


--
-- Name: COLUMN agent_response.command_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.agent_response.command_id IS 'id from source command from agent_commands table';


--
-- Name: agent_response_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.agent_response ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.agent_response_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: application_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.application_groups (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    vm_ids text[],
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    project_id text,
    resources jsonb DEFAULT '""'::jsonb NOT NULL,
    data_center_id bigint,
    target_datacenter_id bigint,
    target_bucket text,
    backup_region text,
    backup_zone text,
    minimum_backup_count integer DEFAULT 0
);


--
-- Name: TABLE application_groups; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.application_groups IS 'This is a duplicate of applications';


--
-- Name: application_groups_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.application_groups ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.application_groups_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: applications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.applications (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    vm_ids text[],
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    backupcatalog bigint
);


--
-- Name: COLUMN applications.backupcatalog; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.applications.backupcatalog IS 'link to backup catalog';


--
-- Name: applications_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.applications ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.applications_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: approval_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.approval_tokens (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    step_id uuid NOT NULL,
    approver_id uuid NOT NULL,
    token text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    is_used boolean DEFAULT false,
    used_at timestamp with time zone,
    used_by uuid,
    is_checkpoint boolean DEFAULT false,
    checkpoint_id uuid
);


--
-- Name: audit_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    action text NOT NULL,
    entity_type text NOT NULL,
    entity_id uuid,
    details jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: backup_execution; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.backup_execution (
    execution_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    schedule_id text DEFAULT ''::text NOT NULL,
    project_config_snapshot jsonb NOT NULL,
    vm_snapshots jsonb,
    status text DEFAULT ''::text NOT NULL
);


--
-- Name: backup_run; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.backup_run (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    application_group_id bigint NOT NULL,
    status text DEFAULT 'not null check (status in (''pending'',''completed'',''failed'')),'::text,
    summary jsonb,
    created_at timestamp with time zone DEFAULT now(),
    project_config jsonb DEFAULT '{}'::jsonb NOT NULL,
    retention_period bigint DEFAULT '7'::bigint,
    datacentre_config jsonb not null default '""'::jsonb
);


--
-- Name: backupcatalogs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.backupcatalogs (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    hostname text,
    username text,
    password text,
    port text,
    apitoken text,
    hypervisor_type text,
    user_id uuid DEFAULT auth.uid()
);


--
-- Name: TABLE backupcatalogs; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.backupcatalogs IS 'Table for backup catalogs like Cohesity, CommVault, Rubrik';


--
-- Name: backupcatalogs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.backupcatalogs ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.backupcatalogs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: customers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customers (
    id uuid NOT NULL,
    stripe_customer_id text
);


--
-- Name: datacenters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.datacenters (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    hostname text,
    username text,
    password text,
    port text,
    apitoken text,
    hypervisor_type text
);


--
-- Name: datacenters2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.datacenters2 (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    hypervisor_type text,
    apitoken json,
    project_id text,
    name text DEFAULT ''::text NOT NULL,
    is_control_plane boolean null default false,
    manual_snapshot_cleanup boolean DEFAULT false NOT NULL
);


--
-- Name: COLUMN datacenters2.name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.datacenters2.name IS 'Name of the datacentre';


--
-- Name: datacenters2_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.datacenters2 ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.datacenters2_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: datacenters_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.datacenters ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.datacenters_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: disks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.disks (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    vm_id bigint,
    name character varying(255) NOT NULL,
    type character varying(50) NOT NULL,
    size_gb integer NOT NULL,
    recovery_points jsonb DEFAULT '[]'::jsonb,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT disks_type_check CHECK (((type)::text = ANY (ARRAY[('os'::character varying)::text, ('data'::character varying)::text])))
);


--
-- Name: group_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.group_members (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    group_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role text DEFAULT 'member'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    CONSTRAINT group_members_role_check CHECK ((role = ANY (ARRAY['admin'::text, 'member'::text])))
);


--
-- Name: integration_configs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.integration_configs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    source text NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    last_sync_at timestamp with time zone,
    sync_status text,
    error_message text,
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT integration_configs_source_check CHECK ((source = ANY (ARRAY['native'::text, 'gcp_ad'::text]))),
    CONSTRAINT integration_configs_sync_status_check CHECK ((sync_status = ANY (ARRAY['idle'::text, 'syncing'::text, 'success'::text, 'error'::text, 'in_progress'::text])))
);


--
-- Name: internal_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.internal_groups (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    description text,
    type text DEFAULT 'internal'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    metadata jsonb DEFAULT '{}'::jsonb,
    CONSTRAINT internal_groups_type_check CHECK ((type = 'internal'::text))
);


--
-- Name: license_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.license_logs (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    license_id uuid,
    action text,
    "timestamp" timestamp with time zone DEFAULT timezone('utc'::text, now()),
    metadata jsonb
);


--
-- Name: licenses_backup; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.licenses_backup (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    customer_id text NOT NULL,
    jwt text NOT NULL,
    issued_at timestamp with time zone DEFAULT now()
);


--
-- Name: organizations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organizations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    domain text,
    created_at timestamp with time zone DEFAULT now(),
    status text DEFAULT 'active'::text NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb
);


--
-- Name: prices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.prices (
    id text NOT NULL,
    product_id text,
    active boolean,
    description text,
    unit_amount bigint,
    currency text,
    type public.pricing_type,
    "interval" public.pricing_plan_interval,
    interval_count integer,
    trial_period_days integer,
    metadata jsonb,
    CONSTRAINT prices_currency_check CHECK ((char_length(currency) = 3))
);


--
-- Name: products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.products (
    id text NOT NULL,
    active boolean,
    name text,
    description text,
    image text,
    metadata jsonb
);


--
-- Name: recovery_plan_audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recovery_plan_audit_log (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    recovery_plan_id uuid NOT NULL,
    step_id uuid NOT NULL,
    action text NOT NULL,
    performed_by uuid NOT NULL,
    details jsonb,
    ip_address text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: recovery_plan_checkpoints; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recovery_plan_checkpoints (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    recovery_plan_id uuid NOT NULL,
    step_id uuid NOT NULL,
    approver_id uuid,
    approver_role text,
    approval_required boolean DEFAULT true NOT NULL,
    approval_status text,
    approved_at timestamp with time zone,
    approved_by uuid,
    approval_metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT recovery_plan_checkpoints_approval_status_check CHECK ((approval_status = ANY (ARRAY['pending'::text, 'approved'::text, 'rejected'::text]))),
    CONSTRAINT recovery_plan_checkpoints_check CHECK ((((approver_id IS NOT NULL) AND (approver_role IS NULL)) OR ((approver_id IS NULL) AND (approver_role IS NOT NULL))))
);


--
-- Name: recovery_plan_execution; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recovery_plan_execution (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT (now() AT TIME ZONE 'utc'::text) NOT NULL,
    completed_at timestamp without time zone DEFAULT (now() AT TIME ZONE 'utc'::text),
    status text DEFAULT ''::text,
    recovery_plan_id uuid DEFAULT gen_random_uuid(),
    completed_steps bigint,
    failed_steps bigint,
    error_message text,
    metadata jsonb
);


--
-- Name: recovery_plan_execution_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.recovery_plan_execution ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.recovery_plan_execution_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: recovery_plan_progress; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recovery_plan_progress (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    recovery_plan_id uuid NOT NULL,
    step_id uuid NOT NULL,
    status text NOT NULL,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    execution_metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    execution_id text DEFAULT ''::text NOT NULL,
    ---CONSTRAINT recovery_plan_progress_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'in_progress'::text, 'completed'::text, 'failed'::text, 'awaiting_approval'::text, 'approved'::text, 'rejected'::text])))
    constraint recovery_plan_progress_status_check check ((status = any (array['pending'::text,'in_progress'::text,'completed'::text,'failed'::text,'stopped'::text,'awaiting_approval'::text,'approved'::text,'rejected'::text])))
);


--
-- Name: recovery_plans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recovery_plans (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    description text,
    app_group_id bigint,
    created_at timestamp without time zone DEFAULT now()
);


--
-- Name: recovery_plans_new; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recovery_plans_new (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    description text,
    app_group_id bigint,
    created_at timestamp without time zone DEFAULT now(),
    status text,
    created_by uuid,
    current_execution_id uuid,
    execution_status text,
    execution_started_at timestamp with time zone,
    execution_completed_at timestamp with time zone,
    execution_metadata jsonb DEFAULT '{}'::jsonb,
    destination_datacenter_id bigint,
    ---CONSTRAINT recovery_plans_new_execution_status_check CHECK ((execution_status = ANY (ARRAY['not_started'::text, 'in_progress'::text, 'paused'::text, 'completed'::text, 'failed'::text])))
    constraint recovery_plans_new_execution_status_check check ((execution_status = any (array['not_started'::text,'in_progress'::text,'paused'::text,'completed'::text,'stopped'::text,'failed'::text])))

);


--
-- Name: TABLE recovery_plans_new; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.recovery_plans_new IS 'This is a duplicate of recovery_plans';


--
-- Name: recovery_step_execution; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recovery_step_execution (
    step_execution_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    plan_execution_id bigint,
    status text,
    resource_id text,
    resource_backup_id text,
    started_at timestamp without time zone,
    completed_at timestamp without time zone,
    error_message text,
    configs jsonb,
    updated_at timestamp without time zone,
    step_id uuid,
    target_region text,
    target_zone text
);


--
-- Name: recovery_step_execution_step_execution_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.recovery_step_execution ALTER COLUMN step_execution_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.recovery_step_execution_step_execution_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



--
-- Name: recovery_steps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recovery_steps (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    recovery_plan_id uuid,
    name text NOT NULL,
    description text,
    status text DEFAULT 'Pending'::text,
    owner text,
    operation_type text,
    step_order integer NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    CONSTRAINT recovery_steps_status_check CHECK ((status = ANY (ARRAY['Pending'::text, 'In Progress'::text, 'Completed'::text])))
);


--
-- Name: recovery_steps_new; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recovery_steps_new (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    recovery_plan_id uuid,
    name text NOT NULL,
    description text,
    status text DEFAULT 'Pending'::text,
    owner text,
    operation_type text,
    step_order integer NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    configuration jsonb,
    assignee_type text,
    assignee_id uuid,
    assignee_name text,
    assignee_details jsonb DEFAULT '{}'::jsonb,
    requires_approval boolean DEFAULT false,
    approval_metadata jsonb DEFAULT '{}'::jsonb,
    resource_backup_id jsonb,
    target_region text,
    target_zone text,
    CONSTRAINT recovery_steps_new_assignee_type_check CHECK (assignee_type IN ('user', 'group')),
    CONSTRAINT recovery_steps_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'in_progress'::text, 'completed'::text, 'failed'::text, 'awaiting_approval'::text])))
);


--
-- Name: TABLE recovery_steps_new; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.recovery_steps_new IS 'This is a duplicate of recovery_steps';


--
-- Name: resource_backup; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_backup (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    started_at timestamp with time zone DEFAULT NULL,
    completed_at timestamp with time zone DEFAULT NULL,
    backup_run_id text,
    status text DEFAULT 'NOT NULL CHECK (status IN (''pending'',''completed'',''failed''))'::text,
    config jsonb,
    project_config jsonb,
    artifact_uri text NOT NULL,
    resource_id text DEFAULT ''::text NOT NULL,
    resource_type text NOT NULL,
    source jsonb DEFAULT '{}'::jsonb NOT NULL,
    destination jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: role_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role_permissions (
    role public.app_role NOT NULL,
    resource public.app_resource NOT NULL,
    action public.app_action NOT NULL,
    allowed boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

-- Seed default RBAC permission matrix.
INSERT INTO public.role_permissions (role, resource, action, allowed) VALUES
    ('admin', 'dashboard', 'read', true),
    ('admin', 'dashboard', 'create', true),
    ('admin', 'dashboard', 'update', true),
    ('admin', 'dashboard', 'delete', true),
    ('admin', 'dashboard', 'execute', true),
    ('admin', 'dashboard', 'approve', true),
    ('admin', 'dashboard', 'manual_step', true),
    ('admin', 'dashboard', 'verify', true),
    ('admin', 'dashboard', 'manage', true),
    ('operator', 'dashboard', 'read', true),
    ('operator', 'dashboard', 'create', true),
    ('operator', 'dashboard', 'update', true),
    ('operator', 'dashboard', 'delete', true),
    ('operator', 'dashboard', 'execute', true),
    ('operator', 'dashboard', 'approve', true),
    ('operator', 'dashboard', 'manual_step', true),
    ('operator', 'dashboard', 'verify', true),
    ('operator', 'dashboard', 'manage', true),
    ('approver', 'dashboard', 'read', true),
    ('approver', 'dashboard', 'create', true),
    ('approver', 'dashboard', 'update', true),
    ('approver', 'dashboard', 'delete', true),
    ('approver', 'dashboard', 'execute', true),
    ('approver', 'dashboard', 'approve', true),
    ('approver', 'dashboard', 'manual_step', true),
    ('approver', 'dashboard', 'verify', true),
    ('approver', 'dashboard', 'manage', true),
    ('viewer', 'dashboard', 'read', true),
    ('viewer', 'dashboard', 'create', true),
    ('viewer', 'dashboard', 'update', true),
    ('viewer', 'dashboard', 'delete', true),
    ('viewer', 'dashboard', 'execute', true),
    ('viewer', 'dashboard', 'approve', true),
    ('viewer', 'dashboard', 'manual_step', true),
    ('viewer', 'dashboard', 'verify', true),
    ('viewer', 'dashboard', 'manage', true),
    ('admin', 'datacenter', 'manage', true),
    ('operator', 'datacenter', 'read', true),
    ('approver', 'datacenter', 'read', true),
    ('viewer', 'datacenter', 'read', true),
    ('admin', 'applications', 'manage', true),
    ('operator', 'applications', 'manage', true),
    ('approver', 'applications', 'read', true),
    ('viewer', 'applications', 'read', true),
    ('admin', 'recovery_plans', 'manage', true),
    ('operator', 'recovery_plans', 'read', true),
    ('approver', 'recovery_plans', 'read', true),
    ('approver', 'recovery_plans', 'approve', true),
    ('approver', 'recovery_plans', 'manual_step', true),
    ('approver', 'recovery_plans', 'verify', true),
    ('viewer', 'recovery_plans', 'read', true),
    ('admin', 'settings', 'manage', true),
    ('operator', 'settings', 'read', true),
    ('approver', 'settings', 'read', true),
    ('viewer', 'settings', 'read', true),
    ('admin', 'license', 'manage', true),
    ('operator', 'license', 'read', true),
    ('approver', 'license', 'read', true),
    ('viewer', 'license', 'read', true);


--
-- Name: snapshot_schedules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.snapshot_schedules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    group_id text NOT NULL,
    vm_ids text[] NOT NULL,
    frequency text NOT NULL,
    retention_period smallint NOT NULL,
    start_time text,
    day_of_week smallint,
    day_of_month smallint,
    status text DEFAULT '''active'''::text,
    next_run timestamp with time zone,
    last_run timestamp with time zone,
    "datacenterId" bigint,
    application_group_id bigint
);

--
-- Name: sts_job; Type: TABLE; Schema: public; Owner: Avi Desc: object storage backup jobs -
--

create table public.sts_job (
  id bigint generated by default as identity not null,
  created_at timestamp with time zone not null default now(),
  project_id character varying null default ''::character varying,
  name character varying not null default ''::character varying,
  source_project_id character varying null default ''::character varying,
  source_bucket character varying null default ''::character varying,
  target_project_id character varying null default ''::character varying,
  target_bucket character varying null default ''::character varying,
  job_type character varying null default ''::character varying,
  status character varying null default ''::character varying,
  updated_at timestamp without time zone null default (now() AT TIME ZONE 'utc'::text),
  constraint sts_job_pkey primary key (id)
) ;

--
-- Name: subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscriptions (
    id text NOT NULL,
    user_id uuid NOT NULL,
    status public.subscription_status,
    metadata jsonb,
    price_id text,
    quantity integer,
    cancel_at_period_end boolean,
    created timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
    current_period_start timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
    current_period_end timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
    ended_at timestamp with time zone DEFAULT timezone('utc'::text, now()),
    cancel_at timestamp with time zone DEFAULT timezone('utc'::text, now()),
    canceled_at timestamp with time zone DEFAULT timezone('utc'::text, now()),
    trial_start timestamp with time zone DEFAULT timezone('utc'::text, now()),
    trial_end timestamp with time zone DEFAULT timezone('utc'::text, now())
);


--
-- Name: sync_stats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sync_stats (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    source text NOT NULL,
    total_users integer DEFAULT 0 NOT NULL,
    total_groups integer DEFAULT 0 NOT NULL,
    synced_users integer DEFAULT 0 NOT NULL,
    synced_groups integer DEFAULT 0 NOT NULL,
    conflicts integer DEFAULT 0 NOT NULL,
    last_sync_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT sync_stats_source_check CHECK ((source = ANY (ARRAY['native'::text, 'gcp_ad'::text])))
);


--
-- Name: tasktable; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tasktable (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    task text,
    status text,
    response text
);


--
-- Name: tasktable_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.tasktable ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.tasktable_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: user_license; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_license (
    id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    license_key text,
    "isActive" boolean
);


--
-- Name: TABLE user_license; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.user_license IS 'Storage for fetching and updating user license';




--
-- Name: user_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_profiles (
    id uuid NOT NULL,
    email text NOT NULL,
    role text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    last_sign_in_at timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb,
    source text DEFAULT 'native'::text NOT NULL,
    sync_metadata jsonb DEFAULT '{}'::jsonb,
    CONSTRAINT user_profiles_role_check CHECK ((role = ANY (ARRAY['admin'::text, 'operator'::text, 'approver'::text, 'viewer'::text]))),
    CONSTRAINT user_profiles_source_check CHECK ((source = ANY (ARRAY['native'::text, 'gcp_ad'::text]))),
    CONSTRAINT user_profiles_status_check CHECK ((status = ANY (ARRAY['active'::text, 'invited'::text, 'suspended'::text])))
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid NOT NULL,
    full_name text,
    avatar_url text,
    billing_address jsonb,
    payment_method jsonb
);


--
-- Name: vmconfig; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vmconfig (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    machine_type character varying DEFAULT ''::character varying,
    zone character varying DEFAULT ''::character varying,
    status character varying DEFAULT ''::character varying,
    network_interfaces jsonb,
    disks jsonb,
    iam_policies jsonb,
    name text DEFAULT ''::text
);


--
-- Name: vmconfig_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.vmconfig ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.vmconfig_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: vms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vms (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    name text,
    datacenter_id bigint,
    vm_id text,
    power_state text,
    cpu_count text,
    memory_size_mb text
);


--
-- Name: vms_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.vms ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.vms_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: smtp_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.smtp_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    enabled boolean DEFAULT false NOT NULL,
    host text NOT NULL,
    port integer NOT NULL,
    username text,
    password_encrypted text NOT NULL,
    from_name text,
    from_email text NOT NULL,
    secure boolean DEFAULT false NOT NULL,
    updated_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT smtp_settings_port_check CHECK (((port > 0) AND (port <= 65535)))
);

--
-- Name: twilio_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.twilio_settings (
    id bigint generated by default as identity NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    account_sid text DEFAULT ''::text NOT NULL,
    auth_token text DEFAULT ''::text NOT NULL,
    from_number text DEFAULT ''::text NOT NULL,
    enabled boolean NOT NULL,
    CONSTRAINT twilio_settings_pkey PRIMARY KEY (id)
) TABLESPACE pg_default;


-- Recovery run reports: PDF exports and report JSON snapshots per execution
CREATE TABLE IF NOT EXISTS public.recovery_run_reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id TEXT NOT NULL UNIQUE,
    report_json JSONB NOT NULL,
    report_hash TEXT NOT NULL,
    pdf_path TEXT NOT NULL,
    report_version TEXT NOT NULL,
    schema_version TEXT NOT NULL,
    generated_at TIMESTAMPTZ NOT NULL,
    immutable BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_recovery_run_reports_run_id ON public.recovery_run_reports(run_id);
CREATE INDEX IF NOT EXISTS idx_recovery_run_reports_generated_at ON public.recovery_run_reports(generated_at DESC);

-- RLS: allow service role full access; optional read for authenticated users
ALTER TABLE public.recovery_run_reports ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role full access on recovery_run_reports"
    ON public.recovery_run_reports
    FOR ALL
    USING (true)
    WITH CHECK (true);


-- Execution run reports: immutable report snapshots per execution run
CREATE TABLE IF NOT EXISTS public.execution_run_reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id TEXT NOT NULL UNIQUE,
    report_json JSONB NOT NULL,
    report_hash TEXT NOT NULL,
    pdf_path TEXT NOT NULL,
    report_version TEXT NOT NULL DEFAULT '1.0.0',
    schema_version TEXT NOT NULL DEFAULT '1.0.0',
    generated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    immutable BOOLEAN NOT NULL DEFAULT true
);

CREATE INDEX IF NOT EXISTS idx_execution_run_reports_run_id ON public.execution_run_reports(run_id);
CREATE INDEX IF NOT EXISTS idx_execution_run_reports_generated_at ON public.execution_run_reports(generated_at DESC);

ALTER TABLE public.execution_run_reports ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can read execution_run_reports"
    ON public.execution_run_reports
    FOR SELECT
    TO authenticated
    USING (auth.role() = 'authenticated'::text);

CREATE POLICY "Authenticated users can insert execution_run_reports"
    ON public.execution_run_reports
    FOR INSERT
    TO authenticated
    WITH CHECK (auth.role() = 'authenticated'::text);

CREATE POLICY "Authenticated users can update execution_run_reports"
    ON public.execution_run_reports
    FOR UPDATE
    TO authenticated
    USING (auth.role() = 'authenticated'::text)
    WITH CHECK (auth.role() = 'authenticated'::text);

CREATE POLICY "Authenticated users can delete execution_run_reports"
    ON public.execution_run_reports
    FOR DELETE
    TO authenticated
    USING (auth.role() = 'authenticated'::text);



create table public.audit_events (
  event_id uuid not null default gen_random_uuid (),
  timestamp_utc timestamp with time zone not null default now(),
  actor character varying null default 'system'::character varying,
  actor_type character varying null default 'system'::character varying, -- 'human' | 'system'
  action character varying null default ''::character varying,
  resource_type character varying null default ''::character varying,
  resource_id character varying null default ''::character varying,
  resource_version character varying null,
  severity character varying null default 'info'::character varying, -- 'info' | 'warn' | 'high'
  correlation_id character varying null,
  execution_id character varying null,
  incident_id character varying null,
  before jsonb null,
  after jsonb null,
  metadata jsonb null default '{}'::jsonb,
  constraint audit_events_pkey primary key (event_id)
);


-- Enable RLS
alter table public.audit_events enable row level security;

-- Read: any authenticated user
create policy "audit_events_read_authenticated"
on public.audit_events
for select
to authenticated
using (true);

-- Write: any authenticated user (insert)
create policy "audit_events_insert_authenticated"
on public.audit_events
for insert
to authenticated
with check (true);

-- Write: any authenticated user (update)
create policy "audit_events_update_authenticated"
on public.audit_events
for update
to authenticated
using (true)
with check (true);

-- Write: any authenticated user (delete)
create policy "audit_events_delete_authenticated"
on public.audit_events
for delete
to authenticated
using (true);


--
-- Name: TABLE smtp_settings; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.smtp_settings IS 'System-wide SMTP configuration (single row). All users can view; only admins can edit.';


--
-- Name: COLUMN smtp_settings.user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.smtp_settings.user_id IS 'Deprecated: kept for migration; system row has user_id NULL.';


--
-- Name: COLUMN smtp_settings.password_encrypted; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.smtp_settings.password_encrypted IS 'Encrypted SMTP password';


--
-- Name: COLUMN smtp_settings.updated_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.smtp_settings.updated_by IS 'User who last updated the settings';


--
-- Name: activity_logs activity_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_logs
    ADD CONSTRAINT activity_logs_pkey PRIMARY KEY (id);


--
-- Name: agent_commands agent_commands_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_commands
    ADD CONSTRAINT agent_commands_pkey PRIMARY KEY (id);


--
-- Name: agent_response agent_response_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_response
    ADD CONSTRAINT agent_response_pkey PRIMARY KEY (id);


--
-- Name: application_groups application_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.application_groups
    ADD CONSTRAINT application_groups_pkey PRIMARY KEY (id);


--
-- Name: applications applications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.applications
    ADD CONSTRAINT applications_pkey PRIMARY KEY (id);


--
-- Name: approval_tokens approval_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_tokens
    ADD CONSTRAINT approval_tokens_pkey PRIMARY KEY (id);


--
-- Name: approval_tokens approval_tokens_token_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_tokens
    ADD CONSTRAINT approval_tokens_token_key UNIQUE (token);


--
-- Name: audit_logs audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (id);


--
-- Name: backup_execution backup_execution_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.backup_execution
    ADD CONSTRAINT backup_execution_pkey PRIMARY KEY (execution_id);


--
-- Name: backup_run backup_run_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.backup_run
    ADD CONSTRAINT backup_run_pkey PRIMARY KEY (id);


--
-- Name: backupcatalogs backupcatalogs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.backupcatalogs
    ADD CONSTRAINT backupcatalogs_pkey PRIMARY KEY (id);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);


--
-- Name: datacenters2 datacenters2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.datacenters2
    ADD CONSTRAINT datacenters2_pkey PRIMARY KEY (id);


--
-- Name: datacenters2 datacenters2_project_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.datacenters2
    ADD CONSTRAINT datacenters2_project_id_key UNIQUE (project_id);


--
-- Name: datacenters datacenters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.datacenters
    ADD CONSTRAINT datacenters_pkey PRIMARY KEY (id);


--
-- Name: disks disks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.disks
    ADD CONSTRAINT disks_pkey PRIMARY KEY (id);


--
-- Name: group_members group_members_group_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_members
    ADD CONSTRAINT group_members_group_id_user_id_key UNIQUE (group_id, user_id);


--
-- Name: group_members group_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_members
    ADD CONSTRAINT group_members_pkey PRIMARY KEY (id);


--
-- Name: integration_configs integration_configs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_configs
    ADD CONSTRAINT integration_configs_pkey PRIMARY KEY (id);


--
-- Name: integration_configs integration_configs_source_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_configs
    ADD CONSTRAINT integration_configs_source_unique UNIQUE (source);


--
-- Name: internal_groups internal_groups_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.internal_groups
    ADD CONSTRAINT internal_groups_name_key UNIQUE (name);


--
-- Name: internal_groups internal_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.internal_groups
    ADD CONSTRAINT internal_groups_pkey PRIMARY KEY (id);


--
-- Name: license_logs license_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.license_logs
    ADD CONSTRAINT license_logs_pkey PRIMARY KEY (id);


--
-- Name: licenses_backup licenses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.licenses_backup
    ADD CONSTRAINT licenses_pkey PRIMARY KEY (id);


--
-- Name: organizations organizations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT organizations_pkey PRIMARY KEY (id);


--
-- Name: prices prices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prices
    ADD CONSTRAINT prices_pkey PRIMARY KEY (id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: recovery_plan_audit_log recovery_plan_audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plan_audit_log
    ADD CONSTRAINT recovery_plan_audit_log_pkey PRIMARY KEY (id);


--
-- Name: recovery_plan_checkpoints recovery_plan_checkpoints_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plan_checkpoints
    ADD CONSTRAINT recovery_plan_checkpoints_pkey PRIMARY KEY (id);


--
-- Name: recovery_plan_checkpoints recovery_plan_checkpoints_recovery_plan_id_step_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plan_checkpoints
    ADD CONSTRAINT recovery_plan_checkpoints_recovery_plan_id_step_id_key UNIQUE (recovery_plan_id, step_id);


--
-- Name: recovery_plan_execution recovery_plan_execution_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plan_execution
    ADD CONSTRAINT recovery_plan_execution_pkey PRIMARY KEY (id);


--
-- Name: recovery_plan_progress recovery_plan_progress_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plan_progress
    ADD CONSTRAINT recovery_plan_progress_pkey PRIMARY KEY (id);


--
-- Name: recovery_plan_progress recovery_plan_progress_recovery_plan_id_step_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plan_progress
    ADD CONSTRAINT recovery_plan_progress_recovery_plan_id_step_id_key UNIQUE (recovery_plan_id, step_id);


--
-- Name: recovery_plans_new recovery_plans_new_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plans_new
    ADD CONSTRAINT recovery_plans_new_pkey PRIMARY KEY (id);


--
-- Name: recovery_plans recovery_plans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plans
    ADD CONSTRAINT recovery_plans_pkey PRIMARY KEY (id);


--
-- Name: recovery_step_execution recovery_step_execution_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_step_execution
    ADD CONSTRAINT recovery_step_execution_pkey PRIMARY KEY (step_execution_id);


--
-- Name: recovery_steps_new recovery_steps_new_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_steps_new
    ADD CONSTRAINT recovery_steps_new_pkey PRIMARY KEY (id);


--
-- Name: recovery_steps recovery_steps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_steps
    ADD CONSTRAINT recovery_steps_pkey PRIMARY KEY (id);


--
-- Name: resource_backup resource_backup_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_backup
    ADD CONSTRAINT resource_backup_pkey PRIMARY KEY (id);


--
-- Name: role_permissions role_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_pkey PRIMARY KEY (role, resource, action);


--
-- Name: snapshot_schedules snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.snapshot_schedules
    ADD CONSTRAINT snapshots_pkey PRIMARY KEY (id);


--
-- Name: subscriptions subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (id);


--
-- Name: sync_stats sync_stats_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sync_stats
    ADD CONSTRAINT sync_stats_pkey PRIMARY KEY (id);


--
-- Name: sync_stats sync_stats_source_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sync_stats
    ADD CONSTRAINT sync_stats_source_unique UNIQUE (source);


--
-- Name: tasktable tasktable_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasktable
    ADD CONSTRAINT tasktable_pkey PRIMARY KEY (id);


--
-- Name: user_license user_license_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_license
    ADD CONSTRAINT user_license_pkey PRIMARY KEY (id);


--
-- Name: user_profiles user_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_profiles
    ADD CONSTRAINT user_profiles_pkey PRIMARY KEY (id);


--
-- Name: user_profiles user_profiles_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_profiles
    ADD CONSTRAINT user_profiles_email_key UNIQUE (email);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: vmconfig vmconfig_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vmconfig
    ADD CONSTRAINT vmconfig_pkey PRIMARY KEY (id);


--
-- Name: vms vms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vms
    ADD CONSTRAINT vms_pkey PRIMARY KEY (id);



--
-- Name: smtp_settings smtp_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smtp_settings
    ADD CONSTRAINT smtp_settings_pkey PRIMARY KEY (id);


-- 4. Ensure only one system row (user_id IS NULL) can exist
CREATE UNIQUE INDEX IF NOT EXISTS idx_smtp_single_system
    ON public.smtp_settings ((true))
    WHERE (user_id IS NULL);

--
-- Name: activity_logs_action_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activity_logs_action_idx ON public.activity_logs USING btree (action);


--
-- Name: activity_logs_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activity_logs_created_at_idx ON public.activity_logs USING btree (created_at);


--
-- Name: activity_logs_entity_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activity_logs_entity_type_idx ON public.activity_logs USING btree (entity_type);


--
-- Name: activity_logs_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activity_logs_user_id_idx ON public.activity_logs USING btree (user_id);


--
-- Name: idx_approval_tokens_approver; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_approval_tokens_approver ON public.approval_tokens USING btree (approver_id);


--
-- Name: idx_approval_tokens_checkpoint; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_approval_tokens_checkpoint ON public.approval_tokens USING btree (checkpoint_id);


--
-- Name: idx_approval_tokens_step; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_approval_tokens_step ON public.approval_tokens USING btree (step_id);


--
-- Name: idx_approval_tokens_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_approval_tokens_token ON public.approval_tokens USING btree (token);


--
-- Name: idx_disks_vm_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_disks_vm_id ON public.disks USING btree (vm_id);


--
-- Name: idx_group_members_group_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_members_group_id ON public.group_members USING btree (group_id);


--
-- Name: idx_group_members_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_members_user_id ON public.group_members USING btree (user_id);


--
-- Name: idx_integration_configs_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_integration_configs_source ON public.integration_configs USING btree (source);


--
-- Name: idx_recovery_plan_audit_log_performed_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recovery_plan_audit_log_performed_by ON public.recovery_plan_audit_log USING btree (performed_by);


--
-- Name: idx_recovery_plan_audit_log_plan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recovery_plan_audit_log_plan ON public.recovery_plan_audit_log USING btree (recovery_plan_id);


--
-- Name: idx_recovery_plan_audit_log_step; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recovery_plan_audit_log_step ON public.recovery_plan_audit_log USING btree (step_id);


--
-- Name: idx_recovery_plan_checkpoints_approver; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recovery_plan_checkpoints_approver ON public.recovery_plan_checkpoints USING btree (approver_id);


--
-- Name: idx_recovery_plan_checkpoints_plan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recovery_plan_checkpoints_plan ON public.recovery_plan_checkpoints USING btree (recovery_plan_id);


--
-- Name: idx_recovery_plan_checkpoints_recovery_plan_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recovery_plan_checkpoints_recovery_plan_id ON public.recovery_plan_checkpoints USING btree (recovery_plan_id);


--
-- Name: idx_recovery_plan_checkpoints_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recovery_plan_checkpoints_role ON public.recovery_plan_checkpoints USING btree (approver_role);


--
-- Name: idx_recovery_plan_checkpoints_step; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recovery_plan_checkpoints_step ON public.recovery_plan_checkpoints USING btree (step_id);


--
-- Name: idx_recovery_plan_progress_plan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recovery_plan_progress_plan ON public.recovery_plan_progress USING btree (recovery_plan_id);


--
-- Name: idx_recovery_plan_progress_recovery_plan_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recovery_plan_progress_recovery_plan_id ON public.recovery_plan_progress USING btree (recovery_plan_id);


--
-- Name: idx_recovery_plan_progress_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recovery_plan_progress_status ON public.recovery_plan_progress USING btree (status);


--
-- Name: idx_recovery_plan_progress_step; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recovery_plan_progress_step ON public.recovery_plan_progress USING btree (step_id);


--
-- Name: idx_recovery_steps_assignee; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recovery_steps_assignee ON public.recovery_steps_new (assignee_type, assignee_id);

--
-- Name: idx_recovery_steps_recovery_plan_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recovery_steps_recovery_plan_id ON public.recovery_steps_new USING btree (recovery_plan_id);


--
-- Name: idx_sync_stats_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sync_stats_source ON public.sync_stats USING btree (source);


--
-- Name: idx_user_profiles_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_profiles_source ON public.user_profiles USING btree (source);


--
-- Name: licenses_customer_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX licenses_customer_id_idx ON public.licenses_backup USING btree (customer_id);


--
-- Name: organizations_domain_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organizations_domain_idx ON public.organizations USING btree (domain);


--
-- Name: idx_smtp_settings_enabled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_smtp_settings_enabled ON public.smtp_settings USING btree (enabled);


--
-- Name: idx_smtp_settings_updated_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_smtp_settings_updated_at ON public.smtp_settings USING btree (updated_at);


--
-- Name: idx_smtp_settings_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_smtp_settings_user_id ON public.smtp_settings USING btree (user_id);



--
-- Name: users on_auth_user_created; Type: TRIGGER; Schema: auth; Owner: -
--

CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


--
-- Name: users on_auth_user_deleted; Type: TRIGGER; Schema: auth; Owner: -
--

CREATE TRIGGER on_auth_user_deleted BEFORE DELETE ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_user_deletion();

--
-- Name: user_profiles on_user_profile_deletion; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER on_user_profile_deletion BEFORE DELETE ON public.user_profiles FOR EACH ROW EXECUTE FUNCTION public.log_user_profile_deletion();


--
-- Name: user_profiles on_user_profile_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER on_user_profile_update AFTER UPDATE ON public.user_profiles FOR EACH ROW EXECUTE FUNCTION public.log_user_profile_update();

ALTER TABLE public.user_profiles DISABLE TRIGGER on_user_profile_update;


--
-- Name: applications update_applications_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_applications_updated_at BEFORE UPDATE ON public.applications FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: disks update_disks_modtime; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_disks_modtime BEFORE UPDATE ON public.disks FOR EACH ROW EXECUTE FUNCTION public.update_modified_column();


--
-- Name: group_members update_group_members_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_group_members_updated_at BEFORE UPDATE ON public.group_members FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: integration_configs update_integration_configs_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_integration_configs_updated_at BEFORE UPDATE ON public.integration_configs FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: internal_groups update_internal_groups_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_internal_groups_updated_at BEFORE UPDATE ON public.internal_groups FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: sync_stats update_sync_stats_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_sync_stats_updated_at BEFORE UPDATE ON public.sync_stats FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: vms update_vms_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_vms_updated_at BEFORE UPDATE ON public.vms FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: activity_logs activity_logs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_logs
    ADD CONSTRAINT activity_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: application_groups application_groups_data_center_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--
ALTER TABLE ONLY public.application_groups
    ADD CONSTRAINT application_groups_data_center_id_fkey FOREIGN KEY (data_center_id) REFERENCES public.datacenters2(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: application_groups application_groups_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--
ALTER TABLE ONLY public.application_groups
    ADD CONSTRAINT application_groups_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.datacenters2(project_id) ON UPDATE CASCADE ON DELETE CASCADE;



--
-- Name: application_groups application_groups_target_datacenter_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--
ALTER TABLE ONLY public.application_groups
    ADD CONSTRAINT application_groups_target_datacenter_id_fkey FOREIGN KEY (target_datacenter_id) REFERENCES public.datacenters2(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: approval_tokens approval_tokens_approver_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_tokens
    ADD CONSTRAINT approval_tokens_approver_id_fkey FOREIGN KEY (approver_id) REFERENCES public.user_profiles(id);


--
-- Name: approval_tokens approval_tokens_checkpoint_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_tokens
    ADD CONSTRAINT approval_tokens_checkpoint_id_fkey FOREIGN KEY (checkpoint_id) REFERENCES public.recovery_plan_checkpoints(id) ON DELETE CASCADE;


--
-- Name: approval_tokens approval_tokens_step_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_tokens
    ADD CONSTRAINT approval_tokens_step_id_fkey FOREIGN KEY (step_id) REFERENCES public.recovery_steps_new(id) ON DELETE CASCADE;


--
-- Name: approval_tokens approval_tokens_used_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_tokens
    ADD CONSTRAINT approval_tokens_used_by_fkey FOREIGN KEY (used_by) REFERENCES public.user_profiles(id);


--
-- Name: audit_logs audit_logs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: backup_run backup_run_application_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--
ALTER TABLE ONLY public.backup_run
    ADD CONSTRAINT backup_run_application_group_id_fkey FOREIGN KEY (application_group_id) REFERENCES public.application_groups(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: customers customers_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id);


--
-- Name: disks disks_vm_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.disks
    ADD CONSTRAINT disks_vm_id_fkey FOREIGN KEY (vm_id) REFERENCES public.vms(id) ON DELETE CASCADE;


--
-- Name: approval_tokens fk_approver; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_tokens
    ADD CONSTRAINT fk_approver FOREIGN KEY (approver_id) REFERENCES public.user_profiles(id) ON DELETE CASCADE;


--
-- Name: recovery_plan_audit_log fk_performed_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plan_audit_log
    ADD CONSTRAINT fk_performed_by FOREIGN KEY (performed_by) REFERENCES public.user_profiles(id) ON DELETE CASCADE;


--
-- Name: recovery_plan_audit_log fk_recovery_plan; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plan_audit_log
    ADD CONSTRAINT fk_recovery_plan FOREIGN KEY (recovery_plan_id) REFERENCES public.recovery_plans_new(id) ON DELETE CASCADE;


--
-- Name: recovery_plan_audit_log fk_step; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plan_audit_log
    ADD CONSTRAINT fk_step FOREIGN KEY (step_id) REFERENCES public.recovery_steps_new(id) ON DELETE CASCADE;


--
-- Name: approval_tokens fk_step; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_tokens
    ADD CONSTRAINT fk_step FOREIGN KEY (step_id) REFERENCES public.recovery_steps_new(id) ON DELETE CASCADE;


--
-- Name: group_members group_members_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_members
    ADD CONSTRAINT group_members_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: group_members group_members_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_members
    ADD CONSTRAINT group_members_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.internal_groups(id) ON DELETE CASCADE;


--
-- Name: group_members group_members_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_members
    ADD CONSTRAINT group_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: internal_groups internal_groups_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.internal_groups
    ADD CONSTRAINT internal_groups_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: prices prices_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prices
    ADD CONSTRAINT prices_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: recovery_plan_audit_log recovery_plan_audit_log_performed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plan_audit_log
    ADD CONSTRAINT recovery_plan_audit_log_performed_by_fkey FOREIGN KEY (performed_by) REFERENCES public.user_profiles(id);


--
-- Name: recovery_plan_audit_log recovery_plan_audit_log_recovery_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plan_audit_log
    ADD CONSTRAINT recovery_plan_audit_log_recovery_plan_id_fkey FOREIGN KEY (recovery_plan_id) REFERENCES public.recovery_plans_new(id);


--
-- Name: recovery_plan_audit_log recovery_plan_audit_log_step_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plan_audit_log
    ADD CONSTRAINT recovery_plan_audit_log_step_id_fkey FOREIGN KEY (step_id) REFERENCES public.recovery_steps_new(id);


--
-- Name: recovery_plan_checkpoints recovery_plan_checkpoints_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plan_checkpoints
    ADD CONSTRAINT recovery_plan_checkpoints_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES public.user_profiles(id);


--
-- Name: recovery_plan_checkpoints recovery_plan_checkpoints_approver_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plan_checkpoints
    ADD CONSTRAINT recovery_plan_checkpoints_approver_id_fkey FOREIGN KEY (approver_id) REFERENCES public.user_profiles(id);


--
-- Name: recovery_plan_checkpoints recovery_plan_checkpoints_recovery_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plan_checkpoints
    ADD CONSTRAINT recovery_plan_checkpoints_recovery_plan_id_fkey FOREIGN KEY (recovery_plan_id) REFERENCES public.recovery_plans_new(id) ON DELETE CASCADE;


--
-- Name: recovery_plan_checkpoints recovery_plan_checkpoints_step_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plan_checkpoints
    ADD CONSTRAINT recovery_plan_checkpoints_step_id_fkey FOREIGN KEY (step_id) REFERENCES public.recovery_steps_new(id) ON DELETE CASCADE;


--
-- Name: recovery_plan_progress recovery_plan_progress_recovery_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plan_progress
    ADD CONSTRAINT recovery_plan_progress_recovery_plan_id_fkey FOREIGN KEY (recovery_plan_id) REFERENCES public.recovery_plans_new(id) ON DELETE CASCADE;


--
-- Name: recovery_plan_progress recovery_plan_progress_step_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plan_progress
    ADD CONSTRAINT recovery_plan_progress_step_id_fkey FOREIGN KEY (step_id) REFERENCES public.recovery_steps_new(id) ON DELETE CASCADE;


--
-- Name: recovery_plans recovery_plans_app_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plans
    ADD CONSTRAINT recovery_plans_app_group_id_fkey FOREIGN KEY (app_group_id) REFERENCES public.applications(id) ON DELETE CASCADE;


--
-- Name: recovery_plans_new recovery_plans_new_app_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plans_new
    ADD CONSTRAINT recovery_plans_new_app_group_id_fkey FOREIGN KEY (app_group_id) REFERENCES public.application_groups(id);


--
-- Name: recovery_plans_new recovery_plans_new_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plans_new
    ADD CONSTRAINT recovery_plans_new_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.user_profiles(id);


--
-- Name: recovery_plans_new recovery_plans_new_destination_datacenter_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_plans_new
    ADD CONSTRAINT recovery_plans_new_destination_datacenter_id_fkey FOREIGN KEY (destination_datacenter_id) REFERENCES public.datacenters2(id);



--
-- Name: recovery_step_execution recovery_step_execution_plan_execution_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--
ALTER TABLE ONLY public.recovery_step_execution
    ADD CONSTRAINT recovery_step_execution_plan_execution_id_fkey FOREIGN KEY (plan_execution_id) REFERENCES public.recovery_plan_execution(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: recovery_step_execution recovery_step_execution_step_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--
ALTER TABLE ONLY public.recovery_step_execution
    ADD CONSTRAINT recovery_step_execution_step_id_fkey FOREIGN KEY (step_id) REFERENCES public.recovery_steps_new(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: recovery_steps_new recovery_steps_new_recovery_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_steps_new
    ADD CONSTRAINT recovery_steps_new_recovery_plan_id_fkey FOREIGN KEY (recovery_plan_id) REFERENCES public.recovery_plans_new(id) ON DELETE CASCADE;


--
-- Name: recovery_steps recovery_steps_recovery_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_steps
    ADD CONSTRAINT recovery_steps_recovery_plan_id_fkey FOREIGN KEY (recovery_plan_id) REFERENCES public.recovery_plans(id) ON DELETE CASCADE;



--
-- Name: smtp_settings smtp_settings_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smtp_settings
    ADD CONSTRAINT smtp_settings_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.user_profiles(id);


--
-- Name: smtp_settings smtp_settings_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smtp_settings
    ADD CONSTRAINT smtp_settings_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.user_profiles(id) ON DELETE CASCADE;



--
-- Name: snapshot_schedules snapshot_schedules_datacenterId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.snapshot_schedules
    ADD CONSTRAINT "snapshot_schedules_datacenterId_fkey" FOREIGN KEY ("datacenterId") REFERENCES public.datacenters2(id);

--
-- Name: snapshot_schedules snapshot_schedules_application_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.snapshot_schedules
    ADD CONSTRAINT snapshot_schedules_application_group_id_fkey FOREIGN KEY (application_group_id) REFERENCES public.application_groups(id) ON DELETE RESTRICT;



--
-- Name: subscriptions subscriptions_price_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_price_id_fkey FOREIGN KEY (price_id) REFERENCES public.prices(id);


--
-- Name: subscriptions subscriptions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id);


--
-- Name: user_license user_license_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_license
    ADD CONSTRAINT user_license_id_fkey FOREIGN KEY (id) REFERENCES public.user_profiles(id);



--
-- Name: user_profiles user_profiles_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_profiles
    ADD CONSTRAINT user_profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: users users_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id);


--
-- Name: audit_log_entries; Type: ROW SECURITY; Schema: auth; Owner: -
--

ALTER TABLE auth.audit_log_entries ENABLE ROW LEVEL SECURITY;

--
-- Name: flow_state; Type: ROW SECURITY; Schema: auth; Owner: -
--

ALTER TABLE auth.flow_state ENABLE ROW LEVEL SECURITY;

--
-- Name: identities; Type: ROW SECURITY; Schema: auth; Owner: -
--

ALTER TABLE auth.identities ENABLE ROW LEVEL SECURITY;

--
-- Name: instances; Type: ROW SECURITY; Schema: auth; Owner: -
--

ALTER TABLE auth.instances ENABLE ROW LEVEL SECURITY;

--
-- Name: mfa_amr_claims; Type: ROW SECURITY; Schema: auth; Owner: -
--

ALTER TABLE auth.mfa_amr_claims ENABLE ROW LEVEL SECURITY;

--
-- Name: mfa_challenges; Type: ROW SECURITY; Schema: auth; Owner: -
--

ALTER TABLE auth.mfa_challenges ENABLE ROW LEVEL SECURITY;

--
-- Name: mfa_factors; Type: ROW SECURITY; Schema: auth; Owner: -
--

ALTER TABLE auth.mfa_factors ENABLE ROW LEVEL SECURITY;

--
-- Name: one_time_tokens; Type: ROW SECURITY; Schema: auth; Owner: -
--

ALTER TABLE auth.one_time_tokens ENABLE ROW LEVEL SECURITY;

--
-- Name: refresh_tokens; Type: ROW SECURITY; Schema: auth; Owner: -
--

ALTER TABLE auth.refresh_tokens ENABLE ROW LEVEL SECURITY;

--
-- Name: saml_providers; Type: ROW SECURITY; Schema: auth; Owner: -
--

ALTER TABLE auth.saml_providers ENABLE ROW LEVEL SECURITY;

--
-- Name: saml_relay_states; Type: ROW SECURITY; Schema: auth; Owner: -
--

ALTER TABLE auth.saml_relay_states ENABLE ROW LEVEL SECURITY;

--
-- Name: schema_migrations; Type: ROW SECURITY; Schema: auth; Owner: -
--

ALTER TABLE auth.schema_migrations ENABLE ROW LEVEL SECURITY;

--
-- Name: sessions; Type: ROW SECURITY; Schema: auth; Owner: -
--

ALTER TABLE auth.sessions ENABLE ROW LEVEL SECURITY;

--
-- Name: sso_domains; Type: ROW SECURITY; Schema: auth; Owner: -
--

ALTER TABLE auth.sso_domains ENABLE ROW LEVEL SECURITY;

--
-- Name: sso_providers; Type: ROW SECURITY; Schema: auth; Owner: -
--

ALTER TABLE auth.sso_providers ENABLE ROW LEVEL SECURITY;

--
-- Name: users; Type: ROW SECURITY; Schema: auth; Owner: -
--

ALTER TABLE auth.users ENABLE ROW LEVEL SECURITY;

--
-- Name: audit_logs Admins and operators can view all audit logs; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins and operators can view all audit logs" ON public.audit_logs FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.user_profiles
  WHERE ((user_profiles.id = auth.uid()) AND (user_profiles.role = ANY (ARRAY['admin'::text, 'operator'::text]))))));


--
-- Name: user_profiles Admins can delete profiles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can delete profiles" ON public.user_profiles FOR DELETE USING ((EXISTS ( SELECT 1
   FROM public.user_profiles user_profiles_1
  WHERE ((user_profiles_1.id = auth.uid()) AND (user_profiles_1.role = 'admin'::text)))));


--
-- Name: integration_configs Admins can manage integration configs; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can manage integration configs" ON public.integration_configs TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.user_profiles
  WHERE ((user_profiles.id = auth.uid()) AND (user_profiles.role = 'admin'::text)))));


--
-- Name: user_profiles Admins can update profiles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can update profiles" ON public.user_profiles FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM public.user_profiles user_profiles_1
  WHERE ((user_profiles_1.id = auth.uid()) AND (user_profiles_1.role = 'admin'::text)))));


--
-- Name: audit_logs Admins can view all audit logs; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can view all audit logs" ON public.audit_logs FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.user_profiles
  WHERE ((user_profiles.id = auth.uid()) AND (user_profiles.role = 'admin'::text)))));


--
-- Name: sync_stats Admins can view sync stats; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can view sync stats" ON public.sync_stats FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.user_profiles
  WHERE ((user_profiles.id = auth.uid()) AND (user_profiles.role = 'admin'::text)))));


--
-- Name: license_logs Admins have full access to logs; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins have full access to logs" ON public.license_logs TO authenticated USING ((auth.uid() IN ( SELECT users.id
   FROM auth.users
  WHERE ((users.raw_user_meta_data ->> 'role'::text) = 'admin'::text))));


--
-- Name: vms Allow authenticated users full access to VMs; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow authenticated users full access to VMs" ON public.vms TO authenticated USING ((auth.role() = 'authenticated'::text)) WITH CHECK ((auth.role() = 'authenticated'::text));


--
-- Name: applications Allow authenticated users to read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow authenticated users to read" ON public.applications FOR SELECT USING ((auth.role() = 'authenticated'::text));


--
-- Name: applications Allow authenticated users to write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow authenticated users to write" ON public.applications USING ((auth.role() = 'authenticated'::text));


--
-- Name: user_license Authenticated users can insert licenses; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can insert licenses" ON public.user_license FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: activity_logs Authenticated users can insert logs; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can insert logs" ON public.activity_logs FOR INSERT WITH CHECK ((auth.uid() IS NOT NULL));


--
-- Name: subscriptions Can only view own subs data.; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Can only view own subs data." ON public.subscriptions FOR SELECT USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: users Can update own user data.; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Can update own user data." ON public.users FOR UPDATE USING ((( SELECT auth.uid() AS uid) = id));


--
-- Name: users Can view own user data.; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Can view own user data." ON public.users FOR SELECT USING ((( SELECT auth.uid() AS uid) = id));


--
-- Name: recovery_plans_new DELETE; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "DELETE" ON public.recovery_plans_new FOR DELETE TO authenticated USING (true);


--
-- Name: recovery_steps_new DELETE; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "DELETE" ON public.recovery_steps_new FOR DELETE TO authenticated USING (true);


--
-- Name: application_groups Delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Delete" ON public.application_groups FOR DELETE TO authenticated USING (true);


--
-- Name: datacenters2 Delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Delete" ON public.datacenters2 FOR DELETE USING (true);


--
-- Name: snapshot_schedules Delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Delete" ON public.snapshot_schedules FOR DELETE USING (true);


--
-- Name: application_groups Enable insert for authenticated users only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for authenticated users only" ON public.application_groups FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: datacenters Enable insert for authenticated users only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for authenticated users only" ON public.datacenters FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: datacenters2 Enable insert for authenticated users only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for authenticated users only" ON public.datacenters2 FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: recovery_plans Enable insert for authenticated users only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for authenticated users only" ON public.recovery_plans FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: recovery_plans_new Enable insert for authenticated users only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for authenticated users only" ON public.recovery_plans_new FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: recovery_steps Enable insert for authenticated users only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for authenticated users only" ON public.recovery_steps FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: recovery_steps_new Enable insert for authenticated users only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for authenticated users only" ON public.recovery_steps_new FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: snapshot_schedules Enable insert for authenticated users only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for authenticated users only" ON public.snapshot_schedules FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: recovery_plans_new Enable read access for all users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for all users" ON public.recovery_plans_new FOR SELECT USING (true);


--
-- Name: recovery_steps_new Enable read access for all users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for all users" ON public.recovery_steps_new FOR SELECT USING (true);


--
-- Name: application_groups Enable read access for only auth users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for only auth users" ON public.application_groups FOR SELECT TO authenticated USING ((auth.role() = 'authenticated'::text));


--
-- Name: datacenters Enable read access for only auth users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for only auth users" ON public.datacenters TO authenticated USING ((auth.role() = 'authenticated'::text));


--
-- Name: datacenters2 Enable read access for only auth users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for only auth users" ON public.datacenters2 FOR SELECT USING (true);


--
-- Name: recovery_plans Enable read access for only auth users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for only auth users" ON public.recovery_plans FOR SELECT TO authenticated USING ((auth.role() = 'authenticated'::text));


--
-- Name: recovery_plans rbac_recovery_plans_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY rbac_recovery_plans_select ON public.recovery_plans FOR SELECT TO authenticated USING (public.authorize('recovery_plans'::public.app_resource, 'read'::public.app_action));


--
-- Name: recovery_steps Enable read access for only auth users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for only auth users" ON public.recovery_steps FOR SELECT TO authenticated USING ((auth.role() = 'authenticated'::text));


--
-- Name: snapshot_schedules Enable read access for only auth users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for only auth users" ON public.snapshot_schedules FOR SELECT TO authenticated USING ((auth.role() = 'authenticated'::text));


--
-- Name: user_license Authenticated users can view all licenses; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can view all licenses" ON public.user_license FOR SELECT TO authenticated USING (true);


--
-- Name: licenses_backup Insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Insert" ON public.licenses_backup FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: internal_groups Only admins can create groups; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Only admins can create groups" ON public.internal_groups FOR INSERT TO authenticated WITH CHECK ((EXISTS ( SELECT 1
   FROM public.user_profiles
  WHERE ((user_profiles.id = auth.uid()) AND (user_profiles.role = 'admin'::text)))));


--
-- Name: internal_groups Only admins can delete groups; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Only admins can delete groups" ON public.internal_groups FOR DELETE TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.user_profiles
  WHERE ((user_profiles.id = auth.uid()) AND (user_profiles.role = 'admin'::text)))));


--
-- Name: group_members Only admins can manage group members; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Only admins can manage group members" ON public.group_members TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.user_profiles
  WHERE ((user_profiles.id = auth.uid()) AND (user_profiles.role = 'admin'::text))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.user_profiles
  WHERE ((user_profiles.id = auth.uid()) AND (user_profiles.role = 'admin'::text)))));


--
-- Name: internal_groups Only admins can update groups; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Only admins can update groups" ON public.internal_groups FOR UPDATE TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.user_profiles
  WHERE ((user_profiles.id = auth.uid()) AND (user_profiles.role = 'admin'::text)))));


--
-- Name: licenses_backup READ; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "READ" ON public.licenses_backup FOR SELECT TO authenticated USING (true);


--
-- Name: recovery_plans_new Update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Update" ON public.recovery_plans_new FOR UPDATE TO authenticated USING (true) WITH CHECK (true);


--
-- Name: recovery_steps_new Update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Update" ON public.recovery_steps_new FOR UPDATE USING (true) WITH CHECK (true);


--
-- Name: snapshot_schedules Update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Update" ON public.snapshot_schedules FOR UPDATE USING (true) WITH CHECK (true);


--
-- Name: application_groups Update policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Update policy" ON public.application_groups FOR UPDATE TO authenticated USING (true) WITH CHECK (true);


--
-- Name: approval_tokens Users can create approval tokens; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can create approval tokens" ON public.approval_tokens FOR INSERT WITH CHECK ((approver_id = auth.uid()));


--
-- Name: backupcatalogs Users can delete only their own entries; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can delete only their own entries" ON public.backupcatalogs FOR DELETE USING ((user_id = auth.uid()));


--
-- Name: approval_tokens Users can delete their own approval tokens; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can delete their own approval tokens" ON public.approval_tokens FOR DELETE USING ((approver_id = auth.uid()));


--
-- Name: backupcatalogs Users can insert their own entries; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can insert their own entries" ON public.backupcatalogs FOR INSERT WITH CHECK ((user_id = auth.uid()));


--
-- Name: backupcatalogs Users can read only their own entries; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can read only their own entries" ON public.backupcatalogs FOR SELECT USING ((user_id = auth.uid()));


--
-- Name: backupcatalogs Users can update only their own entries; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can update only their own entries" ON public.backupcatalogs FOR UPDATE USING ((user_id = auth.uid()));


--
-- Name: internal_groups Users can view all groups; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view all groups" ON public.internal_groups FOR SELECT TO authenticated USING (true);


--
-- Name: group_members Users can view group members; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view group members" ON public.group_members FOR SELECT TO authenticated USING (true);


--
-- Name: user_profiles Users can view own profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated Users can view all users" ON public.user_profiles FOR SELECT TO authenticated USING (true);


--
-- Name: recovery_steps_new Users can view steps they are assigned to; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view steps they are assigned to" ON public.recovery_steps_new FOR SELECT USING ((((assignee_type = 'user'::text) AND (assignee_id = auth.uid())) OR ((assignee_type = 'group'::text) AND (EXISTS ( SELECT 1
   FROM public.group_members
  WHERE ((group_members.group_id = recovery_steps_new.assignee_id) AND (group_members.user_id = auth.uid()))))) OR (EXISTS ( SELECT 1
   FROM public.user_profiles
  WHERE ((user_profiles.id = auth.uid()) AND (user_profiles.role = 'admin'::text))))));



--
-- Name: approval_tokens Users can view their own approval tokens; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own approval tokens" ON public.approval_tokens FOR SELECT USING ((approver_id = auth.uid()));


--
-- Name: activity_logs Users can view their own logs; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view their own logs" ON public.activity_logs FOR SELECT USING ((user_id = auth.uid()));



-- Create a policy to enable read access for all users on the "backup_run" table
CREATE POLICY "Enable read access for all users"
ON public.backup_run
FOR SELECT
TO public
USING (true);

-- Create a policy to enable read access for all users on the "backup_run" table
CREATE POLICY "Enable read access for all users"
ON public.resource_backup
FOR SELECT
TO public
USING (true);


--
-- Name: user_license Authenticated users can update licenses; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can update licenses"
    ON public.user_license
    FOR UPDATE
    TO authenticated
    USING (true)
    WITH CHECK (true);


CREATE POLICY "Edit"
ON public.datacenters2
FOR UPDATE
TO authenticated
USING (true)
WITH CHECK (true);


--
-- Name: role_permissions authenticated can read role permissions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "authenticated can read role permissions" ON public.role_permissions FOR SELECT TO authenticated USING (true);


--
-- Name: role_permissions settings managers can modify role permissions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "settings managers can modify role permissions" ON public.role_permissions FOR ALL TO authenticated USING (public.authorize('settings'::public.app_resource, 'manage'::public.app_action)) WITH CHECK (public.authorize('settings'::public.app_resource, 'manage'::public.app_action));


-- 6. New RLS: all authenticated users can view; only admins can modify
CREATE POLICY "Authenticated users can view SMTP settings"
    ON public.smtp_settings
    FOR SELECT
    USING (auth.uid() IS NOT NULL);

CREATE POLICY "Only admins can insert SMTP settings"
    ON public.smtp_settings
    FOR INSERT
    WITH CHECK (
        EXISTS (SELECT 1 FROM public.user_profiles WHERE id = auth.uid() AND role = 'admin')
    );

CREATE POLICY "Only admins can update SMTP settings"
    ON public.smtp_settings
    FOR UPDATE
    USING (
        EXISTS (SELECT 1 FROM public.user_profiles WHERE id = auth.uid() AND role = 'admin')
    )
    WITH CHECK (
        EXISTS (SELECT 1 FROM public.user_profiles WHERE id = auth.uid() AND role = 'admin')
    );

CREATE POLICY "Only admins can delete SMTP settings"
    ON public.smtp_settings
    FOR DELETE
    USING (
        EXISTS (SELECT 1 FROM public.user_profiles WHERE id = auth.uid() AND role = 'admin')
    );


--
-- Name: smtp_settings rbac_smtp_settings_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY rbac_smtp_settings_select ON public.smtp_settings FOR SELECT TO authenticated USING (public.authorize('settings'::public.app_resource, 'read'::public.app_action));


--
-- Name: smtp_settings rbac_smtp_settings_modify; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY rbac_smtp_settings_modify ON public.smtp_settings FOR ALL TO authenticated USING (public.authorize('settings'::public.app_resource, 'manage'::public.app_action)) WITH CHECK (public.authorize('settings'::public.app_resource, 'manage'::public.app_action));


--
-- Name: twilio_settings Authenticated users can delete Twilio settings; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can delete Twilio settings" ON public.twilio_settings FOR DELETE TO authenticated USING ((auth.role() = 'authenticated'::text));


--
-- Name: twilio_settings Authenticated users can insert Twilio settings; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can insert Twilio settings" ON public.twilio_settings FOR INSERT TO authenticated WITH CHECK ((auth.role() = 'authenticated'::text));


--
-- Name: twilio_settings Authenticated users can read Twilio settings; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can read Twilio settings" ON public.twilio_settings FOR SELECT TO authenticated USING ((auth.role() = 'authenticated'::text));


--
-- Name: twilio_settings Authenticated users can update Twilio settings; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can update Twilio settings" ON public.twilio_settings FOR UPDATE TO authenticated USING ((auth.role() = 'authenticated'::text)) WITH CHECK ((auth.role() = 'authenticated'::text));


--
-- Name: RLS policy for storage buckets
--

-- Enable RLS on storage.objects (if not already enabled)
alter table storage.objects enable row level security;

-- Allow authenticated users to download from any bucket
create policy "Allow authenticated downloads from all buckets"
on storage.objects
for select
to authenticated
using (true);

-- Allow authenticated users to upload to any bucket
create policy "Allow authenticated uploads to all buckets"
on storage.objects
for insert
to authenticated
with check (true);

--
-- Name: Enable realtime updates for tables
--

-- Add table to the publication that realtime listens to
alter publication supabase_realtime add table public.resource_backup;
alter publication supabase_realtime add table public.backup_run;
alter publication supabase_realtime add table public.snapshot_schedules;
alter publication supabase_realtime add table public.recovery_step_execution;
alter publication supabase_realtime add table public.recovery_plan_execution;

--
-- Name: activity_logs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.activity_logs ENABLE ROW LEVEL SECURITY;


--
-- Name: user_license; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_license ENABLE ROW LEVEL SECURITY;

--
-- Name: agent_commands; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.agent_commands ENABLE ROW LEVEL SECURITY;

--
-- Name: agent_response; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.agent_response ENABLE ROW LEVEL SECURITY;

--
-- Name: application_groups; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.application_groups ENABLE ROW LEVEL SECURITY;

--
-- Name: applications; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.applications ENABLE ROW LEVEL SECURITY;

--
-- Name: approval_tokens; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.approval_tokens ENABLE ROW LEVEL SECURITY;

--
-- Name: audit_logs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: backup_execution; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.backup_execution ENABLE ROW LEVEL SECURITY;

--
-- Name: backup_run; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.backup_run ENABLE ROW LEVEL SECURITY;

--
-- Name: backupcatalogs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.backupcatalogs ENABLE ROW LEVEL SECURITY;

--
-- Name: customers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;

--
-- Name: datacenters; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.datacenters ENABLE ROW LEVEL SECURITY;

--
-- Name: datacenters2; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.datacenters2 ENABLE ROW LEVEL SECURITY;

--
-- Name: disks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.disks ENABLE ROW LEVEL SECURITY;

--
-- Name: group_members; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.group_members ENABLE ROW LEVEL SECURITY;

--
-- Name: integration_configs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.integration_configs ENABLE ROW LEVEL SECURITY;

--
-- Name: internal_groups; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.internal_groups ENABLE ROW LEVEL SECURITY;

--
-- Name: license_logs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.license_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: licenses_backup; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.licenses_backup ENABLE ROW LEVEL SECURITY;

--
-- Name: organizations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;

--
-- Name: prices; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.prices ENABLE ROW LEVEL SECURITY;

--
-- Name: products; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;

--
-- Name: recovery_plan_audit_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recovery_plan_audit_log ENABLE ROW LEVEL SECURITY;

--
-- Name: recovery_plan_checkpoints; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recovery_plan_checkpoints ENABLE ROW LEVEL SECURITY;

--
-- Name: recovery_plan_progress; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recovery_plan_progress ENABLE ROW LEVEL SECURITY;

--
-- Name: recovery_plans; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recovery_plans ENABLE ROW LEVEL SECURITY;

--
-- Name: recovery_plans_new; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recovery_plans_new ENABLE ROW LEVEL SECURITY;

--
-- Name: recovery_steps; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recovery_steps ENABLE ROW LEVEL SECURITY;

--
-- Name: recovery_steps_new; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recovery_steps_new ENABLE ROW LEVEL SECURITY;

--
-- Name: resource_backup; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.resource_backup ENABLE ROW LEVEL SECURITY;

--
-- Name: role_permissions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;

--
-- Name: execution_run_reports; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.execution_run_reports ENABLE ROW LEVEL SECURITY;

--
-- Name: snapshot_schedules; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.snapshot_schedules ENABLE ROW LEVEL SECURITY;


--
-- Name: smtp_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.smtp_settings ENABLE ROW LEVEL SECURITY;


--
-- Name: twilio_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.twilio_settings ENABLE ROW LEVEL SECURITY;


--
-- Name: subscriptions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;

--
-- Name: sync_stats; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.sync_stats ENABLE ROW LEVEL SECURITY;

--
-- Name: tasktable; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tasktable ENABLE ROW LEVEL SECURITY;

--
-- Name: user_profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: users; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

--
-- Name: vmconfig; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.vmconfig ENABLE ROW LEVEL SECURITY;

--
-- Name: vms; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.vms ENABLE ROW LEVEL SECURITY;

--
-- Name: user_license; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_license ENABLE ROW LEVEL SECURITY;


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION email(); Type: ACL; Schema: auth; Owner: -
--

GRANT ALL ON FUNCTION auth.email() TO dashboard_user;
GRANT ALL ON FUNCTION auth.email() TO postgres;


--
-- Name: FUNCTION jwt(); Type: ACL; Schema: auth; Owner: -
--

GRANT ALL ON FUNCTION auth.jwt() TO postgres;
GRANT ALL ON FUNCTION auth.jwt() TO dashboard_user;


--
-- Name: FUNCTION role(); Type: ACL; Schema: auth; Owner: -
--

GRANT ALL ON FUNCTION auth.role() TO dashboard_user;
GRANT ALL ON FUNCTION auth.role() TO postgres;


--
-- Name: FUNCTION authorize(public.app_resource, public.app_action); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.authorize(public.app_resource, public.app_action) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.authorize(public.app_resource, public.app_action) TO authenticated;


--
-- Name: FUNCTION uid(); Type: ACL; Schema: auth; Owner: -
--

GRANT ALL ON FUNCTION auth.uid() TO dashboard_user;
GRANT ALL ON FUNCTION auth.uid() TO postgres;


--
-- Name: FUNCTION check_step_approval(step_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.check_step_approval(step_id uuid) TO anon;
GRANT ALL ON FUNCTION public.check_step_approval(step_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.check_step_approval(step_id uuid) TO service_role;


--
-- Name: FUNCTION ensure_user_profiles(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.ensure_user_profiles() TO anon;
GRANT ALL ON FUNCTION public.ensure_user_profiles() TO authenticated;
GRANT ALL ON FUNCTION public.ensure_user_profiles() TO service_role;


--
-- Name: FUNCTION handle_new_user(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.handle_new_user() TO anon;
GRANT ALL ON FUNCTION public.handle_new_user() TO authenticated;
GRANT ALL ON FUNCTION public.handle_new_user() TO service_role;


--
-- Name: FUNCTION handle_user_deletion(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.handle_user_deletion() TO anon;
GRANT ALL ON FUNCTION public.handle_user_deletion() TO authenticated;
GRANT ALL ON FUNCTION public.handle_user_deletion() TO service_role;


--
-- Name: FUNCTION is_admin(user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.is_admin(user_id uuid) TO anon;
GRANT ALL ON FUNCTION public.is_admin(user_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.is_admin(user_id uuid) TO service_role;


--
-- Name: FUNCTION log_license_action(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.log_license_action() TO anon;
GRANT ALL ON FUNCTION public.log_license_action() TO authenticated;
GRANT ALL ON FUNCTION public.log_license_action() TO service_role;


--
-- Name: FUNCTION log_user_action(action text, entity_id uuid, details jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.log_user_action(action text, entity_id uuid, details jsonb) TO anon;
GRANT ALL ON FUNCTION public.log_user_action(action text, entity_id uuid, details jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.log_user_action(action text, entity_id uuid, details jsonb) TO service_role;


--
-- Name: FUNCTION log_user_profile_deletion(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.log_user_profile_deletion() TO anon;
GRANT ALL ON FUNCTION public.log_user_profile_deletion() TO authenticated;
GRANT ALL ON FUNCTION public.log_user_profile_deletion() TO service_role;


--
-- Name: FUNCTION log_user_profile_update(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.log_user_profile_update() TO anon;
GRANT ALL ON FUNCTION public.log_user_profile_update() TO authenticated;
GRANT ALL ON FUNCTION public.log_user_profile_update() TO service_role;


--
-- Name: FUNCTION resolve_step_assignees(step_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.resolve_step_assignees(step_id uuid) TO anon;
GRANT ALL ON FUNCTION public.resolve_step_assignees(step_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.resolve_step_assignees(step_id uuid) TO service_role;


--
-- Name: FUNCTION update_customer_profile_timestamp(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.update_customer_profile_timestamp() TO anon;
GRANT ALL ON FUNCTION public.update_customer_profile_timestamp() TO authenticated;
GRANT ALL ON FUNCTION public.update_customer_profile_timestamp() TO service_role;


--
-- Name: FUNCTION update_modified_column(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.update_modified_column() TO anon;
GRANT ALL ON FUNCTION public.update_modified_column() TO authenticated;
GRANT ALL ON FUNCTION public.update_modified_column() TO service_role;


--
-- Name: FUNCTION update_updated_at_column(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.update_updated_at_column() TO anon;
GRANT ALL ON FUNCTION public.update_updated_at_column() TO authenticated;
GRANT ALL ON FUNCTION public.update_updated_at_column() TO service_role;


--
-- Name: FUNCTION update_user_role(user_id uuid, new_role text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.update_user_role(user_id uuid, new_role text) TO anon;
GRANT ALL ON FUNCTION public.update_user_role(user_id uuid, new_role text) TO authenticated;
GRANT ALL ON FUNCTION public.update_user_role(user_id uuid, new_role text) TO service_role;


--
-- Name: FUNCTION create_user_license_on_profile_insert(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.create_user_license_on_profile_insert() TO anon;
GRANT ALL ON FUNCTION public.create_user_license_on_profile_insert() TO authenticated;
GRANT ALL ON FUNCTION public.create_user_license_on_profile_insert() TO service_role;



--
-- Name: TABLE audit_log_entries; Type: ACL; Schema: auth; Owner: -
--

GRANT ALL ON TABLE auth.audit_log_entries TO dashboard_user;
GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE auth.audit_log_entries TO postgres;
GRANT SELECT ON TABLE auth.audit_log_entries TO postgres WITH GRANT OPTION;


--
-- Name: TABLE flow_state; Type: ACL; Schema: auth; Owner: -
--

GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE auth.flow_state TO postgres;
GRANT SELECT ON TABLE auth.flow_state TO postgres WITH GRANT OPTION;
GRANT ALL ON TABLE auth.flow_state TO dashboard_user;


--
-- Name: TABLE identities; Type: ACL; Schema: auth; Owner: -
--

GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE auth.identities TO postgres;
GRANT SELECT ON TABLE auth.identities TO postgres WITH GRANT OPTION;
GRANT ALL ON TABLE auth.identities TO dashboard_user;


--
-- Name: TABLE instances; Type: ACL; Schema: auth; Owner: -
--

GRANT ALL ON TABLE auth.instances TO dashboard_user;
GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE auth.instances TO postgres;
GRANT SELECT ON TABLE auth.instances TO postgres WITH GRANT OPTION;


--
-- Name: TABLE mfa_amr_claims; Type: ACL; Schema: auth; Owner: -
--

GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE auth.mfa_amr_claims TO postgres;
GRANT SELECT ON TABLE auth.mfa_amr_claims TO postgres WITH GRANT OPTION;
GRANT ALL ON TABLE auth.mfa_amr_claims TO dashboard_user;


--
-- Name: TABLE mfa_challenges; Type: ACL; Schema: auth; Owner: -
--

GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE auth.mfa_challenges TO postgres;
GRANT SELECT ON TABLE auth.mfa_challenges TO postgres WITH GRANT OPTION;
GRANT ALL ON TABLE auth.mfa_challenges TO dashboard_user;


--
-- Name: TABLE mfa_factors; Type: ACL; Schema: auth; Owner: -
--

GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE auth.mfa_factors TO postgres;
GRANT SELECT ON TABLE auth.mfa_factors TO postgres WITH GRANT OPTION;
GRANT ALL ON TABLE auth.mfa_factors TO dashboard_user;


--
-- Name: TABLE one_time_tokens; Type: ACL; Schema: auth; Owner: -
--

GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE auth.one_time_tokens TO postgres;
GRANT SELECT ON TABLE auth.one_time_tokens TO postgres WITH GRANT OPTION;
GRANT ALL ON TABLE auth.one_time_tokens TO dashboard_user;


--
-- Name: TABLE refresh_tokens; Type: ACL; Schema: auth; Owner: -
--

GRANT ALL ON TABLE auth.refresh_tokens TO dashboard_user;
GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE auth.refresh_tokens TO postgres;
GRANT SELECT ON TABLE auth.refresh_tokens TO postgres WITH GRANT OPTION;


--
-- Name: SEQUENCE refresh_tokens_id_seq; Type: ACL; Schema: auth; Owner: -
--

GRANT ALL ON SEQUENCE auth.refresh_tokens_id_seq TO dashboard_user;
GRANT ALL ON SEQUENCE auth.refresh_tokens_id_seq TO postgres;


--
-- Name: TABLE saml_providers; Type: ACL; Schema: auth; Owner: -
--

GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE auth.saml_providers TO postgres;
GRANT SELECT ON TABLE auth.saml_providers TO postgres WITH GRANT OPTION;
GRANT ALL ON TABLE auth.saml_providers TO dashboard_user;


--
-- Name: TABLE saml_relay_states; Type: ACL; Schema: auth; Owner: -
--

GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE auth.saml_relay_states TO postgres;
GRANT SELECT ON TABLE auth.saml_relay_states TO postgres WITH GRANT OPTION;
GRANT ALL ON TABLE auth.saml_relay_states TO dashboard_user;


--
-- Name: TABLE schema_migrations; Type: ACL; Schema: auth; Owner: -
--

GRANT ALL ON TABLE auth.schema_migrations TO dashboard_user;
GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE auth.schema_migrations TO postgres;
GRANT SELECT ON TABLE auth.schema_migrations TO postgres WITH GRANT OPTION;


--
-- Name: TABLE sessions; Type: ACL; Schema: auth; Owner: -
--

GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE auth.sessions TO postgres;
GRANT SELECT ON TABLE auth.sessions TO postgres WITH GRANT OPTION;
GRANT ALL ON TABLE auth.sessions TO dashboard_user;


--
-- Name: TABLE sso_domains; Type: ACL; Schema: auth; Owner: -
--

GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE auth.sso_domains TO postgres;
GRANT SELECT ON TABLE auth.sso_domains TO postgres WITH GRANT OPTION;
GRANT ALL ON TABLE auth.sso_domains TO dashboard_user;


--
-- Name: TABLE sso_providers; Type: ACL; Schema: auth; Owner: -
--

GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE auth.sso_providers TO postgres;
GRANT SELECT ON TABLE auth.sso_providers TO postgres WITH GRANT OPTION;
GRANT ALL ON TABLE auth.sso_providers TO dashboard_user;


--
-- Name: TABLE users; Type: ACL; Schema: auth; Owner: -
--

GRANT ALL ON TABLE auth.users TO dashboard_user;
GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE auth.users TO postgres;
GRANT SELECT ON TABLE auth.users TO postgres WITH GRANT OPTION;


--
-- Name: TABLE activity_logs; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.activity_logs TO anon;
GRANT ALL ON TABLE public.activity_logs TO authenticated;
GRANT ALL ON TABLE public.activity_logs TO service_role;


--
-- Name: TABLE agent_commands; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.agent_commands TO anon;
GRANT ALL ON TABLE public.agent_commands TO authenticated;
GRANT ALL ON TABLE public.agent_commands TO service_role;


--
-- Name: SEQUENCE agent_commands_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.agent_commands_id_seq TO anon;
GRANT ALL ON SEQUENCE public.agent_commands_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.agent_commands_id_seq TO service_role;


--
-- Name: TABLE agent_response; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.agent_response TO anon;
GRANT ALL ON TABLE public.agent_response TO authenticated;
GRANT ALL ON TABLE public.agent_response TO service_role;


--
-- Name: SEQUENCE agent_response_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.agent_response_id_seq TO anon;
GRANT ALL ON SEQUENCE public.agent_response_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.agent_response_id_seq TO service_role;


--
-- Name: TABLE application_groups; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.application_groups TO anon;
GRANT ALL ON TABLE public.application_groups TO authenticated;
GRANT ALL ON TABLE public.application_groups TO service_role;


--
-- Name: SEQUENCE application_groups_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.application_groups_id_seq TO anon;
GRANT ALL ON SEQUENCE public.application_groups_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.application_groups_id_seq TO service_role;


--
-- Name: TABLE applications; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.applications TO anon;
GRANT ALL ON TABLE public.applications TO authenticated;
GRANT ALL ON TABLE public.applications TO service_role;


--
-- Name: SEQUENCE applications_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.applications_id_seq TO anon;
GRANT ALL ON SEQUENCE public.applications_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.applications_id_seq TO service_role;


--
-- Name: TABLE approval_tokens; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.approval_tokens TO anon;
GRANT ALL ON TABLE public.approval_tokens TO authenticated;
GRANT ALL ON TABLE public.approval_tokens TO service_role;


--
-- Name: TABLE audit_logs; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.audit_logs TO anon;
GRANT ALL ON TABLE public.audit_logs TO authenticated;
GRANT ALL ON TABLE public.audit_logs TO service_role;


--
-- Name: TABLE execution_run_reports; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.execution_run_reports TO authenticated;
GRANT ALL ON TABLE public.execution_run_reports TO service_role;


--
-- Name: TABLE backup_execution; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.backup_execution TO anon;
GRANT ALL ON TABLE public.backup_execution TO authenticated;
GRANT ALL ON TABLE public.backup_execution TO service_role;


--
-- Name: TABLE backup_run; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.backup_run TO anon;
GRANT ALL ON TABLE public.backup_run TO authenticated;
GRANT ALL ON TABLE public.backup_run TO service_role;


--
-- Name: TABLE backupcatalogs; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.backupcatalogs TO anon;
GRANT ALL ON TABLE public.backupcatalogs TO authenticated;
GRANT ALL ON TABLE public.backupcatalogs TO service_role;


--
-- Name: SEQUENCE backupcatalogs_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.backupcatalogs_id_seq TO anon;
GRANT ALL ON SEQUENCE public.backupcatalogs_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.backupcatalogs_id_seq TO service_role;


--
-- Name: TABLE customers; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.customers TO anon;
GRANT ALL ON TABLE public.customers TO authenticated;
GRANT ALL ON TABLE public.customers TO service_role;


--
-- Name: TABLE datacenters; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.datacenters TO anon;
GRANT ALL ON TABLE public.datacenters TO authenticated;
GRANT ALL ON TABLE public.datacenters TO service_role;


--
-- Name: TABLE datacenters2; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.datacenters2 TO anon;
GRANT ALL ON TABLE public.datacenters2 TO authenticated;
GRANT ALL ON TABLE public.datacenters2 TO service_role;


--
-- Name: SEQUENCE datacenters2_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.datacenters2_id_seq TO anon;
GRANT ALL ON SEQUENCE public.datacenters2_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.datacenters2_id_seq TO service_role;


--
-- Name: SEQUENCE datacenters_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.datacenters_id_seq TO anon;
GRANT ALL ON SEQUENCE public.datacenters_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.datacenters_id_seq TO service_role;


--
-- Name: TABLE disks; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.disks TO anon;
GRANT ALL ON TABLE public.disks TO authenticated;
GRANT ALL ON TABLE public.disks TO service_role;


--
-- Name: TABLE group_members; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.group_members TO anon;
GRANT ALL ON TABLE public.group_members TO authenticated;
GRANT ALL ON TABLE public.group_members TO service_role;


--
-- Name: TABLE integration_configs; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.integration_configs TO anon;
GRANT ALL ON TABLE public.integration_configs TO authenticated;
GRANT ALL ON TABLE public.integration_configs TO service_role;


--
-- Name: TABLE internal_groups; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.internal_groups TO anon;
GRANT ALL ON TABLE public.internal_groups TO authenticated;
GRANT ALL ON TABLE public.internal_groups TO service_role;


--
-- Name: TABLE license_logs; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.license_logs TO anon;
GRANT ALL ON TABLE public.license_logs TO authenticated;
GRANT ALL ON TABLE public.license_logs TO service_role;


--
-- Name: TABLE licenses_backup; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.licenses_backup TO anon;
GRANT ALL ON TABLE public.licenses_backup TO authenticated;
GRANT ALL ON TABLE public.licenses_backup TO service_role;


--
-- Name: TABLE organizations; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.organizations TO anon;
GRANT ALL ON TABLE public.organizations TO authenticated;
GRANT ALL ON TABLE public.organizations TO service_role;


--
-- Name: TABLE prices; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.prices TO anon;
GRANT ALL ON TABLE public.prices TO authenticated;
GRANT ALL ON TABLE public.prices TO service_role;


--
-- Name: TABLE products; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.products TO anon;
GRANT ALL ON TABLE public.products TO authenticated;
GRANT ALL ON TABLE public.products TO service_role;


--
-- Name: TABLE recovery_plan_audit_log; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.recovery_plan_audit_log TO anon;
GRANT ALL ON TABLE public.recovery_plan_audit_log TO authenticated;
GRANT ALL ON TABLE public.recovery_plan_audit_log TO service_role;


--
-- Name: TABLE recovery_plan_checkpoints; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.recovery_plan_checkpoints TO anon;
GRANT ALL ON TABLE public.recovery_plan_checkpoints TO authenticated;
GRANT ALL ON TABLE public.recovery_plan_checkpoints TO service_role;


--
-- Name: TABLE recovery_plan_execution; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.recovery_plan_execution TO anon;
GRANT ALL ON TABLE public.recovery_plan_execution TO authenticated;
GRANT ALL ON TABLE public.recovery_plan_execution TO service_role;


--
-- Name: SEQUENCE recovery_plan_execution_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.recovery_plan_execution_id_seq TO anon;
GRANT ALL ON SEQUENCE public.recovery_plan_execution_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.recovery_plan_execution_id_seq TO service_role;


--
-- Name: TABLE recovery_plan_progress; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.recovery_plan_progress TO anon;
GRANT ALL ON TABLE public.recovery_plan_progress TO authenticated;
GRANT ALL ON TABLE public.recovery_plan_progress TO service_role;


--
-- Name: TABLE recovery_plans; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.recovery_plans TO anon;
GRANT ALL ON TABLE public.recovery_plans TO authenticated;
GRANT ALL ON TABLE public.recovery_plans TO service_role;


--
-- Name: TABLE recovery_plans_new; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.recovery_plans_new TO anon;
GRANT ALL ON TABLE public.recovery_plans_new TO authenticated;
GRANT ALL ON TABLE public.recovery_plans_new TO service_role;


--
-- Name: TABLE recovery_step_execution; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.recovery_step_execution TO anon;
GRANT ALL ON TABLE public.recovery_step_execution TO authenticated;
GRANT ALL ON TABLE public.recovery_step_execution TO service_role;


--
-- Name: SEQUENCE recovery_step_execution_step_execution_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.recovery_step_execution_step_execution_id_seq TO anon;
GRANT ALL ON SEQUENCE public.recovery_step_execution_step_execution_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.recovery_step_execution_step_execution_id_seq TO service_role;


--
-- Name: TABLE recovery_steps; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.recovery_steps TO anon;
GRANT ALL ON TABLE public.recovery_steps TO authenticated;
GRANT ALL ON TABLE public.recovery_steps TO service_role;


--
-- Name: TABLE recovery_steps_new; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.recovery_steps_new TO anon;
GRANT ALL ON TABLE public.recovery_steps_new TO authenticated;
GRANT ALL ON TABLE public.recovery_steps_new TO service_role;


--
-- Name: TABLE resource_backup; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.resource_backup TO anon;
GRANT ALL ON TABLE public.resource_backup TO authenticated;
GRANT ALL ON TABLE public.resource_backup TO service_role;


--
-- Name: TABLE role_permissions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.role_permissions TO anon;
GRANT ALL ON TABLE public.role_permissions TO authenticated;
GRANT ALL ON TABLE public.role_permissions TO service_role;



--
-- Name: TABLE smtp_settings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.smtp_settings TO anon;
GRANT ALL ON TABLE public.smtp_settings TO authenticated;
GRANT ALL ON TABLE public.smtp_settings TO service_role;


--
-- Name: TABLE twilio_settings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.twilio_settings TO authenticated;
GRANT ALL ON TABLE public.twilio_settings TO service_role;



--
-- Name: TABLE snapshot_schedules; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.snapshot_schedules TO anon;
GRANT ALL ON TABLE public.snapshot_schedules TO authenticated;
GRANT ALL ON TABLE public.snapshot_schedules TO service_role;


--
-- Name: TABLE subscriptions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.subscriptions TO anon;
GRANT ALL ON TABLE public.subscriptions TO authenticated;
GRANT ALL ON TABLE public.subscriptions TO service_role;


--
-- Name: TABLE sync_stats; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.sync_stats TO anon;
GRANT ALL ON TABLE public.sync_stats TO authenticated;
GRANT ALL ON TABLE public.sync_stats TO service_role;


--
-- Name: TABLE tasktable; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.tasktable TO anon;
GRANT ALL ON TABLE public.tasktable TO authenticated;
GRANT ALL ON TABLE public.tasktable TO service_role;


--
-- Name: TABLE user_license; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.user_license TO anon;
GRANT ALL ON TABLE public.user_license TO authenticated;
GRANT ALL ON TABLE public.user_license TO service_role;

--
-- Name: SEQUENCE tasktable_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.tasktable_id_seq TO anon;
GRANT ALL ON SEQUENCE public.tasktable_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.tasktable_id_seq TO service_role;


--
-- Name: SEQUENCE twilio_settings_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.twilio_settings_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.twilio_settings_id_seq TO service_role;


--
-- Name: TABLE user_profiles; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.user_profiles TO anon;
GRANT ALL ON TABLE public.user_profiles TO authenticated;
GRANT ALL ON TABLE public.user_profiles TO service_role;


--
-- Name: TABLE users; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.users TO anon;
GRANT ALL ON TABLE public.users TO authenticated;
GRANT ALL ON TABLE public.users TO service_role;


--
-- Name: TABLE vmconfig; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.vmconfig TO anon;
GRANT ALL ON TABLE public.vmconfig TO authenticated;
GRANT ALL ON TABLE public.vmconfig TO service_role;


--
-- Name: SEQUENCE vmconfig_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.vmconfig_id_seq TO anon;
GRANT ALL ON SEQUENCE public.vmconfig_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.vmconfig_id_seq TO service_role;


--
-- Name: TABLE vms; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.vms TO anon;
GRANT ALL ON TABLE public.vms TO authenticated;
GRANT ALL ON TABLE public.vms TO service_role;


--
-- Name: SEQUENCE vms_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.vms_id_seq TO anon;
GRANT ALL ON SEQUENCE public.vms_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.vms_id_seq TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: auth; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_auth_admin IN SCHEMA auth GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_auth_admin IN SCHEMA auth GRANT ALL ON SEQUENCES TO dashboard_user;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: auth; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_auth_admin IN SCHEMA auth GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_auth_admin IN SCHEMA auth GRANT ALL ON FUNCTIONS TO dashboard_user;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: auth; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_auth_admin IN SCHEMA auth GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_auth_admin IN SCHEMA auth GRANT ALL ON TABLES TO dashboard_user;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO service_role;
