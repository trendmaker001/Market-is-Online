-- Presentation only: separate from products so no pricing/reward triggers run.
create table public.product_image_display (
  product_id uuid primary key references public.products(id) on delete cascade,
  mode text not null default 'zoomed' check (mode in ('fit','zoomed','stretch'))
);
alter table public.product_image_display enable row level security;
revoke all on public.product_image_display from anon, authenticated;
grant select on public.product_image_display to anon, authenticated;
grant insert, update on public.product_image_display to authenticated;
grant all on public.product_image_display to service_role;
create policy "Public product photo display" on public.product_image_display for select to anon, authenticated
using (exists(select 1 from public.products p join public.vendors v on v.id=p.vendor_id
 where p.id=product_id and p.status='approved' and v.status='active'));
create policy "Admin reads photo display" on public.product_image_display for select to authenticated
using ((select public.current_user_is_admin()));
create policy "Admin creates photo display" on public.product_image_display for insert to authenticated
with check ((select public.current_user_is_admin()));
create policy "Admin updates photo display" on public.product_image_display for update to authenticated
using ((select public.current_user_is_admin())) with check ((select public.current_user_is_admin()));
comment on table public.product_image_display is 'Admin-controlled card photo presentation. Missing rows use zoomed; product detail gallery is unchanged.';
