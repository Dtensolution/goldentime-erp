-- 6차: 연장·야간·공휴일 근무 기록 (수당 계산 없음, 시간 정리만)
create table if not exists public.overtime (
  id bigint generated always as identity primary key,
  branch_id text not null references public.branches(id),
  staff_id bigint references public.staff(id) on delete set null,
  staff_name text not null, dept text,
  work_date date not null, start_min int, end_min int, minutes int not null default 0,
  kind text not null default '연장',  -- 연장, 점심, 저녁, 공휴일, 야간
  note text, created_by uuid, created_at timestamptz not null default now(),
  approved boolean not null default false
);
create index if not exists overtime_day on public.overtime(branch_id, work_date);
alter table public.overtime enable row level security;
drop policy if exists ot_sel on public.overtime;
create policy ot_sel on public.overtime for select to authenticated using (
  (my_level() = 1 or branch_id = my_branch()) and (my_level() <= 2 or (my_level() = 3 and dept = my_dept())
   or staff_name = (select name from profiles where user_id = auth.uid())));
drop policy if exists ot_ins on public.overtime;
create policy ot_ins on public.overtime for insert to authenticated with check (
  (my_level() = 1 or branch_id = my_branch()) and (my_level() <= 2 or (my_level() = 3 and dept = my_dept())
   or (staff_name = (select name from profiles where user_id = auth.uid()) and not approved)));
drop policy if exists ot_upd on public.overtime;
create policy ot_upd on public.overtime for update to authenticated using (
  (my_level() = 1 or branch_id = my_branch()) and (my_level() <= 2 or (my_level() = 3 and dept = my_dept())
   or (staff_name = (select name from profiles where user_id = auth.uid()) and not approved)))
  with check ((my_level() = 1 or branch_id = my_branch()) and (my_level() <= 3 or not approved));
drop policy if exists ot_del on public.overtime;
create policy ot_del on public.overtime for delete to authenticated using (
  (my_level() = 1 or branch_id = my_branch()) and (my_level() <= 2 or (my_level() = 3 and dept = my_dept())
   or (staff_name = (select name from profiles where user_id = auth.uid()) and not approved)));
create or replace function public.tg_ot() returns trigger language plpgsql security definer set search_path = public as
$$ begin if tg_op='INSERT' then new.created_by := coalesce(new.created_by, auth.uid()); end if; return new; end $$;
drop trigger if exists ot_touch on public.overtime;
create trigger ot_touch before insert on public.overtime for each row execute function public.tg_ot();

create or replace function public.import_ot(p_token text, p_rows jsonb) returns int
language plpgsql security definer set search_path = public as
$$ declare r jsonb; n int := 0; sid bigint; sdept text;
begin
  if p_token <> '(삭제됨-일회용 이관 토큰, 함수도 삭제됨)' then raise exception 'bad token'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    select id, dept into sid, sdept from staff where branch_id='gt-os' and name = r->>'name' order by active desc, id limit 1;
    if not exists (select 1 from overtime where branch_id='gt-os' and staff_name=r->>'name' and work_date=(r->>'date')::date
                   and coalesce(start_min,-1)=coalesce((r->>'s')::int,-1) and kind=r->>'kind') then
      insert into overtime(branch_id, staff_id, staff_name, dept, work_date, start_min, end_min, minutes, kind, note, approved)
      values ('gt-os', sid, r->>'name', coalesce(sdept, r->>'dept'), (r->>'date')::date, (r->>'s')::int, (r->>'e')::int, (r->>'m')::int, r->>'kind', nullif(r->>'note',''), true);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
grant execute on function public.import_ot(text, jsonb) to anon;
