-- 8차: 업무 기록부(시트형 목록), 예약관리, 연차관리
create table if not exists public.registers (
  id bigint generated always as identity primary key,
  branch_id text not null references public.branches(id),
  dept text not null, name text not null, columns jsonb not null default '[]',
  date_col text, sort int not null default 0, active boolean not null default true, memo text,
  created_at timestamptz not null default now()
);
create table if not exists public.register_rows (
  id bigint generated always as identity primary key,
  register_id bigint not null references public.registers(id) on delete cascade,
  branch_id text not null, row_date date, data jsonb not null default '{}', sort int not null default 0,
  updated_by uuid, updated_at timestamptz not null default now(), created_at timestamptz not null default now()
);
create index if not exists register_rows_r on public.register_rows(register_id, row_date);
create or replace function public.reg_dept(p_reg bigint) returns text language sql stable security definer set search_path = public as
$$ select dept from registers where id = p_reg $$;
create or replace function public.can_reg(p_dept text, p_write boolean) returns boolean language sql stable security definer set search_path = public as
$$ select coalesce((select p.active and (p.level <= 2 or p.dept = p_dept or (p_dept = '공통' and (not p_write or p.level <= 3)))
   from profiles p where p.user_id = auth.uid()), false) $$;
alter table public.registers enable row level security;
alter table public.register_rows enable row level security;
drop policy if exists rg_sel on public.registers;
create policy rg_sel on public.registers for select to authenticated using ((my_level() = 1 or branch_id = my_branch()) and can_reg(dept, false));
drop policy if exists rg_all on public.registers;
create policy rg_all on public.registers for all to authenticated using ((my_level() = 1 or branch_id = my_branch()) and (my_level() <= 3) and can_reg(dept, true))
  with check ((my_level() = 1 or branch_id = my_branch()) and (my_level() <= 3) and can_reg(dept, true));
drop policy if exists rr_sel on public.register_rows;
create policy rr_sel on public.register_rows for select to authenticated using ((my_level() = 1 or branch_id = my_branch()) and can_reg(reg_dept(register_id), false));
drop policy if exists rr_all on public.register_rows;
create policy rr_all on public.register_rows for all to authenticated using ((my_level() = 1 or branch_id = my_branch()) and can_reg(reg_dept(register_id), true))
  with check ((my_level() = 1 or branch_id = my_branch()) and can_reg(reg_dept(register_id), true));
create or replace function public.tg_rr() returns trigger language plpgsql security definer set search_path = public as
$$ begin new.updated_by := auth.uid(); new.updated_at := now(); return new; end $$;
drop trigger if exists rr_touch on public.register_rows;
create trigger rr_touch before insert or update on public.register_rows for each row execute function public.tg_rr();

-- 예약관리
create table if not exists public.reservations (
  id bigint generated always as identity primary key,
  branch_id text not null references public.branches(id),
  resv_date date not null, resv_time text, chart_no text, patient_name text, phone text,
  subject text, doctor text, insurance text, memo text, note text,
  visit text,            -- 내원 / 변경 / 취소 / null(확인 전)
  reason text, source text not null default 'manual',
  updated_by uuid, updated_at timestamptz not null default now(), created_at timestamptz not null default now()
);
create index if not exists resv_day on public.reservations(branch_id, resv_date);
create or replace function public.can_resv() returns boolean language sql stable security definer set search_path = public as
$$ select coalesce((select p.active and (p.level <= 2 or p.dept in ('원무','간호','물리치료','임상병리','병동') or p.level = 3) from profiles p where p.user_id = auth.uid()), false) $$;
alter table public.reservations enable row level security;
drop policy if exists rv_sel on public.reservations;
create policy rv_sel on public.reservations for select to authenticated using ((my_level() = 1 or branch_id = my_branch()) and can_resv());
drop policy if exists rv_all on public.reservations;
create policy rv_all on public.reservations for all to authenticated using ((my_level() = 1 or branch_id = my_branch()) and can_resv()) with check ((my_level() = 1 or branch_id = my_branch()) and can_resv());
drop trigger if exists rv_touch on public.reservations;
create trigger rv_touch before insert or update on public.reservations for each row execute function public.tg_rr();

-- 연차관리
create table if not exists public.leave_grants (
  id bigint generated always as identity primary key,
  branch_id text not null references public.branches(id),
  staff_id bigint references public.staff(id) on delete set null, staff_name text not null, dept text,
  year int not null, hire_date date, days numeric not null default 0, note text,
  unique (branch_id, staff_name, year)
);
create table if not exists public.leave_uses (
  id bigint generated always as identity primary key,
  branch_id text not null references public.branches(id),
  staff_id bigint references public.staff(id) on delete set null, staff_name text not null, dept text,
  use_date date not null, kind text not null default '연차', days numeric not null default 1, note text,
  approved boolean not null default false, created_by uuid, created_at timestamptz not null default now()
);
create index if not exists leave_uses_d on public.leave_uses(branch_id, use_date);
alter table public.leave_grants enable row level security;
alter table public.leave_uses enable row level security;
drop policy if exists lg_sel on public.leave_grants;
create policy lg_sel on public.leave_grants for select to authenticated using ((my_level() = 1 or branch_id = my_branch()) and (my_level() <= 2 or (my_level() = 3 and dept = my_dept()) or staff_name = (select name from profiles where user_id = auth.uid())));
drop policy if exists lg_all on public.leave_grants;
create policy lg_all on public.leave_grants for all to authenticated using ((my_level() = 1 or branch_id = my_branch()) and my_level() <= 2) with check ((my_level() = 1 or branch_id = my_branch()) and my_level() <= 2);
drop policy if exists lu_sel on public.leave_uses;
create policy lu_sel on public.leave_uses for select to authenticated using ((my_level() = 1 or branch_id = my_branch()) and (my_level() <= 2 or (my_level() = 3 and dept = my_dept()) or staff_name = (select name from profiles where user_id = auth.uid())));
drop policy if exists lu_ins on public.leave_uses;
create policy lu_ins on public.leave_uses for insert to authenticated with check ((my_level() = 1 or branch_id = my_branch()) and (my_level() <= 2 or (my_level() = 3 and dept = my_dept()) or (staff_name = (select name from profiles where user_id = auth.uid()) and not approved)));
drop policy if exists lu_upd on public.leave_uses;
create policy lu_upd on public.leave_uses for update to authenticated using ((my_level() = 1 or branch_id = my_branch()) and (my_level() <= 2 or (my_level() = 3 and dept = my_dept()))) with check ((my_level() = 1 or branch_id = my_branch()) and my_level() <= 3);
drop policy if exists lu_del on public.leave_uses;
create policy lu_del on public.leave_uses for delete to authenticated using ((my_level() = 1 or branch_id = my_branch()) and (my_level() <= 2 or (my_level() = 3 and dept = my_dept()) or (staff_name = (select name from profiles where user_id = auth.uid()) and not approved)));
drop trigger if exists lu_touch on public.leave_uses;
create trigger lu_touch before insert on public.leave_uses for each row execute function public.tg_ot();
