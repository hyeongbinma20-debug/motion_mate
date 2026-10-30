begin;
insert into auth.users(id,email) values('11111111-1111-4111-8111-111111111111','qa-one@example.invalid'),('22222222-2222-4222-8222-222222222222','qa-two@example.invalid');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}',true);
select public.bookit_write('profile','{"nickname":"QA1","contact":"qa-one@example.invalid","method":"이메일"}');
select public.bookit_write_book('{"id":"qa-ai-own","title":"QA OWN","genre":"소설","condition":"좋음","contact":"qa-one@example.invalid","method":"이메일","metadata":{"isbn":"9780140328721","pageCount":200,"region":"서울 마포구","moods":["따뜻한"],"tradeMethods":["직거래"],"wantedGenres":["소설"]}}');
select set_config('request.jwt.claims','{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}',true);
select public.bookit_write('profile','{"nickname":"QA2","contact":"qa-two@example.invalid","method":"이메일"}');
select public.bookit_write_book('{"id":"qa-ai-match","title":"QA MATCH","genre":"소설","condition":"좋음","contact":"qa-two@example.invalid","method":"이메일","metadata":{"isbn":"9780140328721","publisher":"조회 출판사","category":"Fiction","pageCount":240,"region":"서울 마포구","moods":["따뜻한"],"tradeMethods":["직거래"],"wantedGenres":["소설"]}}');
select public.bookit_write('book','{"id":"qa-ai-unknown","title":"QA UNKNOWN","genre":"소설","condition":"좋음","contact":"qa-two@example.invalid","method":"이메일"}');
select public.bookit_write_book('{"id":"qa-ai-closed","title":"QA CLOSED","genre":"소설","condition":"좋음","contact":"qa-two@example.invalid","method":"이메일","metadata":{"pageCount":200,"region":"서울 마포구"}}');
select public.bookit_write('archive','{"id":"qa-ai-closed"}');
-- Legacy writes retain optional metadata instead of clearing it.
select public.bookit_write('book','{"id":"qa-ai-match","title":"QA MATCH","author":"수정 저자","genre":"소설","condition":"좋음","contact":"qa-two@example.invalid","method":"이메일"}');
do $$ begin
 if (select page_count from public.bookit_book_info where book_id='qa-ai-match')<>240 then raise exception 'LEGACY UPDATE LOST METADATA';end if;
 begin perform public.bookit_write_book('{"id":"qa-ai-match","title":"SHOULD NOT SAVE","genre":"소설","condition":"좋음","contact":"qa-two@example.invalid","method":"이메일","metadata":{"pageCount":0}}');raise exception 'INVALID PAGES SAVED';exception when check_violation then null;end;
 if (select doc->>'title' from public.bookit_books where id='qa-ai-match')<>'QA MATCH' then raise exception 'ATOMIC SAVE FAILED';end if;
 begin perform public.bookit_write_book('{"id":"qa-ai-bad-isbn","title":"BAD ISBN","genre":"소설","condition":"좋음","contact":"qa-two@example.invalid","method":"이메일","metadata":{"isbn":"9780140328722"}}');raise exception 'INVALID ISBN SAVED';exception when others then if SQLERRM='INVALID ISBN SAVED' then raise;end if;end;
 if exists(select 1 from public.bookit_books where id='qa-ai-bad-isbn') then raise exception 'PARTIAL BOOK SAVE';end if;
end $$;
select set_config('request.jwt.claims','{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}',true);
do $$ declare candidates jsonb;begin
 candidates:=public.bookit_ai_candidates('{"genres":["소설"],"moods":["따뜻한"],"pages":{"min":null,"max":300},"region":"마포","methods":["직거래"],"offerGenres":["소설"]}','{}',24);
 if jsonb_array_length(candidates)<>1 or candidates->0->>'id'<>'qa-ai-match' then raise exception 'HARD FILTERS / OWNER / AVAILABILITY FAILED: %',candidates;end if;
 if candidates::text like '%qa-two@example.invalid%' or candidates::text like '%"cover"%' or candidates::text like '%"contact"%' then raise exception 'PRIVATE FIELDS IN CANDIDATES';end if;
 candidates:=public.bookit_ai_candidates('{"region":"검증용으로존재하지않는지역"}','{}',24);
 if jsonb_array_length(candidates)<>0 then raise exception 'NO RESULTS INVENTED';end if;
 candidates:=public.bookit_ai_candidates('{"keywords":"''; DROP TABLE anything; --"}','{}',24);
 if jsonb_array_length(candidates)<>0 then raise exception 'KEYWORD WAS NOT LITERAL';end if;
 begin perform public.bookit_write_book('{"id":"qa-ai-match","title":"SPOOF","genre":"소설","condition":"좋음","contact":"qa-one@example.invalid","method":"이메일","metadata":{"pageCount":10}}');raise exception 'OTHER USER UPDATE';exception when others then if SQLERRM='OTHER USER UPDATE' then raise;end if;end;
 if (select page_count from public.bookit_book_info where book_id='qa-ai-match')<>240 then raise exception 'OWNERSHIP FAILED';end if;
end $$;
reset role;
do $$ begin
 if has_function_privilege('authenticated','public.bookit_ai_consume(uuid,text)','EXECUTE') or has_function_privilege('anon','public.bookit_ai_consume(uuid,text)','EXECUTE') then raise exception 'PUBLIC QUOTA ADMIN ACCESS';end if;
 if has_table_privilege('authenticated','public.bookit_book_info','INSERT') or has_table_privilege('authenticated','public.bookit_book_info','UPDATE') then raise exception 'DIRECT METADATA WRITE';end if;
 if has_function_privilege('anon','public.bookit_ai_candidates(jsonb,jsonb,integer)','EXECUTE') then raise exception 'ANONYMOUS AI ACCESS';end if;
end $$;
set local role service_role;
do $$ declare result jsonb;begin
 result:=public.bookit_ai_consume('11111111-1111-4111-8111-111111111111','photo');if not (result->>'allowed')::boolean then raise exception 'FIRST QUOTA USE FAILED';end if;
 result:=public.bookit_ai_consume('11111111-1111-4111-8111-111111111111','photo');if (result->>'allowed')::boolean or (result->>'retryAfter')::int<1 then raise exception 'MINUTE RATE LIMIT FAILED';end if;
end $$;
reset role;
rollback;
select 'PASS: atomic metadata and legacy compatibility; real available candidates only; strict missing-data filters; privacy/ownership; literal input; server-only atomic quotas; all fixtures rolled back' as result;
