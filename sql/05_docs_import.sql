-- 5차: 게시판 분류 추가(청구·회의록) + 업무시트 일회성 이관
create or replace function public.can_edit_doc(p_dept text) returns boolean
language sql stable security definer set search_path = public as
$$ select coalesce((select p.active and (p.level <= 2 or p.dept = p_dept or (p_dept in ('공통','회의록','청구') and p.level <= 3))
   from profiles p where p.user_id = auth.uid()), false) $$;

create or replace function public.import_docs(p_token text, p_rows jsonb) returns int
language plpgsql security definer set search_path = public as
$$ declare r jsonb; n int := 0;
begin
  if p_token <> '(삭제됨-일회용 이관 토큰, 함수도 삭제됨)' then raise exception 'bad token'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    if not exists (select 1 from dept_docs where branch_id='gt-os' and dept=r->>'dept' and title=r->>'title') then
      insert into dept_docs(branch_id, dept, title, body, pinned, sort)
      values ('gt-os', r->>'dept', r->>'title', r->>'body', coalesce((r->>'pinned')::boolean,false), coalesce((r->>'sort')::int,0));
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
grant execute on function public.import_docs(text, jsonb) to anon;
