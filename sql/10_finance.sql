-- 10차: 수입·지출 (월별 입력 항목). 마감일지 수납·일일지출은 화면에서 자동 합산
create table if not exists public.fin_entries (
  id bigint generated always as identity primary key,
  branch_id text not null references public.branches(id),
  ym text not null check (ym ~ '^\d{4}-\d{2}$'),
  kind text not null check (kind in ('수입','지출')),
  category text not null,
  name text not null,
  amount bigint not null default 0,
  fixed boolean not null default false,
  memo text,
  sort int not null default 0,
  updated_by uuid, updated_at timestamptz not null default now(), created_at timestamptz not null default now()
);
create index if not exists fin_entries_ym on public.fin_entries(branch_id, ym);
alter table public.fin_entries enable row level security;
drop policy if exists fe_all on public.fin_entries;
create policy fe_all on public.fin_entries for all to authenticated
  using (my_level() = 1 or (my_level() = 2 and branch_id = my_branch()))
  with check (my_level() = 1 or (my_level() = 2 and branch_id = my_branch()));
drop trigger if exists fe_touch on public.fin_entries;
create trigger fe_touch before insert or update on public.fin_entries for each row execute function public.tg_rr();
