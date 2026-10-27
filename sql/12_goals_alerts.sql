-- 12차: 월 목표 · 이상신호 기준 · 영업일(공휴일, 토요일 가중치)
create table if not exists public.branch_targets (
  id bigint generated always as identity primary key,
  branch_id text not null references public.branches(id),
  ym text not null check (ym ~ '^\d{4}-\d{2}$'),
  metric text not null check (metric in ('total','newP','visits','pt','npRate','nonpay')),
  value numeric not null default 0,
  updated_by uuid, updated_at timestamptz not null default now(), created_at timestamptz not null default now(),
  unique (branch_id, ym, metric)
);
create table if not exists public.branch_settings (
  branch_id text primary key references public.branches(id),
  data jsonb not null default '{}'::jsonb,   -- {"alerts":{key:{on,th}}, "sat":0.5, "holidays":[{"d":"2026-12-25","n":"성탄절"}]}
  updated_by uuid, updated_at timestamptz not null default now(), created_at timestamptz not null default now()
);
alter table public.branch_targets enable row level security;
alter table public.branch_settings enable row level security;
-- 보기: 대시보드를 볼 수 있는 사람(1·2등급, 원무 부서장) / 고치기: 1·2등급(목표), 1등급(알림 기준·영업일)
drop policy if exists bt_sel on public.branch_targets;
create policy bt_sel on public.branch_targets for select to authenticated
  using (my_level() = 1 or (branch_id = my_branch() and (my_level() = 2 or (my_level() = 3 and my_dept() = '원무'))));
drop policy if exists bt_all on public.branch_targets;
create policy bt_all on public.branch_targets for all to authenticated
  using (my_level() = 1 or (my_level() = 2 and branch_id = my_branch()))
  with check (my_level() = 1 or (my_level() = 2 and branch_id = my_branch()));
drop policy if exists bs_sel on public.branch_settings;
create policy bs_sel on public.branch_settings for select to authenticated using (my_level() = 1 or branch_id = my_branch());
drop policy if exists bs_all on public.branch_settings;
create policy bs_all on public.branch_settings for all to authenticated using (my_level() = 1) with check (my_level() = 1);
drop trigger if exists bt_touch on public.branch_targets;
create trigger bt_touch before insert or update on public.branch_targets for each row execute function public.tg_rr();
drop trigger if exists bs_touch on public.branch_settings;
create trigger bs_touch before insert or update on public.branch_settings for each row execute function public.tg_rr();
