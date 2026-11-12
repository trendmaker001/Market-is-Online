-- User accounts remain separate from network membership until an approved placement.
create table private.shopping_membership_requests (
 id uuid primary key default gen_random_uuid(), customer_id uuid not null references private.customer_identities(user_id),
 source text not null check(source in ('affiliate','direct')), sponsor_id uuid references public.member_profiles(user_id),
 sponsor_member_code text, status text not null check(status in ('pending_admin','pending_sponsor','awaiting_founder','completed','declined')),
 consent_at timestamptz not null, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 admin_reviewed_by uuid references auth.users(id), admin_reviewed_at timestamptz, reviewed_by uuid references auth.users(id), reviewed_at timestamptz,
 placement_side text check(placement_side in ('LEFT','RIGHT')), review_note text not null default '' check(length(review_note)<=500)
);
create unique index shopping_membership_one_active on private.shopping_membership_requests(customer_id) where status in ('pending_admin','pending_sponsor','awaiting_founder');
create index shopping_membership_customer_history on private.shopping_membership_requests(customer_id,created_at desc);
create index shopping_membership_sponsor_queue on private.shopping_membership_requests(sponsor_id,status,created_at desc);
create index shopping_membership_admin_queue on private.shopping_membership_requests(status,created_at desc) where source='direct';
alter table private.shopping_membership_requests enable row level security;
revoke all on private.shopping_membership_requests from public,anon,authenticated;

create table private.shopping_notifications (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id),
 category text not null check(category in ('order','payment','sponsor','membership','announcement')),
 title text not null check(length(title) between 2 and 120), message text not null check(length(message) between 2 and 1000),
 route text not null, entity_id uuid, read_at timestamptz, created_at timestamptz not null default now()
);
create index shopping_notifications_owner on private.shopping_notifications(user_id,created_at desc);
create index shopping_notifications_unread on private.shopping_notifications(user_id) where read_at is null;
alter table private.shopping_notifications enable row level security;
revoke all on private.shopping_notifications from public,anon,authenticated;

create function private.notify_shopper(p_user uuid,p_category text,p_title text,p_message text,p_route text,p_entity uuid default null)
returns void language sql security definer set search_path='' as $$
 insert into private.shopping_notifications(user_id,category,title,message,route,entity_id)
 select p_user,p_category,p_title,p_message,p_route,p_entity where p_user is not null
$$;
revoke all on function private.notify_shopper(uuid,text,text,text,text,uuid) from public,anon,authenticated;

create function private.shopping_membership_status() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c private.customer_identities%rowtype;s public.member_profiles%rowtype;r private.shopping_membership_requests%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 select * into c from private.customer_identities where user_id=auth.uid();
 select m.* into s from public.member_profiles m where m.user_id=c.sponsor_id and m.status in ('active','inactive') and m.terms_accepted_at is not null
 and not exists(select 1 from public.user_roles ur where ur.user_id=m.user_id and ur.role='admin')
 and not exists(select 1 from private.network_foundation nf where nf.company_id=m.user_id);
 select * into r from private.shopping_membership_requests where customer_id=auth.uid() order by created_at desc,id desc limit 1;
 return jsonb_build_object('is_member',exists(select 1 from public.member_profiles where user_id=auth.uid()),'has_sponsor',s.user_id is not null,
 'sponsor_name',s.full_name,'member_referral_code',s.member_code,'request',case when r.id is null then null else to_jsonb(r)-'customer_id'-'admin_reviewed_by'-'reviewed_by' end);
end $$;
create function public.shopping_membership_status() returns jsonb language sql security invoker set search_path='' as $$select private.shopping_membership_status()$$;

create function private.request_shopping_membership(p_consent boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare c private.customer_identities%rowtype;s public.member_profiles%rowtype;r private.shopping_membership_requests%rowtype;a record;
begin
 if auth.uid() is null or p_consent is distinct from true then raise exception 'Sign in and accept the membership terms';end if;
 select * into c from private.customer_identities where user_id=auth.uid() for update;
 if c.user_id is null or c.terms_accepted_at is null then raise exception 'Complete your shopping profile first';end if;
 if exists(select 1 from public.member_profiles where user_id=auth.uid()) then return private.shopping_membership_status();end if;
 if not exists(select 1 from auth.users where id=auth.uid() and email_confirmed_at is not null) then raise exception 'Verify your email first';end if;
 if exists(select 1 from private.shopping_membership_requests where customer_id=auth.uid() and status in ('pending_admin','pending_sponsor','awaiting_founder')) then return private.shopping_membership_status();end if;
 select m.* into s from public.member_profiles m where m.user_id=c.sponsor_id and m.status in ('active','inactive') and m.terms_accepted_at is not null
 and not exists(select 1 from public.user_roles ur where ur.user_id=m.user_id and ur.role='admin')
 and not exists(select 1 from private.network_foundation nf where nf.company_id=m.user_id);
 insert into private.shopping_membership_requests(customer_id,source,sponsor_id,sponsor_member_code,status,consent_at)
 values(auth.uid(),case when s.user_id is null then 'direct' else 'affiliate' end,s.user_id,s.member_code,case when s.user_id is null then 'pending_admin' else 'pending_sponsor' end,now()) returning * into r;
 perform private.notify_shopper(auth.uid(),'membership','Membership request received',case when s.user_id is null then 'Your request is awaiting admin review.' else 'Your request has been sent to your linked sponsor for review and placement.' end,'account/earn',r.id);
 if s.user_id is not null then
  perform private.notify_member(s.user_id,'shopping','User to Member request',c.full_name||' wants to join your member network. Review the request in My Network.','shopping_membership',r.id,jsonb_build_object('route','network'));
 else
  for a in select ur.user_id from public.user_roles ur join public.member_profiles m on m.user_id=ur.user_id where ur.role='admin' loop
   perform private.notify_member(a.user_id,'shopping','User to Member request','A direct shopper has requested membership. Review in Network Controls.','shopping_membership',r.id,jsonb_build_object('route','workspace/user-membership'));
  end loop;
 end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'SHOPPING_MEMBERSHIP_REQUESTED','shopping_membership',r.id,jsonb_build_object('source',r.source,'status',r.status));
 return private.shopping_membership_status();
end $$;
create function public.request_shopping_membership(p_consent boolean) returns jsonb language sql security invoker set search_path='' as $$select private.request_shopping_membership(p_consent)$$;

create function private.review_shopping_membership(p_request uuid,p_approve boolean,p_side text,p_note text) returns jsonb language plpgsql security definer set search_path='' as $$
declare r private.shopping_membership_requests%rowtype;c private.customer_identities%rowtype;s public.member_profiles%rowtype;code text;
begin
 if auth.uid() is null or p_approve is null then raise exception 'Sign in and choose a decision';end if;
 if length(coalesce(p_note,''))>500 then raise exception 'Keep the review note within 500 characters';end if;
 select * into r from private.shopping_membership_requests where id=p_request for update;
 if r.id is null then raise exception 'Request not found';end if;
 -- Check ownership before exposing any terminal state or accepting retries.
 if r.status='pending_admin' then
  if not private.has_role('admin') then raise exception 'Admin access required';end if;
 elsif r.sponsor_id is distinct from auth.uid() then
  if r.source='direct' and r.admin_reviewed_by=auth.uid() and private.has_role('admin') then return jsonb_build_object('status',r.status,'already_reviewed',true);end if;
  raise exception 'Only the assigned sponsor can review this request';
 end if;
 if r.status in ('completed','declined') then return jsonb_build_object('status',r.status,'already_reviewed',true);end if;
 select * into c from private.customer_identities where user_id=r.customer_id for update;
 if not p_approve then
  if length(trim(coalesce(p_note,'')))<3 then raise exception 'Add a short reason for declining';end if;
  update private.shopping_membership_requests set status='declined',admin_reviewed_by=case when r.status='pending_admin' then auth.uid() else admin_reviewed_by end,admin_reviewed_at=case when r.status='pending_admin' then now() else admin_reviewed_at end,reviewed_by=auth.uid(),reviewed_at=now(),review_note=trim(p_note),updated_at=now() where id=r.id;
  perform private.notify_shopper(c.user_id,'membership','Membership request declined',trim(p_note),'account/earn',r.id);
 elsif r.status='pending_admin' then
  select m.* into s from private.network_foundation nf join public.member_profiles m on m.user_id=nf.founder_id where nf.singleton and nf.founder_id<>nf.company_id and m.status in ('active','inactive') and m.terms_accepted_at is not null;
  if s.user_id is null or exists(select 1 from public.user_roles where user_id=s.user_id and role='admin') or not exists(select 1 from public.binary_placements where member_id=s.user_id) then raise exception 'Founder account is not ready for placement';end if;
  update private.shopping_membership_requests set sponsor_id=s.user_id,sponsor_member_code=s.member_code,status='awaiting_founder',admin_reviewed_by=auth.uid(),admin_reviewed_at=now(),review_note=trim(coalesce(p_note,'')),updated_at=now() where id=r.id;
  update private.customer_identities set sponsor_id=s.user_id where user_id=c.user_id;
  perform private.notify_shopper(c.user_id,'membership','Admin approved your request','Your request has been sent to the Founder for Left or Right placement. Membership starts after placement.','account/earn',r.id);
  perform private.notify_member(s.user_id,'shopping','User ready for Founder placement',c.full_name||' has admin approval. Review and choose Left or Right in My Network.','shopping_membership',r.id,jsonb_build_object('route','network'));
 else
  if p_side is null or p_side not in ('LEFT','RIGHT') then raise exception 'Choose Left or Right before confirming membership';end if;
  select * into s from public.member_profiles where user_id=r.sponsor_id and status in ('active','inactive') and terms_accepted_at is not null;
  if s.user_id is null or exists(select 1 from public.user_roles where user_id=s.user_id and role='admin') then raise exception 'Sponsor is not eligible for placement';end if;
  if not exists(select 1 from auth.users where id=c.user_id and email_confirmed_at is not null) then raise exception 'Customer must verify their email first';end if;
  if exists(select 1 from public.member_profiles where user_id=c.user_id) then raise exception 'Customer already has a membership; review their existing placement';end if;
  code:=upper(substr(replace(c.user_id::text,'-',''),1,10));
  insert into public.member_profiles(user_id,member_code,referral_code,full_name,phone,country_code,sponsor_id,status,terms_accepted_at,terms_version)
  values(c.user_id,'MIO-'||code,code,c.full_name,c.phone,c.country_code,s.user_id,'inactive',r.consent_at,'phase1-terms-v1');
  insert into public.user_roles(user_id,role) values(c.user_id,'member') on conflict do nothing;
  perform private.place_outermost(c.user_id,s.user_id,p_side);
  update private.customer_identities set sponsor_id=s.user_id where user_id=c.user_id;
  update private.shopping_membership_requests set status='completed',placement_side=p_side,reviewed_by=auth.uid(),reviewed_at=now(),review_note=trim(coalesce(p_note,'')),updated_at=now() where id=r.id;
  perform private.notify_shopper(c.user_id,'membership','Your membership is ready','Your sponsor has placed you on the '||lower(p_side)||' leg. Open your Member Dashboard. Your shopping history is preserved.','dashboard',r.id);
  perform private.notify_member(c.user_id,'shopping','Welcome to your member network','Your membership is ready. Package activation and earning qualifications are separate.','shopping_membership',r.id,jsonb_build_object('route','network'));
 end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'SHOPPING_MEMBERSHIP_REVIEWED','shopping_membership',r.id,jsonb_build_object('approved',p_approve,'side',p_side,'previous_status',r.status));
 return (select jsonb_build_object('status',status,'placement_side',placement_side) from private.shopping_membership_requests where id=r.id);
end $$;
create function public.review_shopping_membership(p_request uuid,p_approve boolean,p_side text default null,p_note text default '') returns jsonb language sql security invoker set search_path='' as $$select private.review_shopping_membership(p_request,p_approve,p_side,p_note)$$;

create function private.shopping_membership_queue(p_admin boolean,p_status text,p_search text,p_offset integer) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 if p_admin is null or (p_admin and not private.has_role('admin')) then raise exception 'Admin access required';end if;
 if not p_admin and not exists(select 1 from public.member_profiles where user_id=auth.uid()) then raise exception 'Member access required';end if;
 with scoped as (select r.*,c.full_name,c.phone,u.email from private.shopping_membership_requests r join private.customer_identities c on c.user_id=r.customer_id join auth.users u on u.id=c.user_id
 where (p_admin and r.source='direct') or (not p_admin and r.sponsor_id=auth.uid())),
 filtered as (select * from scoped where (p_status='all' or (p_status='pending' and status in('pending_admin','pending_sponsor','awaiting_founder')) or status=p_status)
 and (coalesce(p_search,'')='' or full_name ilike '%'||left(p_search,100)||'%' or email ilike '%'||left(p_search,100)||'%')),
 paged as (select * from filtered order by created_at desc,id desc limit 50 offset greatest(coalesce(p_offset,0),0))
 select jsonb_build_object('total',(select count(*) from filtered),'pending',(select count(*) from scoped where status in('pending_admin','pending_sponsor','awaiting_founder')),'rows',coalesce((select jsonb_agg(to_jsonb(paged) order by created_at desc,id desc) from paged),'[]')) into result;
 return result;
end $$;
create function public.shopping_membership_queue(p_admin boolean default false,p_status text default 'pending',p_search text default '',p_offset integer default 0) returns jsonb language sql security invoker set search_path='' as $$select private.shopping_membership_queue(p_admin,p_status,p_search,p_offset)$$;

create function private.shopping_messages(p_offset integer,p_unread boolean) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 return jsonb_build_object('unread',(select count(*) from private.shopping_notifications where user_id=auth.uid() and read_at is null),
 'total',(select count(*) from private.shopping_notifications where user_id=auth.uid() and (not coalesce(p_unread,false) or read_at is null)),
 'rows',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,id desc) from (select id,category,title,message,route,entity_id,read_at,created_at from private.shopping_notifications where user_id=auth.uid() and (not coalesce(p_unread,false) or read_at is null) order by created_at desc,id desc limit 50 offset greatest(coalesce(p_offset,0),0)) x),'[]'));
end $$;
create function public.shopping_messages(p_offset integer default 0,p_unread boolean default false) returns jsonb language sql security invoker set search_path='' as $$select private.shopping_messages(p_offset,p_unread)$$;
create function private.read_shopping_messages(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 update private.shopping_notifications set read_at=now() where user_id=auth.uid() and read_at is null and (p_id is null or id=p_id);
end $$;
create function public.read_shopping_messages(p_id uuid default null) returns void language sql security invoker set search_path='' as $$select private.read_shopping_messages(p_id)$$;

-- Eliminate the old unapproved upgrade endpoint and anonymous order creation.
create or replace function public.join_network_from_shopping(p_referral_code text,p_consent boolean) returns void language plpgsql set search_path='' as $$begin raise exception 'Use Earn with us to request sponsor or admin approval';end$$;
revoke all on function public.join_network_from_shopping(text,boolean) from public,anon,authenticated;
revoke all on function public.place_guest_affiliate_order(jsonb,text,text,text,text,text,text,text,text) from public,anon,authenticated;
revoke all on function public.place_configured_bundle_order(uuid,uuid,jsonb,text,jsonb) from public,anon;
grant execute on function public.place_configured_bundle_order(uuid,uuid,jsonb,text,jsonb) to authenticated;
-- Existing guest receipts remain readable by their secret receipt token.

create function private.shopping_order_notification() returns trigger language plpgsql security definer set search_path='' as $$
declare c uuid;entity uuid;ordercode text;route text;title text;body text;
begin
 if tg_table_name='customer_order_funding' then
  if tg_op='UPDATE' and new.status is not distinct from old.status then return new;end if;
  c:=new.customer_id;entity:=new.order_id;select order_code into ordercode from public.orders where id=new.order_id;
  route:=case when new.method='ADVANCE' then 'account/prepayments/'||new.order_id else 'account/orders/'||new.order_id end;
  if tg_op='INSERT' then title:='Order saved';body:='Order '||ordercode||case when new.method='ADVANCE' then ' is saved. Complete its advance payment to continue.' else ' is awaiting sponsor hold approval.' end;
  else title:='Payment '||replace(new.status,'_',' ');body:='Order '||ordercode||': your advance payment is '||replace(new.status,'_',' ')||'.'||case when nullif(new.review_note,'') is not null then ' '||left(new.review_note,500) else '' end;end if;
 elsif tg_table_name='orders' then
  if new.status is not distinct from old.status then return new;end if;
  select customer_id into c from private.customer_order_funding where order_id=new.id;
  entity:=new.id;route:='account/orders/'||new.id;title:='Order '||replace(new.status::text,'_',' ');body:='Order '||new.order_code||' is now '||replace(new.status::text,'_',' ')||'.';
 else
  if new.status is not distinct from old.status then return new;end if;
  select f.customer_id,o.order_code into c,ordercode from private.customer_order_funding f join public.orders o on o.id=f.order_id where f.order_id=new.order_id and f.method='SPONSOR';
  entity:=new.order_id;route:='account/orders/'||new.order_id;title:='Sponsor hold updated';body:='Order '||ordercode||': sponsor security is '||replace(new.status,'_',' ')||'.';
 end if;
 if c is not null then perform private.notify_shopper(c,case tg_table_name when 'orders' then 'order' when 'customer_order_funding' then 'payment' else 'sponsor' end,title,body,route,entity);end if;
 return new;
end $$;
revoke all on function private.shopping_order_notification() from public,anon,authenticated;
create trigger shopping_funding_messages after insert or update of status on private.customer_order_funding for each row execute function private.shopping_order_notification();
create trigger shopping_order_messages after update of status on public.orders for each row execute function private.shopping_order_notification();
create trigger shopping_hold_messages after update of status on public.affiliate_guest_order_approvals for each row execute function private.shopping_order_notification();

-- Persist delivery details supplied at initial checkout without storing the password.
create function private.save_initial_shopping_address() returns trigger language plpgsql security definer set search_path='' as $$
begin
 update private.customer_identities set shipping_address=left(coalesce(new.raw_user_meta_data->>'shipping_address',''),500),shipping_city=left(coalesce(new.raw_user_meta_data->>'shipping_city',''),100) where user_id=new.id;
 return new;
end $$;
revoke all on function private.save_initial_shopping_address() from public,anon,authenticated;
create trigger zzz_shopping_initial_address after insert on auth.users for each row execute function private.save_initial_shopping_address();

-- Every callable private implementation enforces its own authenticated ownership check.
revoke all on function private.shopping_membership_status(),private.request_shopping_membership(boolean),private.review_shopping_membership(uuid,boolean,text,text),private.shopping_membership_queue(boolean,text,text,integer),private.shopping_messages(integer,boolean),private.read_shopping_messages(uuid) from public,anon,authenticated;
grant execute on function private.shopping_membership_status(),private.request_shopping_membership(boolean),private.review_shopping_membership(uuid,boolean,text,text),private.shopping_membership_queue(boolean,text,text,integer),private.shopping_messages(integer,boolean),private.read_shopping_messages(uuid) to authenticated;
revoke all on function public.shopping_membership_status(),public.request_shopping_membership(boolean),public.review_shopping_membership(uuid,boolean,text,text),public.shopping_membership_queue(boolean,text,text,integer),public.shopping_messages(integer,boolean),public.read_shopping_messages(uuid) from public,anon,authenticated;
grant execute on function public.shopping_membership_status(),public.request_shopping_membership(boolean),public.review_shopping_membership(uuid,boolean,text,text),public.shopping_membership_queue(boolean,text,text,integer),public.shopping_messages(integer,boolean),public.read_shopping_messages(uuid) to authenticated;
notify pgrst,'reload schema';

create function private.shopping_order_details(p_order uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 return coalesce((select jsonb_agg(x.data order by x.created_at desc) from (
 select o.created_at,jsonb_build_object('id',o.id,'order_code',o.order_code,'status',o.status,'payment_status',o.payment_status,'total_pkr',o.total_pkr,'cod_due_pkr',o.cod_due_pkr,'created_at',o.created_at,
 'shipping_name',o.shipping_name,'shipping_city',o.shipping_city,'shipping_address',o.shipping_address,
 'funding',to_jsonb(f)-'customer_id'-'transaction_key'-'reviewer_id',
 'sponsor_status',a.status,'items',(select coalesce(jsonb_agg(jsonb_build_object('name',i.product_name_snapshot,'quantity',i.quantity,'unit_price',i.unit_price_pkr)),'[]') from public.order_items i where i.order_id=o.id)) as data
 from private.customer_order_funding f join public.orders o on o.id=f.order_id left join public.affiliate_guest_order_approvals a on a.order_id=o.id
 where f.customer_id=auth.uid() and o.id=p_order order by o.created_at desc limit 1) x),'[]')->0;
end $$;


create function public.shopping_order_details(p_order uuid) returns jsonb language sql security invoker set search_path='' as $$select private.shopping_order_details(p_order)$$;
revoke all on function private.shopping_order_details(uuid),public.shopping_order_details(uuid) from public,anon,authenticated;
grant execute on function private.shopping_order_details(uuid),public.shopping_order_details(uuid) to authenticated;
notify pgrst,'reload schema';
