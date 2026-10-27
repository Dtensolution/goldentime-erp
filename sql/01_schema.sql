-- 골든타임 ERP (D:TEN) 1차 스키마
-- 지점 / 계정(등급) / 원장 / 일일 마감 / 변경 기록 + 등급별 RLS

create extension if not exists pgcrypto with schema extensions;

-- ── 테이블 ─────────────────────────────────────────────
create table if not exists public.branches (
  id text primary key,
  name text not null,
  active boolean not null default true,
  sort int not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  login_id text not null unique,
  name text not null,
  level smallint not null check (level between 1 and 4),
  branch_id text references public.branches(id),
  dept text,
  title text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.doctors (
  id bigint generated always as identity primary key,
  branch_id text not null references public.branches(id),
  name text not null,
  sort int not null default 0,
  active boolean not null default true
);

create table if not exists public.daily_close (
  id bigint generated always as identity primary key,
  branch_id text not null references public.branches(id),
  close_date date not null,
  -- 진료비
  total bigint not null default 0,
  nonpay bigint not null default 0,
  outpatient bigint not null default 0,
  inpatient bigint not null default 0,
  surgery_cnt int not null default 0,
  -- 수납
  pay_card bigint not null default 0,
  pay_cash bigint not null default 0,
  pay_account bigint not null default 0,
  unpaid bigint not null default 0,
  unpaid_in bigint not null default 0,
  -- 일일 지출 / 추가 수입
  exp_cash bigint not null default 0,
  exp_card bigint not null default 0,
  exp_free bigint not null default 0,
  inc_cash bigint not null default 0,
  inc_card bigint not null default 0,
  inc_account bigint not null default 0,
  -- 예약: {"items":{"주사":{"resv":0,"change":0,"cancel":0},...},"real":0,"visit":0,"why":{"일정":0,"연락안됨":0,"기타":0}}
  resv jsonb not null default '{}'::jsonb,
  -- 원장별 환자: [{"doctor_id":1,"name":"..","new":0,"re":0}]
  doctors jsonb not null default '[]'::jsonb,
  -- 초진 내원경로: {"지인소개":0,...}
  paths jsonb not null default '{}'::jsonb,
  note text,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (branch_id, close_date)
);

create table if not exists public.audit_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  user_id uuid,
  branch_id text,
  action text not null,
  target text,
  detail jsonb
);

-- ── 내 정보 헬퍼 ───────────────────────────────────────
create or replace function public.my_level() returns int
language sql stable security definer set search_path = public as
$$ select coalesce((select level from profiles where user_id = auth.uid() and active), 99) $$;

create or replace function public.my_branch() returns text
language sql stable security definer set search_path = public as
$$ select branch_id from profiles where user_id = auth.uid() and active $$;

create or replace function public.my_dept() returns text
language sql stable security definer set search_path = public as
$$ select dept from profiles where user_id = auth.uid() and active $$;

create or replace function public.kst_today() returns date
language sql stable as
$$ select (now() at time zone 'Asia/Seoul')::date $$;

-- ── RLS ───────────────────────────────────────────────
alter table public.branches   enable row level security;
alter table public.profiles   enable row level security;
alter table public.doctors    enable row level security;
alter table public.daily_close enable row level security;
alter table public.audit_log  enable row level security;

drop policy if exists br_sel on public.branches;
create policy br_sel on public.branches for select to authenticated
  using (my_level() = 1 or id = my_branch());
drop policy if exists br_all on public.branches;
create policy br_all on public.branches for all to authenticated
  using (my_level() = 1) with check (my_level() = 1);

drop policy if exists pf_sel on public.profiles;
create policy pf_sel on public.profiles for select to authenticated
  using (
    user_id = auth.uid()
    or my_level() = 1
    or (my_level() = 2 and branch_id = my_branch())
    or (my_level() = 3 and branch_id = my_branch() and dept = my_dept())
  );

drop policy if exists dr_sel on public.doctors;
create policy dr_sel on public.doctors for select to authenticated
  using (my_level() = 1 or branch_id = my_branch());
drop policy if exists dr_all on public.doctors;
create policy dr_all on public.doctors for all to authenticated
  using (my_level() = 1 or (my_level() = 2 and branch_id = my_branch()))
  with check (my_level() = 1 or (my_level() = 2 and branch_id = my_branch()));

-- 일일 마감: 1등급 전체 / 2등급 자기 지점 / 3등급 원무 부서장 자기 지점 / 4등급 원무 직원은 어제·오늘만
drop policy if exists dc_sel on public.daily_close;
create policy dc_sel on public.daily_close for select to authenticated
  using (
    my_level() = 1
    or (my_level() = 2 and branch_id = my_branch())
    or (my_level() = 3 and branch_id = my_branch() and my_dept() = '원무')
    or (my_level() = 4 and branch_id = my_branch() and my_dept() = '원무' and close_date >= kst_today() - 1)
  );
drop policy if exists dc_ins on public.daily_close;
create policy dc_ins on public.daily_close for insert to authenticated
  with check (
    my_level() = 1
    or (my_level() = 2 and branch_id = my_branch())
    or (my_level() = 3 and branch_id = my_branch() and my_dept() = '원무')
    or (my_level() = 4 and branch_id = my_branch() and my_dept() = '원무' and close_date between kst_today() - 1 and kst_today())
  );
drop policy if exists dc_upd on public.daily_close;
create policy dc_upd on public.daily_close for update to authenticated
  using (
    my_level() = 1
    or (my_level() = 2 and branch_id = my_branch())
    or (my_level() = 3 and branch_id = my_branch() and my_dept() = '원무')
    or (my_level() = 4 and branch_id = my_branch() and my_dept() = '원무' and close_date between kst_today() - 1 and kst_today())
  )
  with check (
    my_level() = 1
    or (my_level() = 2 and branch_id = my_branch())
    or (my_level() = 3 and branch_id = my_branch() and my_dept() = '원무')
    or (my_level() = 4 and branch_id = my_branch() and my_dept() = '원무' and close_date between kst_today() - 1 and kst_today())
  );
drop policy if exists dc_del on public.daily_close;
create policy dc_del on public.daily_close for delete to authenticated
  using (my_level() = 1 or (my_level() = 2 and branch_id = my_branch()));

drop policy if exists al_sel on public.audit_log;
create policy al_sel on public.audit_log for select to authenticated
  using (my_level() = 1 or (my_level() = 2 and branch_id = my_branch()));

-- ── 변경 기록 트리거 ───────────────────────────────────
create or replace function public.tg_daily_close() returns trigger
language plpgsql security definer set search_path = public as
$$
begin
  if tg_op = 'INSERT' then
    new.created_by := auth.uid();
    new.updated_by := auth.uid();
    new.created_at := now();
  else
    new.created_by := old.created_by;
    new.created_at := old.created_at;
    new.updated_by := auth.uid();
  end if;
  new.updated_at := now();
  insert into audit_log(user_id, branch_id, action, target, detail)
  values (auth.uid(), new.branch_id, lower(tg_op), 'daily_close:' || new.close_date,
          jsonb_build_object('total', new.total));
  return new;
end $$;
drop trigger if exists daily_close_audit on public.daily_close;
create trigger daily_close_audit before insert or update on public.daily_close
  for each row execute function public.tg_daily_close();

-- ── 계정 관리 RPC (비밀번호는 관리자가 앱에서 지정) ───────
create or replace function public.admin_create_user(
  p_login text, p_password text, p_name text, p_level int,
  p_branch text, p_dept text default null, p_title text default null
) returns uuid
language plpgsql security definer set search_path = public, extensions, auth as
$$
declare
  v_uid uuid := gen_random_uuid();
  v_email text := lower(trim(p_login)) || '@gterp.local';
  v_lv int := my_level();
begin
  if v_lv > 2 then raise exception '계정 생성 권한이 없습니다'; end if;
  if v_lv = 2 and (p_level < 3 or p_branch is distinct from my_branch()) then
    raise exception '원장 계정은 자기 지점의 부서장·직원 계정만 만들 수 있습니다';
  end if;
  if p_login !~ '^[A-Za-z0-9._-]{3,30}$' then raise exception '아이디는 영문·숫자 3~30자로 정해주세요'; end if;
  if length(p_password) < 8 then raise exception '비밀번호는 8자 이상이어야 합니다'; end if;
  if exists (select 1 from profiles where login_id = lower(trim(p_login))) then raise exception '이미 있는 아이디입니다'; end if;

  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated', v_email,
    crypt(p_password, gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}', jsonb_build_object('name', p_name), now(), now(),
    '', '', '', '');

  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), v_uid, v_uid::text,
    jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true),
    'email', now(), now(), now());

  insert into profiles(user_id, login_id, name, level, branch_id, dept, title)
  values (v_uid, lower(trim(p_login)), p_name, p_level, p_branch, nullif(p_dept,''), nullif(p_title,''));

  insert into audit_log(user_id, branch_id, action, target, detail)
  values (auth.uid(), p_branch, 'create_user', p_login, jsonb_build_object('level', p_level, 'dept', p_dept));
  return v_uid;
end $$;

create or replace function public.admin_update_user(
  p_user uuid, p_name text, p_level int, p_branch text, p_dept text, p_title text, p_active boolean
) returns void
language plpgsql security definer set search_path = public as
$$
declare v_lv int := my_level(); t profiles;
begin
  select * into t from profiles where user_id = p_user;
  if not found then raise exception '계정을 찾을 수 없습니다'; end if;
  if v_lv > 2 then raise exception '권한이 없습니다'; end if;
  if v_lv = 2 and (t.branch_id is distinct from my_branch() or t.level < 3 or p_level < 3 or p_branch is distinct from my_branch()) then
    raise exception '원장 계정은 자기 지점의 부서장·직원만 수정할 수 있습니다';
  end if;
  if p_user = auth.uid() and (p_level <> t.level or not p_active) then raise exception '본인 등급이나 사용 여부는 바꿀 수 없습니다'; end if;
  update profiles set name = p_name, level = p_level, branch_id = p_branch,
    dept = nullif(p_dept,''), title = nullif(p_title,''), active = p_active where user_id = p_user;
  insert into audit_log(user_id, branch_id, action, target, detail)
  values (auth.uid(), p_branch, 'update_user', t.login_id, jsonb_build_object('level', p_level, 'active', p_active));
end $$;

create or replace function public.admin_reset_password(p_user uuid, p_password text) returns void
language plpgsql security definer set search_path = public, extensions, auth as
$$
declare v_lv int := my_level(); t profiles;
begin
  select * into t from profiles where user_id = p_user;
  if not found then raise exception '계정을 찾을 수 없습니다'; end if;
  if v_lv > 2 or (v_lv = 2 and (t.branch_id is distinct from my_branch() or t.level < 3)) then
    raise exception '권한이 없습니다';
  end if;
  if length(p_password) < 8 then raise exception '비밀번호는 8자 이상이어야 합니다'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = p_user;
  insert into audit_log(user_id, branch_id, action, target) values (auth.uid(), t.branch_id, 'reset_password', t.login_id);
end $$;

revoke all on function public.admin_create_user(text,text,text,int,text,text,text) from public, anon;
revoke all on function public.admin_update_user(uuid,text,int,text,text,text,boolean) from public, anon;
revoke all on function public.admin_reset_password(uuid,text) from public, anon;
grant execute on function public.admin_create_user(text,text,text,int,text,text,text) to authenticated;
grant execute on function public.admin_update_user(uuid,text,int,text,text,text,boolean) to authenticated;
grant execute on function public.admin_reset_password(uuid,text) to authenticated;

-- ── 기본 데이터 ────────────────────────────────────────
insert into public.branches(id, name, active, sort) values
  ('gt-os', '골든타임365정형외과', true, 1),
  ('gt-ns', '골든타임365신경외과의원', false, 2),
  ('gt-cs', '철산골든타임365신경외과', false, 3),
  ('gt-pj', '골든타임파주', false, 4)
on conflict (id) do nothing;

insert into public.doctors(branch_id, name, sort, active)
select 'gt-os', v.name, v.sort, v.active from (values
  ('대표원장', 1, true), ('박현우 원장', 2, true), ('정대우 원장', 3, true), ('조승우 원장', 4, true),
  ('이승우 원장', 5, false), ('권순찬 원장', 6, false), ('정종은 원장', 7, false)
) as v(name, sort, active)
where not exists (select 1 from public.doctors where branch_id = 'gt-os');

select 'ok' as result,
  (select count(*) from public.branches) as branches,
  (select count(*) from public.doctors) as doctors;
