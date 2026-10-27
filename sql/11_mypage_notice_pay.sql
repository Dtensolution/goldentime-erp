-- 11차: 본인 비밀번호 변경일, 필독 공지·읽음 확인, 인건비·인센티브(1등급 전용)
alter table public.profiles add column if not exists pw_changed_at timestamptz;
create or replace function public.mark_pw_changed() returns void
language sql security definer set search_path = public as
$$ update profiles set pw_changed_at = now() where user_id = auth.uid() $$;
revoke all on function public.mark_pw_changed() from public, anon;
grant execute on function public.mark_pw_changed() to authenticated;

-- 필독 공지
alter table public.dept_docs add column if not exists notice boolean not null default false;
create table if not exists public.doc_reads (
  doc_id bigint not null references public.dept_docs(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  branch_id text, read_at timestamptz not null default now(),
  primary key (doc_id, user_id)
);
alter table public.doc_reads enable row level security;
drop policy if exists drd_sel on public.doc_reads;
create policy drd_sel on public.doc_reads for select to authenticated
  using (user_id = auth.uid() or my_level() = 1 or (my_level() <= 3 and branch_id = my_branch()));
drop policy if exists drd_ins on public.doc_reads;
create policy drd_ins on public.doc_reads for insert to authenticated
  with check (user_id = auth.uid() and (my_level() = 1 or branch_id = my_branch()));
drop policy if exists drd_upd on public.doc_reads;
create policy drd_upd on public.doc_reads for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 읽음 현황: 공지 대상(공통=지점 전체, 부서 글=그 부서) 중 읽은 사람 / 안 읽은 사람
create or replace function public.doc_read_summary(p_doc bigint) returns json
language plpgsql stable security definer set search_path = public as
$$
declare d record; me record;
begin
  select * into d from dept_docs where id = p_doc; if not found then return null; end if;
  select * into me from profiles where user_id = auth.uid();
  if me is null or not me.active or not (me.level = 1 or (me.level <= 3 and me.branch_id = d.branch_id)) then
    raise exception '권한이 없습니다';
  end if;
  return (select json_build_object(
    'read', coalesce((select json_agg(json_build_object('name', p.name, 'dept', p.dept, 'at', r.read_at) order by r.read_at)
              from doc_reads r join profiles p on p.user_id = r.user_id where r.doc_id = p_doc), '[]'::json),
    'unread', coalesce((select json_agg(json_build_object('name', p.name, 'dept', p.dept) order by p.dept, p.name)
              from profiles p where p.active and p.level >= 2 and p.branch_id = d.branch_id
                and (d.dept = '공통' or p.dept = d.dept)
                and not exists (select 1 from doc_reads r where r.doc_id = p_doc and r.user_id = p.user_id)), '[]'::json)));
end $$;
revoke all on function public.doc_read_summary(bigint) from public, anon;
grant execute on function public.doc_read_summary(bigint) to authenticated;

-- 인건비·인센티브 (1등급만)
create table if not exists public.pay_people (
  id bigint generated always as identity primary key,
  branch_id text not null references public.branches(id),
  staff_id bigint references public.staff(id) on delete set null,
  name text not null, dept text, base_monthly bigint not null default 0,
  memo text, active boolean not null default true, sort int not null default 0,
  updated_by uuid, updated_at timestamptz not null default now(), created_at timestamptz not null default now()
);
create table if not exists public.pay_rates (
  id bigint generated always as identity primary key,
  branch_id text not null references public.branches(id),
  person_id bigint references public.pay_people(id) on delete cascade,   -- null = 지점 공통 단가
  kind text not null check (kind in ('pt','emg')),
  item text not null, rate bigint not null default 0,
  updated_by uuid, updated_at timestamptz not null default now(), created_at timestamptz not null default now()
);
create unique index if not exists pay_rates_u on public.pay_rates(branch_id, coalesce(person_id, 0), kind, item);
create table if not exists public.pay_month (
  id bigint generated always as identity primary key,
  branch_id text not null references public.branches(id),
  person_id bigint not null references public.pay_people(id) on delete cascade,
  ym text not null check (ym ~ '^\d{4}-\d{2}$'),
  base bigint, extra bigint not null default 0, memo text,
  updated_by uuid, updated_at timestamptz not null default now(), created_at timestamptz not null default now(),
  unique (person_id, ym)
);
alter table public.pay_people enable row level security;
alter table public.pay_rates enable row level security;
alter table public.pay_month enable row level security;
drop policy if exists pp_all on public.pay_people;
create policy pp_all on public.pay_people for all to authenticated using (my_level() = 1) with check (my_level() = 1);
drop policy if exists pr_all on public.pay_rates;
create policy pr_all on public.pay_rates for all to authenticated using (my_level() = 1) with check (my_level() = 1);
drop policy if exists pm_all on public.pay_month;
create policy pm_all on public.pay_month for all to authenticated using (my_level() = 1) with check (my_level() = 1);
drop trigger if exists pp_touch on public.pay_people;
create trigger pp_touch before insert or update on public.pay_people for each row execute function public.tg_rr();
drop trigger if exists pr_touch on public.pay_rates;
create trigger pr_touch before insert or update on public.pay_rates for each row execute function public.tg_rr();
drop trigger if exists pm_touch on public.pay_month;
create trigger pm_touch before insert or update on public.pay_month for each row execute function public.tg_rr();
