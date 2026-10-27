create table if not exists public.inv_items (
  id bigint generated always as identity primary key,
  branch_id text not null references public.branches(id),
  dept text not null, category text, vendor text, code text, name text not null, spec text, unit text,
  price int, std_qty numeric, memo text, sort int not null default 0, active boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists inv_items_b on public.inv_items(branch_id, dept);
create table if not exists public.inv_logs (
  id bigint generated always as identity primary key,
  item_id bigint not null references public.inv_items(id) on delete cascade,
  branch_id text not null, log_date date not null,
  kind text not null default '재고',  -- 재고(조사 수량), 발주, 입고, 사용
  qty numeric not null, note text, created_by uuid, created_at timestamptz not null default now()
);
create index if not exists inv_logs_i on public.inv_logs(item_id, log_date);
create unique index if not exists inv_logs_u on public.inv_logs(item_id, log_date, kind);
create or replace function public.can_edit_inv(p_dept text) returns boolean
language sql stable security definer set search_path = public as
$$ select coalesce((select p.active and (p.level <= 2 or p.dept = p_dept or (p.level = 3 and p_dept in ('간호','병동','수술') and p.dept in ('간호','병동','수술'))) from profiles p where p.user_id = auth.uid()), false) $$;
alter table public.inv_items enable row level security;
alter table public.inv_logs enable row level security;
drop policy if exists ii_sel on public.inv_items;
create policy ii_sel on public.inv_items for select to authenticated using (my_level() = 1 or branch_id = my_branch());
drop policy if exists ii_all on public.inv_items;
create policy ii_all on public.inv_items for all to authenticated using ((my_level() = 1 or branch_id = my_branch()) and can_edit_inv(dept)) with check ((my_level() = 1 or branch_id = my_branch()) and can_edit_inv(dept));
drop policy if exists il_sel on public.inv_logs;
create policy il_sel on public.inv_logs for select to authenticated using (my_level() = 1 or branch_id = my_branch());
drop policy if exists il_all on public.inv_logs;
create policy il_all on public.inv_logs for all to authenticated
  using ((my_level() = 1 or branch_id = my_branch()) and can_edit_inv((select i.dept from inv_items i where i.id = item_id)))
  with check ((my_level() = 1 or branch_id = my_branch()) and can_edit_inv((select i.dept from inv_items i where i.id = item_id)));
create or replace function public.tg_inv() returns trigger language plpgsql security definer set search_path = public as
$$ begin new.created_by := coalesce(new.created_by, auth.uid()); return new; end $$;
drop trigger if exists inv_touch on public.inv_logs;
create trigger inv_touch before insert on public.inv_logs for each row execute function public.tg_inv();

create or replace function public.import_inv(p_token text, p_items jsonb) returns int
language plpgsql security definer set search_path = public as
$$ declare it jsonb; lg jsonb; iid bigint; n int := 0;
begin
  if p_token <> '(삭제됨-일회용 이관 토큰, 함수도 삭제됨)' then raise exception 'bad token'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    insert into inv_items(branch_id, dept, category, vendor, code, name, spec, unit, price, std_qty, sort)
    values ('gt-os', it->>'dept', nullif(it->>'cat',''), nullif(it->>'vendor',''), nullif(it->>'code',''), it->>'name', nullif(it->>'spec',''), nullif(it->>'unit',''),
            nullif(it->>'price','')::int, nullif(it->>'std','')::numeric, coalesce((it->>'sort')::int,0)) returning id into iid;
    for lg in select * from jsonb_array_elements(coalesce(it->'logs','[]'::jsonb)) loop
      insert into inv_logs(item_id, branch_id, log_date, kind, qty) values (iid, 'gt-os', (lg->>'d')::date, lg->>'k', (lg->>'q')::numeric)
      on conflict (item_id, log_date, kind) do update set qty = excluded.qty;
    end loop;
    n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.import_inv(text, jsonb) to anon;
