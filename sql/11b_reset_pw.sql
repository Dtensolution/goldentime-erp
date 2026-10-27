-- 11b: 비밀번호 재설정 시 '초기 비밀번호' 상태로 표시
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
  update profiles set pw_changed_at = null where user_id = p_user;
  insert into audit_log(user_id, branch_id, action, target) values (auth.uid(), t.branch_id, 'reset_password', t.login_id);
end $$;
