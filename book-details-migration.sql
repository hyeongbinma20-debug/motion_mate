-- Add optional book detail fields without rewriting existing records or changing access policies.
begin;
create or replace function bookit_private.write(action text, payload jsonb) returns void language plpgsql security definer set search_path='' as $$
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
  if bid is null or length(bid)>100 or length(trim(coalesce(payload->>'title',''))) not between 1 and 120 or length(coalesce(payload->>'author',''))>80 or length(coalesce(payload->>'description',''))>1500 or length(coalesce(payload->>'terms',''))>300 or coalesce(payload->>'genre','') not in ('소설','에세이','인문','자기계발','예술','과학') or coalesce(payload->>'condition','') not in ('새 책','좋음','사용감 있음') then raise exception '책 제목과 입력 내용을 확인해주세요.'; end if;
  if (payload ? 'genreDetail' and jsonb_typeof(payload->'genreDetail')<>'string') or (payload ? 'conditionDetail' and jsonb_typeof(payload->'conditionDetail')<>'string') or length(coalesce(payload->>'genreDetail',''))>40 or length(coalesce(payload->>'conditionDetail',''))>300 then raise exception '세부 장르는 40자, 상세 상태는 300자 이내의 글자로 입력해주세요.'; end if;
  select * into b from public.bookit_books where id=bid;
  if found and (b.owner<>me or b.status<>'available') then raise exception '수정할 수 없는 책입니다.'; end if;
  p:=jsonb_build_object('title',trim(payload->>'title'),'author',coalesce(payload->>'author',''),'description',coalesce(payload->>'description',''),'terms',coalesce(payload->>'terms',''),'genre',payload->>'genre','genreDetail',trim(coalesce(payload->>'genreDetail',b.doc->>'genreDetail','')),'condition',payload->>'condition','conditionDetail',trim(coalesce(payload->>'conditionDetail',b.doc->>'conditionDetail','')),'cover',coalesce(payload->>'cover','light'));
  if length(p->>'cover')>2900000 or ((p->>'cover') not in ('light','essay','store','fish','sapiens','winter','sea','art') and (p->>'cover')!~'^data:image/(png|jpeg|webp);base64,') then raise exception '책 표지 형식이나 크기를 확인해주세요.'; end if;
  insert into public.bookit_books(id,owner,doc,created) values(bid,me,p,now_ms) on conflict(id) do update set doc=excluded.doc;
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
commit;
