begin;

-- Only the ID, owner and deletion revision survive a delete. No meal fields
-- remain, and this table is outside the exposed Data API schemas.
create table bitelens_private.meal_tombstones (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    revision bigint not null check (revision > 1)
);
create index meal_tombstones_user_id_idx on bitelens_private.meal_tombstones(user_id);
alter table bitelens_private.meal_tombstones enable row level security;
revoke all on table bitelens_private.meal_tombstones from public, anon, authenticated;

create function bitelens_private.sync_meal(
    p_meal_id uuid, p_user_id uuid, p_revision bigint, p_meal jsonb
)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
    caller_id uuid := auth.uid();
    is_deletion boolean := p_meal is null or p_meal = 'null'::jsonb;
    request_hash bytea;
    saved public.bitelens_meals%rowtype;
    tombstone bitelens_private.meal_tombstones%rowtype;
begin
    if caller_id is null or caller_id is distinct from bitelens_private.approved_owner_id()
       or p_user_id is distinct from caller_id
       or coalesce(auth.jwt()->>'is_anonymous', 'false') = 'true' then
        raise insufficient_privilege using message = 'BiteLens owner required';
    end if;
    if p_meal_id is null or p_revision is null or p_revision < 1 or (is_deletion and p_revision = 1) then
        raise invalid_parameter_value using message = 'Invalid meal identity or revision';
    end if;
    if not is_deletion then
        if (p_meal->>'user_id')::uuid is distinct from caller_id then
            raise insufficient_privilege using message = 'BiteLens owner required';
        end if;
        if (p_meal->>'id')::uuid is distinct from p_meal_id then
            raise invalid_parameter_value using message = 'Invalid meal identity';
        end if;
        if pg_catalog.jsonb_typeof(p_meal) is distinct from 'object'
           or p_meal - array['id', 'user_id', 'meal_at_epoch_seconds', 'local_date', 'time_zone',
                             'confirmed_at_epoch_seconds',
                             'notes', 'estimate_provider', 'estimate_model', 'estimate_version', 'items'] <> '{}'::jsonb
           or pg_catalog.jsonb_typeof(p_meal->'items') is distinct from 'array' then
            raise invalid_parameter_value using message = 'Invalid structured meal';
        end if;
        if pg_catalog.jsonb_array_length(p_meal->'items') = 0 or exists (
            select 1
            from pg_catalog.jsonb_array_elements(p_meal->'items') as entry(item)
            where case when pg_catalog.jsonb_typeof(item) <> 'object' then true
                  else item - array['id', 'name', 'description', 'portion_grams', 'serving_description',
                                    'calories_kcal', 'protein_grams', 'carbohydrates_grams', 'fat_grams',
                                    'fiber_grams', 'sodium_milligrams'] <> '{}'::jsonb end
        ) then
            raise invalid_parameter_value using message = 'Invalid meal items';
        end if;
        request_hash := pg_catalog.sha256(pg_catalog.convert_to(p_meal::text, 'UTF8'));
    end if;

    -- One transaction per meal ID, even when neither row exists yet. Any
    -- advisory hash collision just serializes two unrelated meals.
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_meal_id::text, 631119));
    select * into tombstone from bitelens_private.meal_tombstones where id = p_meal_id;
    if found then
        if is_deletion and tombstone.user_id = caller_id and tombstone.revision = p_revision then
            return pg_catalog.jsonb_build_object('id', p_meal_id, 'revision', p_revision);
        end if;
        raise unique_violation using message = 'Meal already deleted';
    end if;

    select * into saved from public.bitelens_meals where id = p_meal_id;
    if found then
        if saved.user_id is distinct from caller_id or p_revision < saved.revision then
            raise unique_violation using message = 'Meal conflicts with an existing record';
        end if;
        if p_revision = saved.revision then
            if not is_deletion and saved.payload_hash = request_hash then
                return pg_catalog.jsonb_build_object('id', p_meal_id, 'revision', p_revision);
            end if;
            raise unique_violation using message = 'Meal revision conflicts with an existing record';
        end if;
    end if;

    if is_deletion then
        delete from public.bitelens_meals where id = p_meal_id and user_id = caller_id;
        insert into bitelens_private.meal_tombstones(id, user_id, revision)
        values (p_meal_id, caller_id, p_revision);
        return pg_catalog.jsonb_build_object('id', p_meal_id, 'revision', p_revision);
    end if;

    if saved.id is not null then
        if saved.confirmed_at is distinct from pg_catalog.to_timestamp((p_meal->>'confirmed_at_epoch_seconds')::double precision)
           or saved.estimate_provider is distinct from (p_meal->>'estimate_provider')
           or saved.estimate_model is distinct from (p_meal->>'estimate_model')
           or saved.estimate_version is distinct from (p_meal->>'estimate_version') then
            raise invalid_parameter_value using message = 'Meal confirmation and provenance are immutable';
        end if;
        update public.bitelens_meals
        set revision = p_revision, payload_hash = request_hash,
            meal_at = pg_catalog.to_timestamp((p_meal->>'meal_at_epoch_seconds')::double precision),
            local_date = (p_meal->>'local_date')::date, time_zone = p_meal->>'time_zone',
            notes = p_meal->>'notes'
        where id = p_meal_id and user_id = caller_id;
        delete from public.bitelens_meal_items where meal_id = p_meal_id and user_id = caller_id;
    else
        insert into public.bitelens_meals (
            id, user_id, revision, payload_hash, meal_at, local_date, time_zone, confirmed_at, notes,
            estimate_provider, estimate_model, estimate_version
        ) values (
            p_meal_id, caller_id, p_revision, request_hash, pg_catalog.to_timestamp((p_meal->>'meal_at_epoch_seconds')::double precision),
            (p_meal->>'local_date')::date, p_meal->>'time_zone',
            pg_catalog.to_timestamp((p_meal->>'confirmed_at_epoch_seconds')::double precision), p_meal->>'notes',
            p_meal->>'estimate_provider', p_meal->>'estimate_model', p_meal->>'estimate_version'
        );
    end if;

    insert into public.bitelens_meal_items (
        id, user_id, meal_id, position, name, description, portion_grams, serving_description,
        calories_kcal, protein_grams, carbohydrates_grams, fat_grams, fiber_grams, sodium_milligrams
    )
    select item.id, caller_id, p_meal_id, entry.ordinality - 1, item.name, item.description,
           item.portion_grams, item.serving_description, item.calories_kcal, item.protein_grams,
           item.carbohydrates_grams, item.fat_grams, item.fiber_grams, item.sodium_milligrams
    from pg_catalog.jsonb_array_elements(p_meal->'items') with ordinality as entry(value, ordinality)
    cross join lateral pg_catalog.jsonb_to_record(entry.value) as item(
        id uuid, name text, description text, portion_grams double precision, serving_description text,
        calories_kcal double precision, protein_grams double precision, carbohydrates_grams double precision,
        fat_grams double precision, fiber_grams double precision, sodium_milligrams double precision
    );

    return pg_catalog.jsonb_build_object('id', p_meal_id, 'revision', p_revision);
end;
$$;
revoke all on function bitelens_private.sync_meal(uuid, uuid, bigint, jsonb) from public, anon, authenticated;
grant execute on function bitelens_private.sync_meal(uuid, uuid, bigint, jsonb) to authenticated;

create function public.bitelens_sync_meal(
    p_meal_id uuid, p_user_id uuid, p_revision bigint, p_meal jsonb
)
returns jsonb
language sql volatile security invoker
set search_path = ''
as $$
    select bitelens_private.sync_meal(p_meal_id, p_user_id, p_revision, p_meal);
$$;
revoke all on function public.bitelens_sync_meal(uuid, uuid, bigint, jsonb) from public, anon, authenticated;
grant execute on function public.bitelens_sync_meal(uuid, uuid, bigint, jsonb) to authenticated;

-- An older app can still replay a revision 1 create, but it must also honor
-- tombstones and must not bypass serialization or overwrite a newer revision.
create or replace function bitelens_private.create_meal(p_meal jsonb)
returns jsonb
language sql volatile security invoker
set search_path = ''
as $$
    select bitelens_private.sync_meal((p_meal->>'id')::uuid, (p_meal->>'user_id')::uuid, 1, p_meal);
$$;
revoke all on function bitelens_private.create_meal(jsonb) from public, anon, authenticated;
grant execute on function bitelens_private.create_meal(jsonb) to authenticated;

notify pgrst, 'reload schema';
commit;
