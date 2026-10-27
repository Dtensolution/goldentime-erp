-- 3차: 도수·충격파 / 근전도 스케줄 + 개인별 메뉴 권한
alter table public.profiles add column if not exists perms jsonb not null default '{}'::jsonb;  -- {"sched_pt":"none|view|edit","sched_emg":"..."}

create table if not exists public.sched_lanes (
  id bigint generated always as identity primary key,
  branch_id text not null references public.branches(id),
  kind text not null check (kind in ('pt','emg')),
  name text not null, grp text, sort int not null default 0, active boolean not null default true
);
create table if not exists public.sched_items (
  id bigint generated always as identity primary key,
  branch_id text not null references public.branches(id),
  kind text not null check (kind in ('pt','emg')),
  name text not null, minutes int not null default 30, price int not null default 0,
  sort int not null default 0, active boolean not null default true
);
create table if not exists public.appointments (
  id bigint generated always as identity primary key,
  branch_id text not null references public.branches(id),
  kind text not null check (kind in ('pt','emg')),
  appt_date date not null,
  start_min int not null check (start_min between 0 and 1439),   -- 자정부터 분 (9:00 = 540)
  minutes int not null default 30 check (minutes between 5 and 240),
  lane_id bigint references public.sched_lanes(id),
  chart_no text, patient_name text,
  item text not null,
  staff text, doctor text,
  status text not null default '예약' check (status in ('예약','완료','취소','노쇼')),
  inpatient boolean not null default false,
  is_new boolean not null default false,
  note text,
  created_by uuid, updated_by uuid,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists appt_day on public.appointments(branch_id, kind, appt_date);
create table if not exists public.sched_day_notes (
  branch_id text not null references public.branches(id),
  kind text not null check (kind in ('pt','emg')),
  note_date date not null, note text,
  updated_by uuid, updated_at timestamptz not null default now(),
  primary key (branch_id, kind, note_date)
);

-- 권한: 개인 지정(perms)이 있으면 그것, 없으면 기본값
-- 기본: 보기 = 지점 전원 / 편집 = 1·2등급, 도수(물리치료·원무), 근전도(임상병리·원무)
create or replace function public.sched_perm(p_kind text) returns text
language sql stable security definer set search_path = public as
$$
  select case
    when p.user_id is null or not p.active then 'none'
    when p.level = 1 then 'edit'
    when p.perms ? ('sched_' || p_kind) then p.perms ->> ('sched_' || p_kind)
    when p.level = 2 then 'edit'
    when p_kind = 'pt'  and p.dept in ('물리치료','원무') then 'edit'
    when p_kind = 'emg' and p.dept in ('임상병리','원무') then 'edit'
    else 'view' end
  from (select 1) d left join profiles p on p.user_id = auth.uid()
$$;

alter table public.sched_lanes enable row level security;
alter table public.sched_items enable row level security;
alter table public.appointments enable row level security;
alter table public.sched_day_notes enable row level security;

drop policy if exists sl_sel on public.sched_lanes;
create policy sl_sel on public.sched_lanes for select to authenticated using (my_level() = 1 or branch_id = my_branch());
drop policy if exists sl_all on public.sched_lanes;
create policy sl_all on public.sched_lanes for all to authenticated
  using (my_level() = 1 or (my_level() = 2 and branch_id = my_branch()))
  with check (my_level() = 1 or (my_level() = 2 and branch_id = my_branch()));
drop policy if exists si_sel on public.sched_items;
create policy si_sel on public.sched_items for select to authenticated using (my_level() = 1 or branch_id = my_branch());
drop policy if exists si_all on public.sched_items;
create policy si_all on public.sched_items for all to authenticated
  using (my_level() = 1 or (my_level() = 2 and branch_id = my_branch()))
  with check (my_level() = 1 or (my_level() = 2 and branch_id = my_branch()));

drop policy if exists ap_sel on public.appointments;
create policy ap_sel on public.appointments for select to authenticated
  using ((my_level() = 1 or branch_id = my_branch()) and sched_perm(kind) in ('view','edit'));
drop policy if exists ap_ins on public.appointments;
create policy ap_ins on public.appointments for insert to authenticated
  with check ((my_level() = 1 or branch_id = my_branch()) and sched_perm(kind) = 'edit');
drop policy if exists ap_upd on public.appointments;
create policy ap_upd on public.appointments for update to authenticated
  using ((my_level() = 1 or branch_id = my_branch()) and sched_perm(kind) = 'edit')
  with check ((my_level() = 1 or branch_id = my_branch()) and sched_perm(kind) = 'edit');
drop policy if exists ap_del on public.appointments;
create policy ap_del on public.appointments for delete to authenticated
  using ((my_level() = 1 or branch_id = my_branch()) and sched_perm(kind) = 'edit');

drop policy if exists sn_sel on public.sched_day_notes;
create policy sn_sel on public.sched_day_notes for select to authenticated
  using ((my_level() = 1 or branch_id = my_branch()) and sched_perm(kind) in ('view','edit'));
drop policy if exists sn_all on public.sched_day_notes;
create policy sn_all on public.sched_day_notes for all to authenticated
  using ((my_level() = 1 or branch_id = my_branch()) and sched_perm(kind) = 'edit')
  with check ((my_level() = 1 or branch_id = my_branch()) and sched_perm(kind) = 'edit');

-- 변경 기록 (누가 넣고/고치고/지웠는지)
create or replace function public.tg_appt() returns trigger
language plpgsql security definer set search_path = public as
$$
declare r appointments;
begin
  if tg_op = 'DELETE' then r := old; else r := new; end if;
  if tg_op = 'INSERT' then new.created_by := auth.uid(); new.created_at := now(); end if;
  if tg_op = 'UPDATE' then new.created_by := old.created_by; new.created_at := old.created_at; end if;
  if tg_op <> 'DELETE' then new.updated_by := auth.uid(); new.updated_at := now(); end if;
  insert into audit_log(user_id, branch_id, action, target, detail)
  values (auth.uid(), r.branch_id, 'appt_' || lower(tg_op), r.kind || ':' || r.appt_date,
          jsonb_build_object('chart', r.chart_no, 'item', r.item, 'status', r.status,
                             'time', lpad((r.start_min/60)::text,2,'0') || ':' || lpad((r.start_min%60)::text,2,'0')));
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
drop trigger if exists appt_audit on public.appointments;
create trigger appt_audit before insert or update or delete on public.appointments
  for each row execute function public.tg_appt();

-- 개인별 권한 지정 (1등급: 누구나 / 2등급: 자기 지점 3·4등급)
create or replace function public.admin_set_perms(p_user uuid, p_perms jsonb) returns void
language plpgsql security definer set search_path = public as
$$
declare v_lv int := my_level(); t profiles; k text;
begin
  select * into t from profiles where user_id = p_user;
  if not found then raise exception '계정을 찾을 수 없습니다'; end if;
  if v_lv > 2 or (v_lv = 2 and (t.branch_id is distinct from my_branch() or t.level < 3)) then raise exception '권한이 없습니다'; end if;
  for k in select jsonb_object_keys(p_perms) loop
    if k not in ('sched_pt','sched_emg') or (p_perms->>k) not in ('none','view','edit','default') then raise exception '잘못된 권한 값'; end if;
  end loop;
  update profiles set perms = (
    select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    from jsonb_each(perms || p_perms) where value::text <> '"default"')
  where user_id = p_user;
  insert into audit_log(user_id, branch_id, action, target, detail) values (auth.uid(), t.branch_id, 'set_perms', t.login_id, p_perms);
end $$;
revoke all on function public.admin_set_perms(uuid, jsonb) from public, anon;
grant execute on function public.admin_set_perms(uuid, jsonb) to authenticated;

-- 기본 방·치료항목 (구글시트 구성 그대로, 운정점·철산점)
insert into public.sched_lanes(branch_id, kind, name, grp, sort)
select b.id, v.kind, v.name, v.grp, v.sort from public.branches b,
  (values ('pt','1번방','도수치료',1),('pt','2번방','도수치료',2),('pt','충격파 1번방','체외충격파',3),('pt','충격파 2번방','체외충격파',4),
          ('emg','근전도','근전도',1)) as v(kind,name,grp,sort)
where b.id in ('gt-os','gt-cs') and not exists (select 1 from public.sched_lanes l where l.branch_id = b.id);

insert into public.sched_items(branch_id, kind, name, minutes, price, sort)
select b.id, v.kind, v.name, v.minutes, v.price, v.sort from public.branches b,
  (values ('pt','도수A',30,80000,1),('pt','도수B',50,130000,2),('pt','도수C',80,200000,3),('pt','도수E2A',30,0,4),('pt','도수E2B',50,0,5),
          ('pt','충격파A',10,80000,6),('pt','충격파B',20,130000,7),('pt','충격파13',20,130000,8),('pt','충격파18',30,180000,9),('pt','도수상담',10,0,10),
          ('emg','상지편측',20,0,1),('emg','하지편측',30,86600,2),('emg','상지양측',40,77600,3),('emg','하지양측',60,0,4),
          ('emg','상하지편측',60,0,5),('emg','상하지양측',90,0,6),('emg','근전도 결과',10,0,7)) as v(kind,name,minutes,price,sort)
where b.id in ('gt-os','gt-cs') and not exists (select 1 from public.sched_items i where i.branch_id = b.id);

select (select count(*) from public.sched_lanes) lanes, (select count(*) from public.sched_items) items;
