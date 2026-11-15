begin;

create table public.bitelens_observations (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    revision bigint not null check (revision > 0),
    payload_hash bytea check (pg_catalog.octet_length(payload_hash) = 32),
    kind text,
    symptom_id text,
    observed_at timestamptz check (pg_catalog.isfinite(observed_at)),
    local_date date check (pg_catalog.isfinite(local_date)),
    time_zone text check (time_zone ~ '[^[:space:]]'),
    level text check (level in ('mild', 'moderate', 'severe')),
    notes text,
    meal_id uuid,
    created_at timestamptz not null,
    updated_at timestamptz not null,
    deleted_at timestamptz,
    foreign key (user_id, meal_id) references public.bitelens_meals(user_id, id) on delete set null (meal_id),
    constraint bitelens_observations_kind_check check (
        case kind
            when 'symptom' then symptom_id is not null and meal_id is null
            when 'bingeEatingUrge' then symptom_id is null
            else kind is null and deleted_at is not null
        end
    ),
    constraint bitelens_observations_catalog_check check (symptom_id in (
        'abdominalCramps', 'acne', 'appetiteChanges', 'bladderIncontinence', 'bloating',
        'breastPain', 'chestTightnessOrPain', 'chills', 'constipation', 'coughing',
        'diarrhea', 'dizziness', 'drySkin', 'fainting', 'fatigue', 'fever',
        'generalizedBodyAche', 'hairLoss', 'headache', 'heartburn', 'hotFlashes',
        'lossOfSmell', 'lossOfTaste', 'lowerBackPain', 'memoryLapse', 'moodChanges',
        'nausea', 'nightSweats', 'pelvicPain', 'rapidPoundingOrFlutteringHeartbeat',
        'runnyNose', 'shortnessOfBreath', 'sinusCongestion', 'skippedHeartbeat',
        'sleepChanges', 'soreThroat', 'vaginalDryness', 'vomiting', 'wheezing'
    )),
    constraint bitelens_observations_state_check check (
        case when deleted_at is null then
            kind is not null and payload_hash is not null and observed_at is not null
            and local_date is not null and time_zone is not null
        else
            revision > 1 and kind is null and symptom_id is null and payload_hash is null
            and observed_at is null and local_date is null and time_zone is null
            and level is null and notes is null and meal_id is null and deleted_at = updated_at
        end
    )
);

create index bitelens_observations_owner_updated_at_idx
    on public.bitelens_observations (user_id, updated_at, id);
create index bitelens_observations_meal_idx
    on public.bitelens_observations (user_id, meal_id) where meal_id is not null;

alter table public.bitelens_observations enable row level security;
revoke all on table public.bitelens_observations from public, anon, authenticated;
grant select on table public.bitelens_observations to authenticated;

create policy bitelens_observations_owner_read on public.bitelens_observations for select to authenticated
using (
    user_id = (select auth.uid())
    and user_id = (select bitelens_private.approved_owner_id())
    and coalesce((select auth.jwt())->>'is_anonymous', 'false') <> 'true'
);

-- Foreign-key unlink updates are server changes at the existing client revision.
create function bitelens_private.stamp_observation_update()
returns trigger
language plpgsql security invoker
set search_path = ''
as $$
begin
    new.updated_at := greatest(pg_catalog.clock_timestamp(), old.updated_at + interval '1 microsecond');
    if new.deleted_at is not null then
        new.deleted_at := new.updated_at;
    end if;
    return new;
end;
$$;
revoke all on function bitelens_private.stamp_observation_update() from public, anon, authenticated;

create trigger bitelens_observations_stamp_update
    before update on public.bitelens_observations for each row
    execute function bitelens_private.stamp_observation_update();

create function bitelens_private.sync_observation(
    p_observation_id uuid, p_user_id uuid, p_revision bigint, p_observation jsonb
)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
    caller_id uuid := auth.uid();
    is_deletion boolean := p_observation is null or p_observation = 'null'::jsonb;
    acknowledgement jsonb := pg_catalog.jsonb_build_object('id', p_observation_id, 'revision', p_revision);
    request_hash bytea;
    saved public.bitelens_observations%rowtype;
    entry_kind text;
    symptom text;
    linked_meal_id uuid;
    observed_at timestamptz;
    written_at timestamptz;
begin
    if caller_id is null or caller_id is distinct from bitelens_private.approved_owner_id()
       or p_user_id is distinct from caller_id
       or coalesce(auth.jwt()->>'is_anonymous', 'false') = 'true' then
        raise insufficient_privilege using message = 'BiteLens owner required';
    end if;
    if p_observation_id is null or p_revision is null or p_revision < 1 or (is_deletion and p_revision = 1) then
        raise invalid_parameter_value using message = 'Invalid observation identity or revision';
    end if;
    if not is_deletion then
        if pg_catalog.jsonb_typeof(p_observation) is distinct from 'object' then
            raise invalid_parameter_value using message = 'Invalid structured observation';
        end if;
        if (p_observation->>'user_id')::uuid is distinct from caller_id then
            raise insufficient_privilege using message = 'BiteLens owner required';
        end if;
        if (p_observation->>'id')::uuid is distinct from p_observation_id then
            raise invalid_parameter_value using message = 'Invalid observation identity';
        end if;
        if pg_catalog.jsonb_typeof(p_observation->'observed_at_epoch_seconds') is distinct from 'number'
           or not coalesce(p_observation->>'local_date' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$', false)
           or exists (
                select 1 from pg_catalog.jsonb_each(p_observation - 'observed_at_epoch_seconds') as field(key, value)
                where case
                    when key in ('id', 'user_id', 'kind', 'local_date', 'time_zone') then
                        pg_catalog.jsonb_typeof(value) <> 'string'
                    when key in ('symptom_id', 'level', 'notes', 'meal_id') then
                        pg_catalog.jsonb_typeof(value) not in ('string', 'null')
                    else true
                end
           ) then
            raise invalid_parameter_value using message = 'Invalid structured observation';
        end if;
        request_hash := pg_catalog.sha256(pg_catalog.convert_to(p_observation::text, 'UTF8'));
    end if;

    -- Serialize competing client revisions even before the observation exists.
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_observation_id::text, 631120));
    select * into saved from public.bitelens_observations where id = p_observation_id;
    if found then
        if saved.user_id is distinct from caller_id then
            raise unique_violation using message = 'Observation conflicts with an existing record';
        end if;
        if p_revision = saved.revision and (
            (is_deletion and saved.deleted_at is not null)
            or (not is_deletion and saved.payload_hash = request_hash)
        ) then
            return acknowledgement;
        end if;
        if saved.deleted_at is not null or p_revision <= saved.revision then
            raise unique_violation using message = 'Observation revision conflicts with an existing record';
        end if;
    end if;

    written_at := pg_catalog.clock_timestamp();
    if is_deletion then
        if saved.id is null then
            insert into public.bitelens_observations (id, user_id, revision, created_at, updated_at, deleted_at)
            values (p_observation_id, caller_id, p_revision, written_at, written_at, written_at);
        else
            update public.bitelens_observations
            set revision = p_revision, payload_hash = null, kind = null, symptom_id = null,
                observed_at = null, local_date = null, time_zone = null, level = null, notes = null,
                meal_id = null, deleted_at = written_at
            where id = p_observation_id and user_id = caller_id;
        end if;
        return acknowledgement;
    end if;

    entry_kind := p_observation->>'kind';
    symptom := p_observation->>'symptom_id';
    linked_meal_id := (p_observation->>'meal_id')::uuid;
    observed_at := pg_catalog.to_timestamp((p_observation->>'observed_at_epoch_seconds')::double precision);
    if observed_at > written_at then
        raise invalid_parameter_value using message = 'Observation time is in the future';
    end if;
    if saved.id is not null and (entry_kind is distinct from saved.kind or symptom is distinct from saved.symptom_id) then
        raise invalid_parameter_value using message = 'Observation kind and symptom are immutable';
    end if;

    if linked_meal_id is not null then
        -- Lock the referenced meal before taking an observation row lock, the same
        -- order used by a meal deletion and its foreign-key unlink.
        perform 1 from public.bitelens_meals
        where id = linked_meal_id and user_id = caller_id
        for key share;
        if not found then
            raise foreign_key_violation using message = 'Observation requires an active meal owned by the caller';
        end if;
    end if;

    written_at := pg_catalog.clock_timestamp();
    insert into public.bitelens_observations (
        id, user_id, revision, payload_hash, kind, symptom_id, observed_at, local_date, time_zone,
        level, notes, meal_id, created_at, updated_at
    ) values (
        p_observation_id, caller_id, p_revision, request_hash, entry_kind, symptom, observed_at,
        (p_observation->>'local_date')::date, p_observation->>'time_zone', p_observation->>'level',
        p_observation->>'notes', linked_meal_id, written_at, written_at
    )
    on conflict (id) do update
    set revision = excluded.revision, payload_hash = excluded.payload_hash,
        observed_at = excluded.observed_at, local_date = excluded.local_date, time_zone = excluded.time_zone,
        level = excluded.level, notes = excluded.notes, meal_id = excluded.meal_id;

    return acknowledgement;
end;
$$;
revoke all on function bitelens_private.sync_observation(uuid, uuid, bigint, jsonb) from public, anon, authenticated;
grant execute on function bitelens_private.sync_observation(uuid, uuid, bigint, jsonb) to authenticated;

create function public.bitelens_sync_observation(
    p_observation_id uuid, p_user_id uuid, p_revision bigint, p_observation jsonb
)
returns jsonb
language sql volatile security invoker
set search_path = ''
as $$
    select bitelens_private.sync_observation(p_observation_id, p_user_id, p_revision, p_observation);
$$;
revoke all on function public.bitelens_sync_observation(uuid, uuid, bigint, jsonb) from public, anon, authenticated;
grant execute on function public.bitelens_sync_observation(uuid, uuid, bigint, jsonb) to authenticated;

commit;
