-- 4차: 근전도 니들링 원장, 전직원 근무스케줄, 부서별 업무게시판
alter table public.appointments add column if not exists needle_doctor text;

-- ── 근무스케줄 ──
create table if not exists public.staff (
  id bigint generated always as identity primary key,
  branch_id text not null references public.branches(id),
  name text not null, dept text not null, memo text,
  sort int not null default 0, active boolean not null default true,
  unique (branch_id, dept, name)
);
create table if not exists public.shift_codes (
  id bigint generated always as identity primary key,
  branch_id text not null references public.branches(id),
  code text not null, label text, start_min int, end_min int,
  color text not null default 'blue', is_off boolean not null default false, sort int not null default 0,
  unique (branch_id, code)
);
create table if not exists public.shifts (
  staff_id bigint not null references public.staff(id) on delete cascade,
  work_date date not null,
  branch_id text not null references public.branches(id),
  value text not null, note text,
  updated_by uuid, updated_at timestamptz not null default now(),
  primary key (staff_id, work_date)
);
create index if not exists shifts_day on public.shifts(branch_id, work_date);

-- 편집: 1·2등급, 3등급은 자기 부서 직원, 개인 권한 sched_staff=edit 이면 전체
create or replace function public.can_edit_staff_dept(p_dept text) returns boolean
language sql stable security definer set search_path = public as
$$ select coalesce((select p.active and (p.level <= 2 or p.perms->>'sched_staff' = 'edit' or (p.level = 3 and p.dept = p_dept))
   from profiles p where p.user_id = auth.uid()), false) $$;

alter table public.staff enable row level security;
alter table public.shift_codes enable row level security;
alter table public.shifts enable row level security;
drop policy if exists st_sel on public.staff;
create policy st_sel on public.staff for select to authenticated using (my_level() = 1 or branch_id = my_branch());
drop policy if exists st_all on public.staff;
create policy st_all on public.staff for all to authenticated
  using ((my_level() = 1 or branch_id = my_branch()) and can_edit_staff_dept(dept))
  with check ((my_level() = 1 or branch_id = my_branch()) and can_edit_staff_dept(dept));
drop policy if exists sc_sel on public.shift_codes;
create policy sc_sel on public.shift_codes for select to authenticated using (my_level() = 1 or branch_id = my_branch());
drop policy if exists sc_all on public.shift_codes;
create policy sc_all on public.shift_codes for all to authenticated
  using (my_level() = 1 or (my_level() = 2 and branch_id = my_branch()))
  with check (my_level() = 1 or (my_level() = 2 and branch_id = my_branch()));
drop policy if exists sh_sel on public.shifts;
create policy sh_sel on public.shifts for select to authenticated using (my_level() = 1 or branch_id = my_branch());
drop policy if exists sh_all on public.shifts;
create policy sh_all on public.shifts for all to authenticated
  using ((my_level() = 1 or branch_id = my_branch()) and can_edit_staff_dept((select s.dept from staff s where s.id = staff_id)))
  with check ((my_level() = 1 or branch_id = my_branch()) and can_edit_staff_dept((select s.dept from staff s where s.id = staff_id)));

create or replace function public.tg_shift() returns trigger
language plpgsql security definer set search_path = public as
$$ begin new.updated_by := auth.uid(); new.updated_at := now(); return new; end $$;
drop trigger if exists shift_touch on public.shifts;
create trigger shift_touch before insert or update on public.shifts for each row execute function public.tg_shift();

-- ── 부서별 업무게시판 ──
create table if not exists public.dept_docs (
  id bigint generated always as identity primary key,
  branch_id text not null references public.branches(id),
  dept text not null, title text not null, body text not null default '',
  pinned boolean not null default false, sort int not null default 0,
  updated_by uuid, updated_at timestamptz not null default now(), created_at timestamptz not null default now()
);
create table if not exists public.dept_doc_revs (
  id bigint generated always as identity primary key,
  doc_id bigint not null references public.dept_docs(id) on delete cascade,
  branch_id text not null, title text, body text, saved_by uuid, saved_at timestamptz not null default now()
);
create or replace function public.can_edit_doc(p_dept text) returns boolean
language sql stable security definer set search_path = public as
$$ select coalesce((select p.active and (p.level <= 2 or p.dept = p_dept or (p_dept = '공통' and p.level <= 3))
   from profiles p where p.user_id = auth.uid()), false) $$;
alter table public.dept_docs enable row level security;
alter table public.dept_doc_revs enable row level security;
drop policy if exists dd_sel on public.dept_docs;
create policy dd_sel on public.dept_docs for select to authenticated using (my_level() = 1 or branch_id = my_branch());
drop policy if exists dd_all on public.dept_docs;
create policy dd_all on public.dept_docs for all to authenticated
  using ((my_level() = 1 or branch_id = my_branch()) and can_edit_doc(dept))
  with check ((my_level() = 1 or branch_id = my_branch()) and can_edit_doc(dept));
drop policy if exists dr_sel2 on public.dept_doc_revs;
create policy dr_sel2 on public.dept_doc_revs for select to authenticated using (my_level() = 1 or branch_id = my_branch());

create or replace function public.tg_doc() returns trigger
language plpgsql security definer set search_path = public as
$$ begin
  if tg_op = 'UPDATE' and (old.body is distinct from new.body or old.title is distinct from new.title) then
    insert into dept_doc_revs(doc_id, branch_id, title, body, saved_by, saved_at) values (old.id, old.branch_id, old.title, old.body, old.updated_by, old.updated_at);
  end if;
  new.updated_by := auth.uid(); new.updated_at := now(); return new; end $$;
drop trigger if exists doc_touch on public.dept_docs;
create trigger doc_touch before insert or update on public.dept_docs for each row execute function public.tg_doc();

-- 기본 근무 코드 (시트에서 쓰던 표기)
insert into public.shift_codes(branch_id, code, label, start_min, end_min, color, is_off, sort)
select b.id, v.code, v.label, v.s, v.e, v.color, v.off, v.sort from public.branches b,
 (values ('9-19','주간 9-19',540,1140,'blue',false,1),('9-22','종일 9-22',540,1320,'navy',false,2),('14-22','오후 14-22',840,1320,'teal',false,3),
         ('13-22','오후 13-22',780,1320,'teal',false,4),('19-22','야간진료 19-22',1140,1320,'purple',false,5),('9-16','9-16',540,960,'blue',false,6),
         ('9-17','9-17',540,1020,'blue',false,7),('10-20','10-20',600,1200,'blue',false,8),('주간','병동 주간',null,null,'blue',false,9),
         ('야간','병동 야간',null,null,'purple',false,10),('A','영상 A',null,null,'blue',false,11),('D','영상 D',null,null,'teal',false,12),
         ('E','영상 E',null,null,'purple',false,13),('OFF','휴무',null,null,'gray',true,20),('연차','연차',null,null,'orange',true,21),
         ('반차','반차',null,null,'orange',false,22),('병가','병가',null,null,'red',true,23),('학회','학회',null,null,'orange',true,24)) as v(code,label,s,e,color,off,sort)
where b.id in ('gt-os','gt-cs')
on conflict (branch_id, code) do nothing;

-- 일회성 이관 (이관 후 바로 삭제)
create or replace function public.import_shifts(p_token text, p_rows jsonb) returns int
language plpgsql security definer set search_path = public as
$$ declare r jsonb; sid bigint; n int := 0;
begin
  if p_token <> '(삭제됨-일회용 이관 토큰, 함수도 삭제됨)' then raise exception 'bad token'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    insert into staff(branch_id, name, dept, sort) values ('gt-os', r->>'name', r->>'dept', (r->>'sort')::int)
      on conflict (branch_id, dept, name) do update set sort = least(staff.sort, excluded.sort) returning id into sid;
    if r ? 'date' then
      insert into shifts(staff_id, work_date, branch_id, value, note) values (sid, (r->>'date')::date, 'gt-os', r->>'value', nullif(r->>'note',''))
        on conflict (staff_id, work_date) do update set value = excluded.value, note = excluded.note;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
grant execute on function public.import_shifts(text, jsonb) to anon;

select (select count(*) from public.shift_codes) codes;
