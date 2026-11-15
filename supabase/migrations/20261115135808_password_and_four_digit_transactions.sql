-- Passwords are verified by Supabase Auth, never passed to or stored in this table.
-- Each fresh password sign-in may issue one short-lived, session-bound PIN proof.
create table private.transaction_authorizations (
 token_hash text primary key,
 member_id uuid not null references auth.users(id) on delete cascade,
 session_id uuid not null,
 verification_session_id uuid not null unique,
 purpose text not null check(purpose in ('transaction','pin_reset')),
 pin_fingerprint text,
 created_at timestamptz not null default now(),
 expires_at timestamptz not null default now()+interval '2 minutes',
 used_xid text
);
alter table private.transaction_authorizations enable row level security;
revoke all on private.transaction_authorizations from public,anon,authenticated;
create index transaction_authorizations_expiry on private.transaction_authorizations(expires_at);

create function private.fresh_password_session() returns uuid
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();sid uuid:=nullif(auth.jwt()->>'session_id','')::uuid;verified boolean;
begin
 if uid is null or sid is null then raise exception 'Sign in required';end if;
 select exists(select 1 from jsonb_array_elements(coalesce(auth.jwt()->'amr','[]'::jsonb)) a
  where a->>'method'='password' and (a->>'timestamp')~'^[0-9]+$'
  and to_timestamp((a->>'timestamp')::double precision) between now()-interval '60 seconds' and now()+interval '30 seconds') into verified;
 if not verified or not exists(select 1 from auth.sessions where id=sid and user_id=uid and created_at>=now()-interval '90 seconds') then
  raise exception 'Enter your account password again to verify this transaction';
 end if;
 return sid;
end $$;
revoke all on function private.fresh_password_session() from public,anon,authenticated;

create function private.authorize_transaction(p_pin text,p_session_id uuid,p_pin_reset boolean default false)
returns text language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();verified_session uuid;stored text;ticket text;
begin
 verified_session:=private.fresh_password_session();
 if p_session_id is null or p_session_id=verified_session or not exists(select 1 from auth.sessions where id=p_session_id and user_id=uid) then
  raise exception 'Account session changed. Please sign in again';
 end if;
 select transaction_pin_hash into stored from public.member_profiles where user_id=uid;
 if not found then raise exception 'Member account required';end if;
 if not coalesce(p_pin_reset,false) then
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then raise exception 'Enter exactly 4 digits for your transaction PIN';end if;
  if stored is null then raise exception 'Set your transaction PIN in Account security first';end if;
  if extensions.crypt(p_pin,stored) is distinct from stored then raise exception 'Incorrect PIN';end if;
 end if;
 delete from private.transaction_authorizations where expires_at<now()-interval '1 day';
 ticket:='txauth_'||encode(extensions.gen_random_bytes(32),'hex');
 insert into private.transaction_authorizations(token_hash,member_id,session_id,verification_session_id,purpose,pin_fingerprint)
 values(encode(extensions.digest(ticket,'sha256'),'hex'),uid,p_session_id,verified_session,
 case when coalesce(p_pin_reset,false) then 'pin_reset' else 'transaction' end,
 encode(extensions.digest(coalesce(stored,''),'sha256'),'hex'));
 return ticket;
exception when unique_violation then raise exception 'Password verification was already used. Please verify again';
end $$;
revoke all on function private.authorize_transaction(text,uuid,boolean) from public,anon;
grant execute on function private.authorize_transaction(text,uuid,boolean) to authenticated;
create function public.authorize_transaction(p_pin text,p_session_id uuid,p_pin_reset boolean default false)
returns text language sql security invoker set search_path='' as $$select private.authorize_transaction(p_pin,p_session_id,p_pin_reset)$$;
revoke all on function public.authorize_transaction(text,uuid,boolean) from public,anon;
grant execute on function public.authorize_transaction(text,uuid,boolean) to authenticated;

create function private.consume_transaction_authorization(p_ticket text,p_member_id uuid,p_allow_reset boolean default false)
returns void language plpgsql security definer set search_path='' as $$
declare proof private.transaction_authorizations%rowtype;stored text;sid uuid:=nullif(auth.jwt()->>'session_id','')::uuid;xid text:=pg_current_xact_id()::text;
begin
 if p_member_id is null or p_member_id is distinct from auth.uid() then raise exception 'Authentication required';end if;
 if p_ticket is null or p_ticket !~ '^txauth_[0-9a-f]{64}$' then raise exception 'Account password and 4-digit PIN verification are required. Refresh the page and try again';end if;
 select * into proof from private.transaction_authorizations where token_hash=encode(extensions.digest(p_ticket,'sha256'),'hex') for update;
 if not found or proof.member_id<>p_member_id or proof.session_id is distinct from sid or proof.expires_at<=now()
  or (proof.used_xid is not null and proof.used_xid<>xid)
  or not exists(select 1 from auth.sessions where id=sid and user_id=p_member_id) then
  raise exception 'Transaction verification expired or was already used. Enter your password and PIN again';
 end if;
 select transaction_pin_hash into stored from public.member_profiles where user_id=p_member_id;
 if proof.pin_fingerprint is distinct from encode(extensions.digest(coalesce(stored,''),'sha256'),'hex') then raise exception 'PIN changed. Please verify again';end if;
 if proof.purpose='pin_reset' then
  if not p_allow_reset then raise exception 'Account password and transaction PIN verification required';end if;
  perform private.require_recent_totp();
 end if;
 update private.transaction_authorizations set used_xid=xid where token_hash=proof.token_hash;
end $$;
revoke all on function private.consume_transaction_authorization(text,uuid,boolean) from public,anon,authenticated;
create or replace function private.require_transaction_pin(p_pin text,p_member_id uuid default auth.uid())
returns void language plpgsql security definer set search_path='' as $$begin
 perform private.consume_transaction_authorization(p_pin,p_member_id,false);
end $$;
revoke all on function private.require_transaction_pin(text,uuid) from public,anon,authenticated;

create or replace function public.set_transaction_pin(p_pin text)
returns void language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();stored text;
begin
 perform private.fresh_password_session();
 if p_pin is null or p_pin !~ '^[0-9]{4}$' then raise exception 'Transaction PIN must contain exactly 4 digits';end if;
 select transaction_pin_hash into stored from public.member_profiles where user_id=uid for update;
 if not found then raise exception 'Member account required';end if;
 if stored is not null then raise exception 'Transaction PIN already exists. Verify your previous PIN or authenticator code to change it';end if;
 update public.member_profiles set transaction_pin_hash=extensions.crypt(p_pin,extensions.gen_salt('bf')),transaction_pin_set_at=now(),transaction_pin_updated_at=now(),updated_at=now() where user_id=uid;
end $$;
create or replace function public.change_transaction_pin(p_new_pin text,p_current_pin text default null)
returns void language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();stored text;
begin
 if uid is null then raise exception 'Authentication required';end if;
 if p_new_pin is null or p_new_pin !~ '^[0-9]{4}$' then raise exception 'New transaction PIN must contain exactly 4 digits';end if;
 perform private.consume_transaction_authorization(p_current_pin,uid,true);
 select transaction_pin_hash into stored from public.member_profiles where user_id=uid for update;
 if stored is null then raise exception 'No transaction PIN exists. Set your PIN first';end if;
 update public.member_profiles set transaction_pin_hash=extensions.crypt(p_new_pin,extensions.gen_salt('bf')),transaction_pin_updated_at=now(),updated_at=now() where user_id=uid;
end $$;
revoke all on function public.set_transaction_pin(text) from public,anon;
revoke all on function public.change_transaction_pin(text,text) from public,anon;
grant execute on function public.set_transaction_pin(text),public.change_transaction_pin(text,text) to authenticated;
