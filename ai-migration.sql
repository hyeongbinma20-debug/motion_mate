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
