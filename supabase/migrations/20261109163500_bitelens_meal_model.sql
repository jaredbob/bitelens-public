begin;

-- Existing rows have no verified server write times.
alter table public.bitelens_meals
    add column created_at timestamptz,
    add column updated_at timestamptz;
create index bitelens_meals_owner_updated_at_idx
    on public.bitelens_meals (user_id, updated_at, id)
    where updated_at is not null;

alter table public.bitelens_meal_items
    add column consumed_count double precision check (consumed_count > 0 and consumed_count < 'Infinity'),
    add column alcohol_grams double precision check (alcohol_grams >= 0 and alcohol_grams < 'Infinity'),
    add column caffeine_milligrams double precision check (caffeine_milligrams >= 0 and caffeine_milligrams < 'Infinity'),
    add column added_sugar_grams double precision check (added_sugar_grams >= 0 and added_sugar_grams < 'Infinity'),
    add column item_origin text,
    add column original_item_estimate jsonb,
    add column is_corrected boolean,
    add constraint bitelens_item_origin_check check (
        case item_origin
            when 'ai' then original_item_estimate is not null and is_corrected is not null
            when 'manual' then original_item_estimate is null and is_corrected is null
            else item_origin is null and original_item_estimate is null and is_corrected is null
        end
    );

-- Accept only structured item values in the comparison, including unknowns.
create function bitelens_private.valid_item_estimate(p_values jsonb, p_keys text[])
returns boolean
language sql immutable
set search_path = ''
as $$
    select case
        when pg_catalog.jsonb_typeof(p_values) is distinct from 'object' then false
        when p_values - p_keys <> '{}'::jsonb
            or pg_catalog.jsonb_typeof(p_values->'name') is distinct from 'string'
            or pg_catalog.btrim(p_values->>'name') = ''
            or pg_catalog.jsonb_typeof(p_values->'description') is distinct from 'string'
            or pg_catalog.jsonb_typeof(p_values->'serving_description') is distinct from 'string' then false
        else not exists (
            select 1
            from pg_catalog.jsonb_each(p_values - array['name', 'description', 'serving_description']) as field(key, value)
            where case pg_catalog.jsonb_typeof(value)
                when 'null' then false
                when 'number' then (value #>> '{}')::double precision < 0
                    or (key = 'consumed_count' and (value #>> '{}')::double precision = 0)
                else true
            end
        )
    end;
$$;
revoke all on function bitelens_private.valid_item_estimate(jsonb, text[]) from public, anon, authenticated;

create or replace function bitelens_private.sync_meal(
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
    written_at timestamptz;
    value_keys constant text[] := array['name', 'description', 'portion_grams', 'serving_description',
        'calories_kcal', 'protein_grams', 'carbohydrates_grams', 'fat_grams', 'fiber_grams', 'sodium_milligrams',
        'consumed_count', 'alcohol_grams', 'caffeine_milligrams', 'added_sugar_grams'];
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
                  else item - (value_keys || array['id', 'item_origin', 'original_item_estimate']) <> '{}'::jsonb
                    or case item->>'item_origin'
                        when 'ai' then p_meal->>'estimate_provider' is null
                          or not bitelens_private.valid_item_estimate(item->'original_item_estimate', value_keys)
                          or not bitelens_private.valid_item_estimate(
                            item - array['id', 'item_origin', 'original_item_estimate'], value_keys)
                        when 'manual' then coalesce(item->'original_item_estimate', 'null'::jsonb) <> 'null'::jsonb
                        else item->>'item_origin' is not null
                          or coalesce(item->'original_item_estimate', 'null'::jsonb) <> 'null'::jsonb
                    end
                  end
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

    written_at := pg_catalog.clock_timestamp();
    if saved.id is not null then
        if saved.confirmed_at is distinct from pg_catalog.to_timestamp((p_meal->>'confirmed_at_epoch_seconds')::double precision)
           or saved.estimate_provider is distinct from (p_meal->>'estimate_provider')
           or saved.estimate_model is distinct from (p_meal->>'estimate_model')
           or saved.estimate_version is distinct from (p_meal->>'estimate_version') then
            raise invalid_parameter_value using message = 'Meal confirmation and provenance are immutable';
        end if;
        -- A snapshot may remove an item. For a surviving item, its known origin
        -- and original values are fixed across revisions.
        if exists (
            select 1
            from pg_catalog.jsonb_array_elements(p_meal->'items') as incoming(item)
            join public.bitelens_meal_items as old on old.id = (incoming.item->>'id')::uuid
            where old.meal_id = p_meal_id and old.user_id = caller_id and old.item_origin is not null
              and (old.item_origin is distinct from incoming.item->>'item_origin'
                   or old.original_item_estimate is distinct from
                       nullif(pg_catalog.jsonb_strip_nulls(incoming.item->'original_item_estimate'), 'null'::jsonb))
        ) then
            raise invalid_parameter_value using message = 'Original item estimates and origins are immutable';
        end if;
        update public.bitelens_meals
        set revision = p_revision, payload_hash = request_hash, updated_at = written_at,
            meal_at = pg_catalog.to_timestamp((p_meal->>'meal_at_epoch_seconds')::double precision),
            local_date = (p_meal->>'local_date')::date, time_zone = p_meal->>'time_zone',
            notes = p_meal->>'notes'
        where id = p_meal_id and user_id = caller_id;
        delete from public.bitelens_meal_items where meal_id = p_meal_id and user_id = caller_id;
    else
        insert into public.bitelens_meals (
            id, user_id, revision, payload_hash, meal_at, local_date, time_zone, confirmed_at, notes,
            estimate_provider, estimate_model, estimate_version, created_at, updated_at
        ) values (
            p_meal_id, caller_id, p_revision, request_hash, pg_catalog.to_timestamp((p_meal->>'meal_at_epoch_seconds')::double precision),
            (p_meal->>'local_date')::date, p_meal->>'time_zone',
            pg_catalog.to_timestamp((p_meal->>'confirmed_at_epoch_seconds')::double precision), p_meal->>'notes',
            p_meal->>'estimate_provider', p_meal->>'estimate_model', p_meal->>'estimate_version', written_at, written_at
        );
    end if;

    insert into public.bitelens_meal_items (
        id, user_id, meal_id, position, name, description, portion_grams, serving_description,
        calories_kcal, protein_grams, carbohydrates_grams, fat_grams, fiber_grams, sodium_milligrams,
        consumed_count, alcohol_grams, caffeine_milligrams, added_sugar_grams,
        item_origin, original_item_estimate, is_corrected
    )
    select item.id, caller_id, p_meal_id, entry.ordinality - 1, item.name, item.description,
           item.portion_grams, item.serving_description, item.calories_kcal, item.protein_grams,
           item.carbohydrates_grams, item.fat_grams, item.fiber_grams, item.sodium_milligrams,
           item.consumed_count, item.alcohol_grams, item.caffeine_milligrams, item.added_sugar_grams,
           item.item_origin, pg_catalog.jsonb_strip_nulls(item.original_item_estimate),
           case when item.item_origin = 'ai' then
               pg_catalog.jsonb_strip_nulls(entry.value - array['id', 'item_origin', 'original_item_estimate'])
                   <> pg_catalog.jsonb_strip_nulls(item.original_item_estimate)
           end
    from pg_catalog.jsonb_array_elements(p_meal->'items') with ordinality as entry(value, ordinality)
    cross join lateral pg_catalog.jsonb_to_record(entry.value) as item(
        id uuid, name text, description text, portion_grams double precision, serving_description text,
        calories_kcal double precision, protein_grams double precision, carbohydrates_grams double precision,
        fat_grams double precision, fiber_grams double precision, sodium_milligrams double precision,
        consumed_count double precision, alcohol_grams double precision, caffeine_milligrams double precision,
        added_sugar_grams double precision, item_origin text, original_item_estimate jsonb
    );

    return pg_catalog.jsonb_build_object('id', p_meal_id, 'revision', p_revision);
end;
$$;

notify pgrst, 'reload schema';
commit;
