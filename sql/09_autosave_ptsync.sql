-- 9차: 마감일지 자동저장(변경기록 10분 묶음) + 도수·충격파 스케줄 → 마감일지 pt 자동 반영
create or replace function public.tg_daily_close() returns trigger
language plpgsql security definer set search_path = public as
$$
begin
  if tg_op = 'INSERT' then
    new.created_by := auth.uid(); new.updated_by := auth.uid(); new.created_at := now();
  else
    new.created_by := old.created_by; new.created_at := old.created_at; new.updated_by := auth.uid();
  end if;
  new.updated_at := now();
  if tg_op = 'INSERT' or not (old.updated_by is not distinct from auth.uid() and old.updated_at > now() - interval '10 minutes') then
    insert into audit_log(user_id, branch_id, action, target, detail)
    values (auth.uid(), new.branch_id, lower(tg_op), 'daily_close:' || new.close_date, jsonb_build_object('total', new.total));
  end if;
  return new;
end $$;

create or replace function public.sync_pt(b text, d date) returns void
language plpgsql security definer set search_path = public as
$$
declare cnt jsonb; cur jsonb; man jsonb; newpt jsonb;
begin
  if d < date '2026-10-27' then return; end if;   -- 구글시트에서 옮긴 과거 자료는 건드리지 않음
  select coalesce(jsonb_object_agg(item, n), '{}'::jsonb) into cnt
    from (select item, count(*) n from appointments
          where branch_id = b and appt_date = d and kind = 'pt' and status not in ('취소','노쇼') group by item) t;
  select pt into cur from daily_close where branch_id = b and close_date = d;
  if not found then
    if cnt = '{}'::jsonb then return; end if;
    insert into daily_close(branch_id, close_date, pt) values (b, d, cnt);
    return;
  end if;
  cur := coalesce(cur, '{}'::jsonb); man := coalesce(cur->'_m', '[]'::jsonb);
  select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) into newpt from (
    select key k, value v from jsonb_each(cnt) where not (man ? key)
    union all
    select key, value from jsonb_each(cur) where man ? key and key <> '_m') t;
  if jsonb_array_length(man) > 0 then newpt := newpt || jsonb_build_object('_m', man); end if;
  if newpt is distinct from cur then
    update daily_close set pt = newpt where branch_id = b and close_date = d;
  end if;
end $$;
revoke all on function public.sync_pt(text, date) from public, anon, authenticated;

create or replace function public.tg_appt_pt() returns trigger
language plpgsql security definer set search_path = public as
$$
begin
  if tg_op in ('INSERT','UPDATE') and new.kind = 'pt' then perform sync_pt(new.branch_id, new.appt_date); end if;
  if tg_op = 'DELETE' and old.kind = 'pt' then perform sync_pt(old.branch_id, old.appt_date); end if;
  if tg_op = 'UPDATE' and old.kind = 'pt' and (old.appt_date <> new.appt_date or old.branch_id <> new.branch_id or new.kind <> 'pt') then
    perform sync_pt(old.branch_id, old.appt_date); end if;
  return null;
end $$;
drop trigger if exists appt_pt_sync on public.appointments;
create trigger appt_pt_sync after insert or update or delete on public.appointments
  for each row execute function public.tg_appt_pt();
