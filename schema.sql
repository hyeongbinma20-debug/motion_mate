begin;
create schema if not exists bookit_private;
revoke all on schema bookit_private from public;
create table public.bookit_profiles(id uuid primary key references auth.users(id), doc jsonb not null);
create table public.bookit_books(id text primary key, owner uuid not null references public.bookit_profiles(id), doc jsonb not null, status text not null default 'available' check(status in ('available','reserved','completed','archived')), created bigint not null);
create table public.bookit_requests(id text primary key, sender uuid not null references public.bookit_profiles(id), recipient uuid not null references public.bookit_profiles(id), target text not null references public.bookit_books(id), offered text not null references public.bookit_books(id), status text not null default '대기 중' check(status in ('대기 중','수락됨','거절됨','취소됨','교환 완료')), message text not null default '', notes jsonb not null default '{}', confirmations jsonb not null default '[]', cancellations jsonb not null default '[]' check(jsonb_typeof(cancellations)='array' and jsonb_array_length(cancellations)<=2), created bigint not null, closed_reason text, check(sender <> recipient), check(target <> offered));
create table public.bookit_contacts(id text primary key, owner uuid not null references public.bookit_profiles(id), method text not null, value text not null);
create index bookit_books_owner on public.bookit_books(owner);
create index bookit_books_created on public.bookit_books(created desc);
create index bookit_requests_sender on public.bookit_requests(sender,status);
create index bookit_requests_recipient on public.bookit_requests(recipient,status);
create index bookit_requests_target on public.bookit_requests(target);
create index bookit_requests_offered on public.bookit_requests(offered);
create index bookit_contacts_owner on public.bookit_contacts(owner);
alter table public.bookit_profiles enable row level security;
alter table public.bookit_books enable row level security;
alter table public.bookit_requests enable row level security;
alter table public.bookit_contacts enable row level security;
revoke all on public.bookit_profiles,public.bookit_books,public.bookit_requests,public.bookit_contacts from anon,authenticated;
grant select on public.bookit_profiles,public.bookit_books to anon,authenticated;
grant select on public.bookit_requests,public.bookit_contacts to authenticated;
create policy profiles_read on public.bookit_profiles for select to anon,authenticated using(true);
create policy books_read on public.bookit_books for select to anon,authenticated using(true);
create policy requests_participants on public.bookit_requests for select to authenticated using((select auth.uid()) in (sender,recipient));
create policy contacts_participants on public.bookit_contacts for select to authenticated using(owner=(select auth.uid()) or exists(select 1 from public.bookit_requests r where r.status in ('수락됨','교환 완료') and (select auth.uid()) in (r.sender,r.recipient) and bookit_contacts.id in (r.target,r.offered)));

-- Privileged write logic lives outside the exposed API schema. All authorization
-- uses the verified auth.uid(), never IDs supplied by the browser.
create function bookit_private.write(action text, payload jsonb) returns void language plpgsql security definer set search_path='' as $$
declare me uuid:=auth.uid(); bid text; b public.bookit_books; o public.bookit_books; r public.bookit_requests; p jsonb; contact text; method text; now_ms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
begin
 if me is null then raise exception '로그인이 필요합니다.'; end if;
 perform pg_advisory_xact_lock(182029,1);
 if octet_length(payload::text)>4500000 then raise exception '사진이나 입력 데이터가 너무 큽니다.'; end if;
 if action='profile' then
  if length(trim(coalesce(payload->>'nickname',''))) not between 1 and 20 or length(coalesce(payload->>'bio',''))>140 or length(coalesce(payload->>'keywords',''))>300 then raise exception '프로필 입력 길이를 확인해주세요.'; end if;
  if jsonb_typeof(coalesce(payload->'interests','[]'))<>'array' then raise exception '관심 장르가 잘못되었습니다.'; end if;
  p:=jsonb_build_object('nickname',trim(payload->>'nickname'),'bio',coalesce(payload->>'bio',''),'avatar',coalesce(payload->>'avatar',''),'interests',coalesce(payload->'interests','[]'),'keywords',coalesce(payload->>'keywords',''));
  if length(p->>'avatar')>2900000 or ((p->>'avatar')<>'' and (p->>'avatar')!~'^data:image/(png|jpeg|webp);base64,') then raise exception '프로필 사진 형식을 확인해주세요.'; end if;
  insert into public.bookit_profiles values(me,p) on conflict(id) do update set doc=excluded.doc;
  bid:='profile:'||me;
 elsif action='book' then
  if not exists(select 1 from public.bookit_profiles where id=me) then raise exception '프로필을 먼저 저장해주세요.'; end if;
  bid:=payload->>'id';
  if bid is null or length(bid)>100 or length(trim(coalesce(payload->>'title',''))) not between 1 and 120 or length(coalesce(payload->>'author',''))>80 or length(coalesce(payload->>'description',''))>1500 or length(coalesce(payload->>'terms',''))>300 or coalesce(payload->>'genre','') not in ('소설','에세이','인문','자기계발','예술','과학','기타') or coalesce(payload->>'condition','') not in ('새 책','좋음','사용감 있음','기타') then raise exception '책 제목과 입력 내용을 확인해주세요.'; end if;
  if (payload ? 'genreDetail' and jsonb_typeof(payload->'genreDetail')<>'string') or (payload ? 'conditionDetail' and jsonb_typeof(payload->'conditionDetail')<>'string') or length(coalesce(payload->>'genreDetail',''))>40 or length(coalesce(payload->>'conditionDetail',''))>300 then raise exception '세부 장르는 40자, 상세 상태는 300자 이내의 글자로 입력해주세요.'; end if;
  if (payload->>'genre'='기타' and length(trim(coalesce(payload->>'genreDetail','')))=0) or (payload->>'condition'='기타' and length(trim(coalesce(payload->>'conditionDetail','')))=0) then raise exception '기타 항목을 선택하면 세부 장르 또는 상세 상태를 입력해주세요.'; end if;
  select * into b from public.bookit_books where id=bid;
  if found and (b.owner<>me or b.status<>'available') then raise exception '수정할 수 없는 책입니다.'; end if;
  p:=jsonb_build_object('title',trim(payload->>'title'),'author',coalesce(payload->>'author',''),'description',coalesce(payload->>'description',''),'terms',coalesce(payload->>'terms',''),'genre',payload->>'genre','genreDetail',trim(coalesce(payload->>'genreDetail',b.doc->>'genreDetail','')),'condition',payload->>'condition','conditionDetail',trim(coalesce(payload->>'conditionDetail',b.doc->>'conditionDetail','')),'cover',coalesce(payload->>'cover','light'));
  if length(p->>'cover')>2900000 or ((p->>'cover') not in ('light','essay','store','fish','sapiens','winter','sea','art') and (p->>'cover')!~'^data:image/(png|jpeg|webp);base64,') then raise exception '책 표지 형식이나 크기를 확인해주세요.'; end if;
  insert into public.bookit_books(id,owner,doc,created) values(bid,me,p,now_ms) on conflict(id) do update set doc=excluded.doc;
 elsif action in ('archive','restore') then
  select * into b from public.bookit_books where id=payload->>'id';
  if not found or b.owner<>me or (action='archive' and b.status<>'available') or (action='restore' and b.status<>'archived') then raise exception '진행 중이거나 완료된 책의 등록 상태는 변경할 수 없어요.'; end if;
  update public.bookit_books set status=case when action='archive' then 'archived' else 'available' end where id=b.id;
  if action='archive' then update public.bookit_requests set status=case when sender=me then '취소됨' else '거절됨' end,closed_reason='책 등록이 종료되어 신청이 마감되었어요.' where status='대기 중' and b.id in (target,offered); end if;
  return;
 elsif action='delete' then
  select * into b from public.bookit_books where id=payload->>'id';
  if not found or b.owner<>me or b.status<>'available' then raise exception '삭제할 수 없는 책입니다.'; end if;
  if exists(select 1 from public.bookit_requests where target=b.id or offered=b.id) then raise exception '교환 기록에 연결된 책은 삭제할 수 없습니다.'; end if;
  delete from public.bookit_contacts where id=b.id;
  delete from public.bookit_books where id=b.id;
  return;
 elsif action='propose' then
  select * into b from public.bookit_books where id=payload->>'target';
  select * into o from public.bookit_books where id=payload->>'offered';
  if b.id is null or o.id is null or b.owner=me or o.owner<>me or b.status<>'available' or o.status<>'available' then raise exception '교환 가능한 책을 선택해주세요.'; end if;
  if exists(select 1 from public.bookit_requests where sender=me and recipient=b.owner and status in ('대기 중','수락됨')) then raise exception '이 사용자에게 진행 중인 신청이 있습니다.'; end if;
  if length(coalesce(payload->>'message',''))>1000 then raise exception '메시지는 1000자 이내로 입력해주세요.'; end if;
  insert into public.bookit_requests(id,sender,recipient,target,offered,message,created) values(gen_random_uuid()::text,me,b.owner,b.id,o.id,coalesce(payload->>'message',''),now_ms);
  return;
 elsif action='transition' then
  select * into r from public.bookit_requests where id=payload->>'id';
  if not found or me not in (r.sender,r.recipient) then raise exception '접근할 수 없는 신청입니다.'; end if;
  if payload->>'action' in ('합의 취소','취소 철회','취소 거절') then
   if r.status<>'수락됨' then raise exception '수락된 교환만 합의 취소할 수 있어요.'; end if;
   if payload->>'action'='합의 취소' then
    if r.cancellations @> jsonb_build_array(me::text) then raise exception '상대방의 취소 동의를 기다리고 있어요.'; end if;
    r.cancellations:=r.cancellations||jsonb_build_array(me::text);
    if jsonb_array_length(r.cancellations)=2 then
     update public.bookit_requests set status='취소됨',closed_reason='양쪽 사용자가 동의하여 교환을 취소했어요.',cancellations=r.cancellations,confirmations='[]'::jsonb where id=r.id;
     update public.bookit_books set status='available' where id in (r.target,r.offered) and status='reserved';
    else update public.bookit_requests set cancellations=r.cancellations where id=r.id; end if;
   else
    if jsonb_array_length(r.cancellations)=0 or (payload->>'action'='취소 철회' and not r.cancellations @> jsonb_build_array(me::text)) or (payload->>'action'='취소 거절' and r.cancellations @> jsonb_build_array(me::text)) then raise exception '이 취소 요청을 변경할 수 없어요.'; end if;
    update public.bookit_requests set cancellations='[]'::jsonb where id=r.id;
   end if;
   return;
  end if;
  if payload->>'action'='수락됨' then
   if me<>r.recipient or r.status<>'대기 중' then raise exception '수락할 수 없는 신청입니다.'; end if;
   if exists(select 1 from public.bookit_books where id in (r.target,r.offered) and status<>'available') then raise exception '이미 예약되거나 완료된 책입니다.'; end if;
   update public.bookit_books set status='reserved' where id in (r.target,r.offered);
   update public.bookit_requests set status='수락됨' where id=r.id;
   update public.bookit_requests set status='거절됨',closed_reason='다른 교환이 수락되어 마감되었어요.' where id<>r.id and status='대기 중' and (target in (r.target,r.offered) or offered in (r.target,r.offered));
  elsif payload->>'action' in ('거절됨','취소됨') then
   if r.status<>'대기 중' or (payload->>'action'='거절됨' and me<>r.recipient) or (payload->>'action'='취소됨' and me<>r.sender) then raise exception '변경할 수 없는 신청입니다.'; end if;
   update public.bookit_requests set status=payload->>'action' where id=r.id;
  elsif payload->>'action'='완료' then
   if r.status<>'수락됨' then raise exception '수락된 신청만 완료할 수 있어요.'; end if;
   if jsonb_array_length(r.cancellations)>0 then raise exception '취소 요청을 먼저 처리한 뒤 완료할 수 있어요.'; end if;
   if not r.confirmations @> jsonb_build_array(me::text) then r.confirmations:=r.confirmations||jsonb_build_array(me::text); end if;
   update public.bookit_requests set confirmations=r.confirmations,status=case when jsonb_array_length(r.confirmations)=2 then '교환 완료' else '수락됨' end where id=r.id;
   if jsonb_array_length(r.confirmations)=2 then update public.bookit_books set status='completed' where id in (r.target,r.offered); end if;
  else raise exception '잘못된 작업입니다.';
  end if;
  return;
 elsif action='notes' then
  if length(coalesce(payload->>'note',''))>1000 then raise exception '메모는 1000자 이내로 입력해주세요.'; end if;
  update public.bookit_requests set notes=jsonb_set(notes,array[me::text],to_jsonb(coalesce(payload->>'note',''))) where id=payload->>'id' and me in (sender,recipient) and status='수락됨';
  if not found then raise exception '메모를 수정할 수 없습니다.'; end if;
  return;
 else raise exception '잘못된 작업입니다.';
 end if;
 contact:=trim(coalesce(payload->>'contact','')); method:=payload->>'method';
 if length(contact) not between 1 and 100 or coalesce(method,'') not in ('이메일','전화번호','기타') then raise exception '연락처를 확인해주세요.'; end if;
 if method='이메일' and contact!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception '이메일 형식을 확인해주세요.'; end if;
 if method='전화번호' and contact!~'^[+0-9 ()-]{8,24}$' then raise exception '전화번호 형식을 확인해주세요.'; end if;
 insert into public.bookit_contacts values(bid,me,method,contact) on conflict(id) do update set method=excluded.method,value=excluded.value;
end $$;
revoke all on function bookit_private.write(text,jsonb) from public;
grant usage on schema bookit_private to authenticated;
grant execute on function bookit_private.write(text,jsonb) to authenticated;
create function public.bookit_write(action text,payload jsonb) returns void language sql security invoker set search_path='' as $$ select bookit_private.write(action,payload); $$;
revoke all on function public.bookit_write(text,jsonb) from public,anon;
grant execute on function public.bookit_write(text,jsonb) to authenticated;
commit;

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

begin;
-- Existing book/profile/exchange/contact rows are retained unchanged.
create table if not exists public.bookit_book_info(
  book_id text primary key references public.bookit_books(id) on delete cascade,
  isbn text not null default '' check(isbn='' or isbn ~ '^(\d{13}|\d{9}[\dX])$'),
  publisher text not null default '' check(length(publisher)<=120),
  category text not null default '' check(length(category)<=200),
  page_count integer check(page_count between 1 and 20000),
  region text not null default '' check(length(region)<=60),
  moods text[] not null default '{}' check(moods <@ array['따뜻한','잔잔한','유쾌한','긴장감 있는','생각할 거리','슬픈']::text[] and cardinality(moods)<=6),
  trade_methods text[] not null default '{}' check(trade_methods <@ array['직거래','택배']::text[] and cardinality(trade_methods)<=2),
  wanted_genres text[] not null default '{}' check(wanted_genres <@ array['소설','에세이','인문','자기계발','예술','과학','기타']::text[] and cardinality(wanted_genres)<=7),
  source text not null default 'manual' check(source in ('manual','google-books')),
  source_id text not null default '' check(source_id='' or source_id ~ '^[a-zA-Z0-9_-]{1,80}$')
);
comment on table public.bookit_book_info is 'Public bibliographic and optional coarse exchange information. Unknown values remain empty; never store contacts or exact addresses here.';
alter table public.bookit_book_info enable row level security;
revoke all on public.bookit_book_info from public,anon,authenticated;
grant select on public.bookit_book_info to anon,authenticated;
drop policy if exists book_info_read on public.bookit_book_info;
create policy book_info_read on public.bookit_book_info for select to anon,authenticated using(true);
create index if not exists bookit_available_created on public.bookit_books(created desc) where status='available';
create index if not exists bookit_info_pages on public.bookit_book_info(page_count);

create or replace function bookit_private.valid_isbn(value text) returns boolean language sql immutable set search_path='' as $$
 select case when value='' then true
 when value ~ '^\d{13}$' then (select sum(substr(value,i,1)::int * case when i%2=0 then 3 else 1 end)%10=0 from generate_series(1,13) i)
 when value ~ '^\d{9}[\dX]$' then (select sum((case when substr(value,i,1)='X' then 10 else substr(value,i,1)::int end)*(11-i))%11=0 from generate_series(1,10) i)
 else false end;
$$;
revoke all on function bookit_private.valid_isbn(text) from public,anon,authenticated;

-- Atomic wrapper: a metadata failure also rolls back the original book save.
-- Older clients keep using bookit_write, which leaves this optional table intact.
create or replace function public.bookit_write_book(payload jsonb) returns void language plpgsql security definer set search_path='' as $$
declare info jsonb:=payload->'metadata';
begin
 if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
 perform bookit_private.write('book',payload);
 if not (payload ? 'metadata') then return; end if;
 if jsonb_typeof(info)<>'object' or octet_length(info::text)>6000 then raise exception '도서 부가정보를 확인해주세요.'; end if;
 if not bookit_private.valid_isbn(coalesce(info->>'isbn','')) then raise exception 'ISBN 번호를 확인해주세요.'; end if;
 if length(coalesce(info->>'publisher',''))>120 or length(coalesce(info->>'category',''))>200 or length(coalesce(info->>'region',''))>60 then raise exception '출판사·분류·지역의 입력 길이를 확인해주세요.'; end if;
 if jsonb_typeof(coalesce(info->'moods','[]'))<>'array' or jsonb_typeof(coalesce(info->'tradeMethods','[]'))<>'array' or jsonb_typeof(coalesce(info->'wantedGenres','[]'))<>'array' then raise exception '분위기와 교환 방식을 다시 선택해주세요.'; end if;
 insert into public.bookit_book_info(book_id,isbn,publisher,category,page_count,region,moods,trade_methods,wanted_genres,source,source_id)
 values(payload->>'id',coalesce(info->>'isbn',''),coalesce(info->>'publisher',''),coalesce(info->>'category',''),nullif(info->>'pageCount','')::int,coalesce(info->>'region',''),array(select jsonb_array_elements_text(info->'moods')),array(select jsonb_array_elements_text(info->'tradeMethods')),array(select jsonb_array_elements_text(info->'wantedGenres')),coalesce(info->>'source','manual'),coalesce(info->>'sourceId',''))
 on conflict(book_id) do update set isbn=excluded.isbn,publisher=excluded.publisher,category=excluded.category,page_count=excluded.page_count,region=excluded.region,moods=excluded.moods,trade_methods=excluded.trade_methods,wanted_genres=excluded.wanted_genres,source=excluded.source,source_id=excluded.source_id;
end $$;
revoke all on function public.bookit_write_book(jsonb) from public,anon,authenticated;
grant execute on function public.bookit_write_book(jsonb) to authenticated;

create or replace function bookit_private.ai_matches(b jsonb,m jsonb,f jsonb) returns boolean language sql immutable set search_path='' as $$
 select
 (coalesce(jsonb_array_length(f->'genres'),0)=0 or (f->'genres') ? (b->>'genre')) and
 (coalesce(jsonb_array_length(f->'moods'),0)=0 or coalesce(m->'moods','[]') @> (f->'moods')) and
 ((f->'pages') is null or f->'pages'='null'::jsonb or ((m->>'page_count')::int>0 and ((f->'pages'->>'min') is null or (m->>'page_count')::int>=(f->'pages'->>'min')::int) and ((f->'pages'->>'max') is null or (m->>'page_count')::int<=(f->'pages'->>'max')::int))) and
 (coalesce(f->>'region','')='' or strpos(lower(coalesce(m->>'region','')),lower(f->>'region'))>0) and
 (coalesce(jsonb_array_length(f->'methods'),0)=0 or exists(select 1 from jsonb_array_elements_text(f->'methods') as x(value) where coalesce(m->'trade_methods','[]') ? x.value)) and
 (coalesce(jsonb_array_length(f->'offerGenres'),0)=0 or exists(select 1 from jsonb_array_elements_text(f->'offerGenres') as x(value) where coalesce(m->'wanted_genres','[]') ? x.value)) and
 (coalesce(f->>'keywords','')='' or strpos(lower(coalesce(b->>'title','')||' '||coalesce(b->>'author','')||' '||coalesce(b->>'description','')||' '||coalesce(m->>'category','')),lower(f->>'keywords'))>0);
$$;
revoke all on function bookit_private.ai_matches(jsonb,jsonb,jsonb) from public,anon,authenticated;
create or replace function bookit_private.ai_score(b jsonb,m jsonb,f jsonb) returns integer language sql immutable set search_path='' as $$
 select count(*)::int from jsonb_each(f) x where x.value not in ('[]'::jsonb,'null'::jsonb,'""'::jsonb) and bookit_private.ai_matches(b,m,jsonb_build_object(x.key,x.value));
$$;
revoke all on function bookit_private.ai_score(jsonb,jsonb,jsonb) from public,anon,authenticated;

-- Only public projections are returned; photos and contact data are never candidates.
create or replace function public.bookit_ai_candidates(p_required jsonb,p_preferred jsonb,p_limit integer default 24) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
 if jsonb_typeof(p_required)<>'object' or jsonb_typeof(p_preferred)<>'object' or octet_length(p_required::text||p_preferred::text)>8000 then raise exception '추천 조건을 확인해주세요.'; end if;
 select coalesce(jsonb_agg(x.item order by x.score desc,x.created desc,x.id),'[]') into result from (
   select b.id,b.created,bookit_private.ai_score(b.doc,coalesce(to_jsonb(i),'{}'),p_preferred) score,
     jsonb_build_object('id',b.id,'owner',b.owner,'ownerNickname',p.doc->>'nickname','status',b.status,'created',b.created,'title',b.doc->>'title','author',b.doc->>'author','description',b.doc->>'description','genre',b.doc->>'genre','genreDetail',b.doc->>'genreDetail','condition',b.doc->>'condition','conditionDetail',b.doc->>'conditionDetail','terms',b.doc->>'terms','info',to_jsonb(i)) item
   from public.bookit_books b left join public.bookit_book_info i on i.book_id=b.id join public.bookit_profiles p on p.id=b.owner
   where b.status='available' and b.owner<>auth.uid() and bookit_private.ai_matches(b.doc,coalesce(to_jsonb(i),'{}'),p_required)
   order by score desc,b.created desc,b.id limit least(greatest(p_limit,1),24)
 ) x;
 return result;
end $$;
revoke all on function public.bookit_ai_candidates(jsonb,jsonb,integer) from public,anon,authenticated;
grant execute on function public.bookit_ai_candidates(jsonb,jsonb,integer) to authenticated;

create table if not exists bookit_private.ai_usage(scope text not null,operation text not null,window_seconds integer not null,bucket bigint not null,used integer not null default 0,primary key(scope,operation,window_seconds,bucket));
alter table bookit_private.ai_usage enable row level security;
revoke all on bookit_private.ai_usage from public,anon,authenticated;
comment on table bookit_private.ai_usage is 'Atomic per-account and global API counters; no images, messages or book descriptions are stored.';
create or replace function public.bookit_ai_consume(p_user uuid,p_operation text) returns jsonb language plpgsql security definer set search_path='' as $$
declare seconds bigint:=floor(extract(epoch from clock_timestamp())); scope_key text; win integer; bucket_key bigint; cap integer; value integer; retry integer:=0;
begin
 if p_operation not in ('photo','lookup','chat') or not exists(select 1 from auth.users where id=p_user) then raise exception '잘못된 호출입니다.'; end if;
 perform pg_advisory_xact_lock(hashtextextended('bookit-ai:'||p_operation,0));
 foreach scope_key in array array[p_user::text,'global'] loop
  foreach win in array array[60,3600,86400] loop
   cap:=case when scope_key='global' then case win when 60 then 12 when 3600 then 80 else 200 end
    when p_operation='photo' then case win when 60 then 1 when 3600 then 5 else 20 end
    when p_operation='lookup' then case win when 60 then 3 when 3600 then 20 else 50 end
    else case win when 60 then 3 when 3600 then 12 else 40 end end;
   bucket_key:=seconds/win;
   select used into value from bookit_private.ai_usage u where u.scope=scope_key and u.operation=p_operation and u.window_seconds=win and u.bucket=bucket_key;
   if coalesce(value,0)>=cap then retry:=greatest(retry,((bucket_key+1)*win-seconds)::int);end if;
  end loop;
 end loop;
 if retry>0 then return jsonb_build_object('allowed',false,'retryAfter',retry);end if;
 foreach scope_key in array array[p_user::text,'global'] loop
  foreach win in array array[60,3600,86400] loop
   insert into bookit_private.ai_usage(scope,operation,window_seconds,bucket,used) values(scope_key,p_operation,win,seconds/win,1)
   on conflict(scope,operation,window_seconds,bucket) do update set used=bookit_private.ai_usage.used+1;
  end loop;
 end loop;
 delete from bookit_private.ai_usage where bucket*window_seconds<seconds-259200;
 return jsonb_build_object('allowed',true,'retryAfter',0);
end $$;
revoke all on function public.bookit_ai_consume(uuid,text) from public,anon,authenticated;
grant execute on function public.bookit_ai_consume(uuid,text) to service_role;
commit;
