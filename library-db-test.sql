begin;
-- All fixtures and test writes are rolled back, including temporary auth users.
insert into auth.users(id,email) values('11111111-1111-4111-8111-111111111111','qa-one@example.invalid'),('22222222-2222-4222-8222-222222222222','qa-two@example.invalid');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}',true);
select public.bookit_write('profile','{"nickname":"QA1","contact":"qa-one@example.invalid","method":"이메일"}');
select public.bookit_write('book','{"id":"qa-library-own","title":"QA OWN","genre":"소설","condition":"좋음","method":"이메일","contact":"qa-one@example.invalid"}');
select set_config('request.jwt.claims','{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}',true);
select public.bookit_write('profile','{"nickname":"QA2","contact":"qa-two@example.invalid","method":"이메일"}');
select public.bookit_write('book','{"id":"qa-library-other","title":"QA OTHER","genre":"소설","condition":"좋음","method":"이메일","contact":"qa-two@example.invalid"}');
select public.bookit_write('book','{"id":"qa-library-archived","title":"QA ARCHIVED","genre":"소설","condition":"좋음","method":"이메일","contact":"qa-two@example.invalid"}');
select public.bookit_write('archive','{"id":"qa-library-archived"}');
select set_config('request.jwt.claims','{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}',true);
do $$ begin
 begin insert into public.bookit_favorites(user_id,book_id) values(auth.uid(),'qa-library-own');raise exception 'SELF FAVORITE ALLOWED';exception when insufficient_privilege then null;end;
 begin insert into public.bookit_favorites(user_id,book_id) values(auth.uid(),'qa-library-archived');raise exception 'ARCHIVED FAVORITE ALLOWED';exception when insufficient_privilege then null;end;
end $$;
insert into public.bookit_favorites(user_id,book_id) values(auth.uid(),'qa-library-other');
insert into public.bookit_favorites(user_id,book_id) values(auth.uid(),'qa-library-other') on conflict(user_id,book_id) do nothing;
do $$ begin if (select count(*) from public.bookit_favorites where book_id='qa-library-other')<>1 then raise exception 'DUPLICATE OR MISSING FAVORITE';end if;end $$;
select set_config('request.jwt.claims','{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}',true);
do $$ declare changed integer;begin
 if exists(select 1 from public.bookit_favorites where book_id='qa-library-other') then raise exception 'OTHER USER READ ALLOWED';end if;
 delete from public.bookit_favorites where book_id='qa-library-other';get diagnostics changed=row_count;if changed<>0 then raise exception 'OTHER USER DELETE ALLOWED';end if;
 begin insert into public.bookit_favorites(user_id,book_id) values('11111111-1111-4111-8111-111111111111','qa-library-own');raise exception 'SPOOFED OWNER ALLOWED';exception when insufficient_privilege then null;end;
end $$;
select set_config('request.jwt.claims','{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}',true);
delete from public.bookit_favorites where book_id='qa-library-other';
do $$ begin if exists(select 1 from public.bookit_favorites where book_id='qa-library-other') then raise exception 'OWNER DELETE FAILED';end if;end $$;
reset role;
do $$ begin
 if has_table_privilege('anon','public.bookit_favorites','SELECT') or has_table_privilege('anon','public.bookit_favorites','INSERT') or has_table_privilege('anon','public.bookit_favorites','DELETE') then raise exception 'ANONYMOUS PRIVILEGES FOUND';end if;
 if not (select relrowsecurity from pg_class where oid='public.bookit_favorites'::regclass) then raise exception 'RLS DISABLED';end if;
end $$;
rollback;
select 'PASS: owner-only favorites, spoofing/self/archive rejection, duplicate prevention, anonymous denial; all fixtures rolled back' as result;
