-- Brand onboarding is separate from member registration and never grants seller access.
alter table private.vendor_identities add column if not exists brand_name_hint text;
alter table public.vendor_applications add column if not exists logo_path text;
alter table public.vendor_applications add column if not exists logo_url text;
alter table public.vendors add column if not exists brand_name_changes integer not null default 0 check (brand_name_changes >= 0);

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('vendor-brand-logos','vendor-brand-logos',true,2097152,array['image/png','image/jpeg','image/webp'])
on conflict(id) do update set file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create or replace function public.can_upload_vendor_logo() returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and (exists(select 1 from private.vendor_identities where user_id=auth.uid()) or exists(select 1 from public.vendors where owner_user_id=auth.uid()));
$$;
revoke all on function public.can_upload_vendor_logo() from public,anon;
grant execute on function public.can_upload_vendor_logo() to authenticated;
create policy "Vendor uploads own brand logo" on storage.objects for insert to authenticated with check(bucket_id='vendor-brand-logos' and (storage.foldername(name))[1]=(select auth.uid())::text and (select public.can_upload_vendor_logo()));

create function private.vendor_logo_url(p_path text,p_owner uuid) returns text language plpgsql stable security definer set search_path='' as $$
begin
 if p_path is null or split_part(p_path,'/',1)<>p_owner::text or not exists(select 1 from storage.objects where bucket_id='vendor-brand-logos' and name=p_path) then raise exception 'Upload your brand logo before continuing'; end if;
 return 'https://vdkhqqhonpnsqugoadke.supabase.co/storage/v1/object/public/vendor-brand-logos/'||p_path;
end;$$;
revoke all on function private.vendor_logo_url(text,uuid) from public,anon,authenticated;

create function private.register_vendor_brand() returns trigger language plpgsql security definer set search_path='' as $$
declare m jsonb:=new.raw_user_meta_data; n text; r numeric; i private.vendor_identities;
begin
 if m->>'registration_type'<>'vendor' or m->>'registration_type' is null then return new; end if;
 n:=trim(m->>'brand_name');
 if n is null or length(n) not between 2 and 150 or coalesce(m->>'brand_logo_selected','')<>'true' then raise exception 'Brand name and logo are required'; end if;
 r:=(m->>'brand_commission')::numeric;
 if r is null or r<.05 or r>1 then raise exception 'Proposed commission must be between 5 and 100 percent'; end if;
 if length(coalesce(trim(m->>'brand_categories'),''))<2 then raise exception 'Product category is required'; end if;
 select * into strict i from private.vendor_identities where user_id=new.id;
 insert into public.vendor_applications(applicant_user_id,business_name,contact_email,contact_phone,categories,description,status,proposed_commission,agreed_commission,agreement_accepted_at,introduced_by,country_code)
 values(new.id,n,new.email,i.phone,trim(m->>'brand_categories'),'','pending',round(r,6),round(r,6),now(),i.introduced_by,i.country_code);
 return new;
end;$$;
revoke all on function private.register_vendor_brand() from public,anon,authenticated;
create trigger zzzz_vendor_brand_application after insert on auth.users for each row execute function private.register_vendor_brand();

create function public.attach_vendor_application_logo(p_application uuid,p_path text) returns void language plpgsql security definer set search_path='' as $$
declare a public.vendor_applications; u text;
begin
 select * into a from public.vendor_applications where id=p_application and applicant_user_id=auth.uid() for update;
 if not found or a.status<>'pending' then raise exception 'Pending application required'; end if;
 u:=private.vendor_logo_url(p_path,auth.uid());
 update public.vendor_applications set logo_path=p_path,logo_url=u where id=a.id;
end;$$;

create function public.submit_vendor_brand_application(p_business text,p_categories text,p_rate numeric,p_logo_path text) returns uuid language plpgsql security definer set search_path='' as $$
declare i private.vendor_identities; a uuid; e text; u text;
begin
 select * into i from private.vendor_identities where user_id=auth.uid() for update;
 if not found then raise exception 'Vendor registration required'; end if;
 if exists(select 1 from public.vendor_applications where applicant_user_id=auth.uid() and status in ('pending','active')) or exists(select 1 from public.vendors where owner_user_id=auth.uid()) then raise exception 'You already have a store or application'; end if;
 select email into e from auth.users where id=auth.uid() and email_confirmed_at is not null;
 if e is null then raise exception 'Verify your email first'; end if;
 u:=private.vendor_logo_url(p_logo_path,auth.uid());
 a:=public.submit_vendor_application_country(i.country_code,p_business,e,i.phone,p_categories,'',p_rate,null);
 update public.vendor_applications set logo_path=p_logo_path,logo_url=u,agreed_commission=round(p_rate,6),agreement_accepted_at=now() where id=a;
 return a;
end;$$;

-- Approval must have a real uploaded logo; a metadata flag is never sufficient.
create function private.approve_vendor_brand() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='active' and old.status is distinct from new.status then
  new.logo_url:=private.vendor_logo_url(new.logo_path,new.applicant_user_id);
  update public.vendors set logo_url=new.logo_url,country_code=new.country_code where owner_user_id=new.applicant_user_id and business_name=new.business_name and status='active' and not is_company_owned;
 end if;
 return new;
end;$$;
revoke all on function private.approve_vendor_brand() from public,anon,authenticated;
create trigger require_vendor_brand_logo before update of status on public.vendor_applications for each row execute function private.approve_vendor_brand();

create table private.vendor_brand_requests(
 id uuid primary key default gen_random_uuid(),vendor_id uuid not null references public.vendors(id),requester_id uuid not null references auth.users(id),
 business_name text not null check(length(business_name) between 2 and 150),logo_path text,logo_url text,commission_rate numeric not null check(commission_rate between .05 and 1),
 original jsonb not null,status text not null default 'pending' check(status in('pending','approved','rejected')),review_note text,reviewed_by uuid references auth.users(id),reviewed_at timestamptz,created_at timestamptz not null default now()
);
alter table private.vendor_brand_requests enable row level security;
revoke all on private.vendor_brand_requests from public,anon,authenticated;
create unique index vendor_brand_one_pending on private.vendor_brand_requests(vendor_id) where status='pending';
create index vendor_brand_request_history on private.vendor_brand_requests(vendor_id,created_at desc);
create index vendor_brand_request_owner on private.vendor_brand_requests(requester_id);
create index vendor_brand_request_reviewer on private.vendor_brand_requests(reviewed_by);

create function public.my_vendor_brand_state(p_vendor uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v public.vendors; a public.vendor_applications; i private.vendor_identities; r private.vendor_brand_requests;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 select * into i from private.vendor_identities where user_id=auth.uid();
 select * into a from public.vendor_applications where applicant_user_id=auth.uid() order by created_at desc limit 1;
 select * into v from public.vendors where owner_user_id=auth.uid() and (p_vendor is null or id=p_vendor) order by created_at desc limit 1;
 if v.id is not null then select * into r from private.vendor_brand_requests where vendor_id=v.id order by created_at desc limit 1; end if;
 return jsonb_build_object('application',case when a.id is not null then to_jsonb(a) end,'store',case when v.id is not null then to_jsonb(v) end,'request',case when r.id is not null then to_jsonb(r)-'original' end,'brand_name_hint',i.brand_name_hint);
end;$$;

create function public.request_vendor_brand_change(p_vendor uuid,p_business text,p_rate numeric,p_logo_path text default null) returns uuid language plpgsql security definer set search_path='' as $$
declare v public.vendors; n text:=trim(p_business); u text; r uuid;
begin
 select * into v from public.vendors where id=p_vendor and owner_user_id=auth.uid() and status='active' for update;
 if not found then raise exception 'Approved store owner required'; end if;
 if n is null or length(n) not between 2 and 150 or p_rate is null or p_rate not between .05 and 1 then raise exception 'Brand name and commission (5–100 percent) are required'; end if;
 if n<>v.business_name and v.brand_name_changes>=1 then raise exception 'Your one approved brand name change has already been used'; end if;
 u:=case when p_logo_path is null then v.logo_url else private.vendor_logo_url(p_logo_path,auth.uid()) end;
 if n=v.business_name and round(p_rate,6)=v.commission_rate and u is not distinct from v.logo_url then raise exception 'No changes to submit'; end if;
 if exists(select 1 from private.vendor_brand_requests where vendor_id=v.id and status='pending') then raise exception 'A change request is already awaiting review'; end if;
 insert into private.vendor_brand_requests(vendor_id,requester_id,business_name,logo_path,logo_url,commission_rate,original)
 values(v.id,auth.uid(),n,p_logo_path,u,round(p_rate,6),jsonb_build_object('name',v.business_name,'logo',v.logo_url,'rate',v.commission_rate)) returning id into r;
 return r;
end;$$;

create function public.admin_vendor_brand_requests() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not exists(select 1 from public.user_roles where user_id=auth.uid() and role='admin') then raise exception 'Workspace administrator required'; end if;
 return coalesce((select jsonb_agg(to_jsonb(r)||jsonb_build_object('current_name',v.business_name) order by r.created_at) from private.vendor_brand_requests r join public.vendors v on v.id=r.vendor_id where r.status='pending'),'[]');
end;$$;

create function public.review_vendor_brand_request(p_request uuid,p_approve boolean,p_note text default '') returns void language plpgsql security definer set search_path='' as $$
declare r private.vendor_brand_requests; v public.vendors; vid uuid;
begin
 if not exists(select 1 from public.user_roles where user_id=auth.uid() and role='admin') then raise exception 'Workspace administrator required'; end if;
 perform private.require_recent_totp();
 select vendor_id into vid from private.vendor_brand_requests where id=p_request;
 select * into v from public.vendors where id=vid for update;
 select * into r from private.vendor_brand_requests where id=p_request for update;
 if r.id is null or r.status<>'pending' then raise exception 'Pending change request required'; end if;
 if p_approve then
  if v.status<>'active' or v.owner_user_id<>r.requester_id then raise exception 'Store owner or access changed; reject this request'; end if;
  if r.original<>jsonb_build_object('name',v.business_name,'logo',v.logo_url,'rate',v.commission_rate) then raise exception 'Store details changed since this request; reject and request a fresh submission'; end if;
  if r.business_name<>v.business_name and v.brand_name_changes>=1 then raise exception 'Brand name change already used'; end if;
  if r.logo_path is not null then perform private.vendor_logo_url(r.logo_path,r.requester_id); end if;
  if r.commission_rate<>v.commission_rate then perform public.set_vendor_commission(v.id,r.commission_rate); end if;
  update public.vendors set business_name=r.business_name,logo_url=r.logo_url,brand_name_changes=brand_name_changes+case when r.business_name<>v.business_name then 1 else 0 end where id=v.id;
 end if;
 update private.vendor_brand_requests set status=case when p_approve then 'approved' else 'rejected' end,review_note=left(trim(p_note),1000),reviewed_by=auth.uid(),reviewed_at=now() where id=r.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'VENDOR_BRAND_REQUEST_REVIEWED','vendor',v.id,jsonb_build_object('request',r.id,'approved',p_approve,'before',r.original,'name',r.business_name,'rate',r.commission_rate));
end;$$;

revoke all on function public.attach_vendor_application_logo(uuid,text),public.submit_vendor_brand_application(text,text,numeric,text),public.my_vendor_brand_state(uuid),public.request_vendor_brand_change(uuid,text,numeric,text),public.admin_vendor_brand_requests(),public.review_vendor_brand_request(uuid,boolean,text) from public,anon;
grant execute on function public.attach_vendor_application_logo(uuid,text),public.submit_vendor_brand_application(text,text,numeric,text),public.my_vendor_brand_state(uuid),public.request_vendor_brand_change(uuid,text,numeric,text),public.admin_vendor_brand_requests(),public.review_vendor_brand_request(uuid,boolean,text) to authenticated;
