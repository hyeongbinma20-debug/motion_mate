begin;
-- Additive only: no existing books, profiles, contacts or exchanges are changed.
create table if not exists public.bookit_favorites (
  user_id uuid not null references auth.users(id) on delete cascade,
  book_id text not null references public.bookit_books(id) on delete cascade,
  created bigint not null default ((extract(epoch from clock_timestamp())*1000)::bigint),
  primary key (user_id,book_id)
);
comment on table public.bookit_favorites is 'Private saved books; owner-only access. Recent viewing history stays on the device.';
create index if not exists bookit_favorites_created on public.bookit_favorites(user_id,created desc);
alter table public.bookit_favorites enable row level security;
revoke all on public.bookit_favorites from public,anon,authenticated;
grant select,insert,delete on public.bookit_favorites to authenticated;
drop policy if exists favorites_read on public.bookit_favorites;
create policy favorites_read on public.bookit_favorites for select to authenticated using(user_id=(select auth.uid()));
drop policy if exists favorites_add on public.bookit_favorites;
create policy favorites_add on public.bookit_favorites for insert to authenticated with check(
  user_id=(select auth.uid()) and exists(select 1 from public.bookit_books b where b.id=book_id and b.owner<>(select auth.uid()) and b.status='available')
);
drop policy if exists favorites_remove on public.bookit_favorites;
create policy favorites_remove on public.bookit_favorites for delete to authenticated using(user_id=(select auth.uid()));
commit;
