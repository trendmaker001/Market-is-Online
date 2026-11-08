-- Lifetime BP edits preserve the independently entered carry-forward figure.
do $patch$ declare body text;old_fragment text:='for v in select * from jsonb_each(p_values) where key in(''carry_left'',''carry_right'') loop';new_fragment text:='for v in select * from jsonb_each(before_state||p_values) where key in(''carry_left'',''carry_right'') and (p_values ? key or p_values ? replace(key,''carry_'',''bp_'')) loop';begin
 select pg_get_functiondef('private.admin_save_member_state(uuid,text,jsonb,jsonb,uuid,text)'::regprocedure) into body;
 if strpos(body,new_fragment)>0 then return;end if;
 if strpos(body,old_fragment)=0 then raise exception 'Unexpected member points implementation';end if;
 execute replace(body,old_fragment,new_fragment);
end $patch$;
