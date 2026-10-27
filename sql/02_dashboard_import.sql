-- 2차: 지점 표기 정리, 전광판 항목 컬럼 추가, 2026 전광판 일회성 이관 함수
alter table public.daily_close add column if not exists pt jsonb not null default '{}'::jsonb;     -- 물리치료 비급여 건수 {"도수A":0,...,"도수상담":0}
alter table public.daily_close add column if not exists extra jsonb not null default '{}'::jsonb;  -- 전광판 부가 항목 {"cash","free","cash_real","pay_real","cash_diff","block","emg","visits","source"}

update public.branches set name = '골든타임365정형외과(운정점)', active = true, sort = 1 where id = 'gt-os';
update public.branches set name = '골든타임365신경외과(철산점)', active = true, sort = 2 where id = 'gt-cs';
update public.branches set active = false, sort = 9 where id in ('gt-ns', 'gt-pj');

insert into public.doctors(branch_id, name, sort, active)
select 'gt-os', '설정훈 원장', 8, false
where not exists (select 1 from public.doctors where branch_id = 'gt-os' and name = '설정훈 원장');

-- 일회성 이관 함수: 이관 직후 drop 합니다
create or replace function public.import_daily(p_token text, p_rows jsonb) returns int
language plpgsql security definer set search_path = public as
$$
declare r jsonb; n int := 0;
begin
  if p_token <> '(삭제됨-일회용 이관 토큰, 함수도 삭제됨)' then raise exception 'bad token'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    insert into daily_close(branch_id, close_date, total, nonpay, outpatient, inpatient, surgery_cnt,
      pay_cash, resv, doctors, pt, extra, note)
    values ('gt-os', (r->>'date')::date, (r->>'total')::bigint, (r->>'nonpay')::bigint, (r->>'outpatient')::bigint,
      (r->>'inpatient')::bigint, (r->>'surgery')::int, (r->>'cash_real')::bigint,
      jsonb_build_object('real', (r->>'real')::int, 'visit', (r->>'visit')::int),
      r->'doctors', r->'pt', r->'extra', null)
    on conflict (branch_id, close_date) do update set
      total = excluded.total, nonpay = excluded.nonpay, outpatient = excluded.outpatient, inpatient = excluded.inpatient,
      surgery_cnt = excluded.surgery_cnt, pay_cash = excluded.pay_cash,
      resv = daily_close.resv || excluded.resv, doctors = excluded.doctors, pt = excluded.pt, extra = excluded.extra;
    n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.import_daily(text, jsonb) to anon, authenticated;

select id, name, active from public.branches order by sort;
