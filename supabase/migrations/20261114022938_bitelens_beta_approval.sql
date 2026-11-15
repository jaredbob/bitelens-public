begin;

-- Managed by the BiteLens Beta administrator. Auth accounts and their data
-- survive removing an approval.
create table bitelens_private.approved_accounts (
    user_id uuid primary key references auth.users(id) on delete cascade
);
alter table bitelens_private.approved_accounts enable row level security;
revoke all on table bitelens_private.approved_accounts from public, anon, authenticated;

create function bitelens_private.is_approved_account()
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select exists (
        select 1 from bitelens_private.approved_accounts
        where user_id = (select auth.uid())
    );
$$;
revoke all on function bitelens_private.is_approved_account() from public, anon, authenticated;
grant execute on function bitelens_private.is_approved_account() to authenticated;

create function public.bitelens_is_approved()
returns boolean
language sql stable security invoker
set search_path = ''
as $$
    select bitelens_private.is_approved_account();
$$;
revoke all on function public.bitelens_is_approved() from public, anon, authenticated;
grant execute on function public.bitelens_is_approved() to authenticated;

commit;
