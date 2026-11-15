begin;

create table bitelens_private.meal_estimate_allowances (
    user_id uuid not null references auth.users(id) on delete cascade,
    utc_day date not null,
    attempts integer not null check (attempts > 0),
    primary key (user_id, utc_day)
);
alter table bitelens_private.meal_estimate_allowances enable row level security;
revoke all on table bitelens_private.meal_estimate_allowances from public, anon, authenticated, service_role;

create function bitelens_private.reserve_meal_estimate(
    p_user_id uuid, p_daily_limit integer, p_photo_expires_at timestamptz, p_now timestamptz
)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
    reservation_time timestamptz;
    reservation_day date;
begin
    if p_user_id is null or p_daily_limit is null or p_daily_limit < 1 then
        raise exception 'Invalid Meal Estimate allowance reservation' using errcode = '22023';
    end if;

    -- Serialize admission for this account with competing reservations and revocation.
    perform 1 from bitelens_private.approved_accounts where user_id = p_user_id for no key update;
    if not found then
        return pg_catalog.jsonb_build_object('error', 'approval_required');
    end if;

    reservation_time := coalesce(p_now, pg_catalog.clock_timestamp());
    if p_photo_expires_at <= reservation_time then
        return pg_catalog.jsonb_build_object('error', 'photo_expired');
    end if;
    reservation_day := (reservation_time at time zone 'UTC')::date;

    insert into bitelens_private.meal_estimate_allowances as allowance (user_id, utc_day, attempts)
    values (p_user_id, reservation_day, 1)
    on conflict (user_id, utc_day) do update set attempts = allowance.attempts + 1
    where allowance.attempts < p_daily_limit;
    if found then
        return pg_catalog.jsonb_build_object('reserved', true);
    end if;

    return pg_catalog.jsonb_build_object(
        'error', 'allowance_exhausted',
        'reset_at', pg_catalog.to_char((reservation_day + 1)::timestamp, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    );
end;
$$;
revoke all on function bitelens_private.reserve_meal_estimate(uuid, integer, timestamptz, timestamptz)
    from public, anon, authenticated;
grant usage on schema bitelens_private to service_role;
grant execute on function bitelens_private.reserve_meal_estimate(uuid, integer, timestamptz, timestamptz)
    to service_role;

create function public.bitelens_reserve_meal_estimate(
    p_user_id uuid, p_daily_limit integer, p_photo_expires_at timestamptz
)
returns jsonb
language sql security invoker
set search_path = ''
as $$
    select bitelens_private.reserve_meal_estimate(p_user_id, p_daily_limit, p_photo_expires_at, null);
$$;
revoke all on function public.bitelens_reserve_meal_estimate(uuid, integer, timestamptz)
    from public, anon, authenticated;
grant execute on function public.bitelens_reserve_meal_estimate(uuid, integer, timestamptz) to service_role;

commit;
