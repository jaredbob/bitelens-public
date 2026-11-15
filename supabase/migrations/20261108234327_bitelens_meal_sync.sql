begin;

create schema bitelens_private;
revoke all on schema bitelens_private from public, anon, authenticated;
grant usage on schema bitelens_private to authenticated;

-- The administrator selects the single approved Auth account after deployment.
create table bitelens_private.approved_owner (
    singleton boolean primary key default true check (singleton),
    user_id uuid not null references auth.users(id) on delete cascade
);
alter table bitelens_private.approved_owner enable row level security;
revoke all on table bitelens_private.approved_owner from public, anon, authenticated;

create function bitelens_private.approved_owner_id()
returns uuid
language sql stable security definer
set search_path = ''
as $$
    select user_id from bitelens_private.approved_owner;
$$;
revoke all on function bitelens_private.approved_owner_id() from public, anon, authenticated;
grant execute on function bitelens_private.approved_owner_id() to authenticated;

create table public.bitelens_meals (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    revision bigint not null default 1 check (revision > 0),
    payload_hash bytea not null check (pg_catalog.octet_length(payload_hash) = 32),
    meal_at timestamptz not null check (pg_catalog.isfinite(meal_at)),
    local_date date not null check (pg_catalog.isfinite(local_date)),
    time_zone text not null check (time_zone ~ '[^[:space:]]'),
    confirmed_at timestamptz not null check (pg_catalog.isfinite(confirmed_at)),
    notes text not null,
    estimate_provider text,
    estimate_model text,
    estimate_version text,
    unique (user_id, id),
    check (
        (estimate_provider is null and estimate_model is null and estimate_version is null)
        or
        (estimate_provider is not null and estimate_provider in ('openai', 'grok')
         and estimate_model is not null and estimate_model ~ '[^[:space:]]')
    )
);

create table public.bitelens_meal_items (
    id uuid primary key,
    user_id uuid not null,
    meal_id uuid not null,
    position integer not null check (position >= 0),
    name text not null check (name ~ '[^[:space:]]'),
    description text not null,
    portion_grams double precision check (portion_grams >= 0 and portion_grams < 'Infinity'),
    serving_description text not null,
    calories_kcal double precision check (calories_kcal >= 0 and calories_kcal < 'Infinity'),
    protein_grams double precision check (protein_grams >= 0 and protein_grams < 'Infinity'),
    carbohydrates_grams double precision check (carbohydrates_grams >= 0 and carbohydrates_grams < 'Infinity'),
    fat_grams double precision check (fat_grams >= 0 and fat_grams < 'Infinity'),
    fiber_grams double precision check (fiber_grams >= 0 and fiber_grams < 'Infinity'),
    sodium_milligrams double precision check (sodium_milligrams >= 0 and sodium_milligrams < 'Infinity'),
    unique (user_id, meal_id, position),
    foreign key (user_id, meal_id) references public.bitelens_meals(user_id, id) on delete cascade
);

alter table public.bitelens_meals enable row level security;
alter table public.bitelens_meal_items enable row level security;
revoke all on table public.bitelens_meals, public.bitelens_meal_items from public, anon, authenticated;
grant select on table public.bitelens_meals, public.bitelens_meal_items to authenticated;

create policy bitelens_meals_owner_read on public.bitelens_meals for select to authenticated
using (user_id = (select auth.uid()) and (select auth.uid()) = (select bitelens_private.approved_owner_id()));
create policy bitelens_meal_items_owner_read on public.bitelens_meal_items for select to authenticated
using (user_id = (select auth.uid()) and (select auth.uid()) = (select bitelens_private.approved_owner_id()));

-- The client has SELECT only. This narrow definer is required to write both
-- tables without opening a separate, non-atomic client write path.
create function bitelens_private.create_meal(p_meal jsonb)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
    caller_id uuid := auth.uid();
    meal_id uuid;
    request_hash bytea;
    inserted boolean;
    accepted_revision bigint;
begin
    if caller_id is null or caller_id is distinct from bitelens_private.approved_owner_id()
       or (p_meal->>'user_id')::uuid is distinct from caller_id then
        raise insufficient_privilege using message = 'BiteLens owner required';
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

    meal_id := (p_meal->>'id')::uuid;
    request_hash := pg_catalog.sha256(pg_catalog.convert_to(p_meal::text, 'UTF8'));
    insert into public.bitelens_meals (
        id, user_id, payload_hash, meal_at, local_date, time_zone, confirmed_at, notes,
        estimate_provider, estimate_model, estimate_version
    ) values (
        meal_id, caller_id, request_hash, pg_catalog.to_timestamp((p_meal->>'meal_at_epoch_seconds')::double precision),
        (p_meal->>'local_date')::date, p_meal->>'time_zone',
        pg_catalog.to_timestamp((p_meal->>'confirmed_at_epoch_seconds')::double precision), p_meal->>'notes',
        p_meal->>'estimate_provider', p_meal->>'estimate_model', p_meal->>'estimate_version'
    )
    on conflict (id) do nothing
    returning true into inserted;

    if inserted then
        insert into public.bitelens_meal_items (
            id, user_id, meal_id, position, name, description, portion_grams, serving_description,
            calories_kcal, protein_grams, carbohydrates_grams, fat_grams, fiber_grams, sodium_milligrams
        )
        select item.id, caller_id, meal_id, entry.ordinality - 1, item.name, item.description,
               item.portion_grams, item.serving_description, item.calories_kcal, item.protein_grams,
               item.carbohydrates_grams, item.fat_grams, item.fiber_grams, item.sodium_milligrams
        from pg_catalog.jsonb_array_elements(p_meal->'items') with ordinality as entry(value, ordinality)
        cross join lateral pg_catalog.jsonb_to_record(entry.value) as item(
            id uuid, name text, description text, portion_grams double precision, serving_description text,
            calories_kcal double precision, protein_grams double precision, carbohydrates_grams double precision,
            fat_grams double precision, fiber_grams double precision, sodium_milligrams double precision
        );
        accepted_revision := 1;
    else
        -- The unique insert waits for concurrent creates. A replay may
        -- acknowledge only the same owner, revision, and complete snapshot.
        select saved.revision into accepted_revision
        from public.bitelens_meals as saved
        where saved.id = meal_id and saved.user_id = caller_id
          and saved.revision = 1 and saved.payload_hash = request_hash
        for update;
        if accepted_revision is null then
            raise unique_violation using message = 'Meal create conflicts with an existing record';
        end if;
    end if;

    return pg_catalog.jsonb_build_object('id', meal_id, 'revision', accepted_revision);
end;
$$;

revoke all on function bitelens_private.create_meal(jsonb) from public, anon, authenticated;
grant execute on function bitelens_private.create_meal(jsonb) to authenticated;

create function public.bitelens_create_meal(p_meal jsonb)
returns jsonb
language sql volatile security invoker
set search_path = ''
as $$
    select bitelens_private.create_meal(p_meal);
$$;

revoke all on function public.bitelens_create_meal(jsonb) from public, anon, authenticated;
grant execute on function public.bitelens_create_meal(jsonb) to authenticated;

notify pgrst, 'reload schema';
commit;
