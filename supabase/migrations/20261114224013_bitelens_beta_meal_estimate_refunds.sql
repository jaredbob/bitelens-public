begin;

alter table bitelens_private.meal_estimate_allowances
    drop constraint meal_estimate_allowances_attempts_check,
    add constraint meal_estimate_allowances_attempts_check check (attempts >= 0);

create table bitelens_private.meal_estimate_photo_reservations (
    id uuid primary key default pg_catalog.gen_random_uuid(),
    user_id uuid not null,
    utc_day date not null,
    foreign key (user_id, utc_day)
        references bitelens_private.meal_estimate_allowances(user_id, utc_day) on delete cascade
);
create index meal_estimate_photo_reservations_account_day_idx
    on bitelens_private.meal_estimate_photo_reservations (user_id, utc_day);
alter table bitelens_private.meal_estimate_photo_reservations enable row level security;
revoke all on table bitelens_private.meal_estimate_photo_reservations from public, anon, authenticated, service_role;

create or replace function bitelens_private.reserve_meal_estimate(
    p_user_id uuid, p_daily_limit integer, p_photo_expires_at timestamptz, p_now timestamptz
)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
    reservation_time timestamptz;
    reservation_day date;
    reservation_id uuid;
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
        if p_photo_expires_at is not null then
            -- Keep the previous UTC day available for refunds that cross midnight.
            delete from bitelens_private.meal_estimate_photo_reservations
            where user_id = p_user_id and utc_day < reservation_day - 1;

            insert into bitelens_private.meal_estimate_photo_reservations (user_id, utc_day)
            values (p_user_id, reservation_day)
            returning id into reservation_id;
            return pg_catalog.jsonb_build_object('reserved', true, 'reservation_id', reservation_id);
        end if;
        return pg_catalog.jsonb_build_object('reserved', true);
    end if;

    return pg_catalog.jsonb_build_object(
        'error', 'allowance_exhausted',
        'reset_at', pg_catalog.to_char((reservation_day + 1)::timestamp, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    );
end;
$$;
create function bitelens_private.refund_meal_estimate(p_reservation_id uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    reservation_user_id uuid;
    reservation_day date;
begin
    select user_id, utc_day into reservation_user_id, reservation_day
    from bitelens_private.meal_estimate_photo_reservations where id = p_reservation_id;
    if not found then
        return;
    end if;

    -- Lock the counter before removing its reservation, as in the reserve operation.
    perform 1 from bitelens_private.meal_estimate_allowances
    where user_id = reservation_user_id and utc_day = reservation_day for update;
    if not found then
        return;
    end if;

    delete from bitelens_private.meal_estimate_photo_reservations where id = p_reservation_id;
    if found then
        update bitelens_private.meal_estimate_allowances set attempts = attempts - 1
        where user_id = reservation_user_id and utc_day = reservation_day;
    end if;
end;
$$;
revoke all on function bitelens_private.refund_meal_estimate(uuid) from public, anon, authenticated;
grant execute on function bitelens_private.refund_meal_estimate(uuid) to service_role;

create function public.bitelens_refund_meal_estimate(p_reservation_id uuid)
returns void
language sql security invoker
set search_path = ''
as $$
    select bitelens_private.refund_meal_estimate(p_reservation_id);
$$;
revoke all on function public.bitelens_refund_meal_estimate(uuid) from public, anon, authenticated;
grant execute on function public.bitelens_refund_meal_estimate(uuid) to service_role;

commit;
