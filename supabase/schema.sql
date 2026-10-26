-- =====================================================================
-- Chaabi.com database (Supabase / Postgres)
-- Run this whole file once in Supabase > SQL Editor > New query > Run.
-- Safe to re-run: it drops and recreates policies and triggers.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- PROFILES (one row per verified user) ----------
create table if not exists public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  full_name     text not null default '' check (char_length(full_name) <= 80),
  phone         text check (phone is null or phone ~ '^03[0-9]{2}-?[0-9]{7}$'),
  role          text not null default 'buyer' check (role in ('buyer','owner','dealer','agency')),
  city          text check (city is null or char_length(city) <= 40),
  cnic_verified boolean not null default false,   -- set by admin only
  is_admin      boolean not null default false,   -- set by you in SQL only
  created_at    timestamptz not null default now()
);

-- Create the profile automatically when someone signs up.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare r text := coalesce(new.raw_user_meta_data->>'role', 'buyer');
        p text := nullif(new.raw_user_meta_data->>'phone', '');
begin
  if r not in ('buyer','owner','dealer','agency') then r := 'buyer'; end if;
  if p is not null and p !~ '^03[0-9]{2}-?[0-9]{7}$' then p := null; end if;
  insert into public.profiles (id, full_name, phone, role, city)
  values (new.id,
          left(coalesce(new.raw_user_meta_data->>'full_name', ''), 80),
          p, r,
          left(nullif(new.raw_user_meta_data->>'city', ''), 40))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;

-- ---------- LISTINGS ----------
create table if not exists public.listings (
  id                 uuid primary key default gen_random_uuid(),
  owner_id           uuid not null references public.profiles (id) on delete cascade,
  mode               text not null check (mode in ('rent','sale')),
  type               text not null check (type in ('house','flat','portion','room','plot','shop','khokha','office','commercial','farmhouse')),
  city               text not null check (char_length(city) <= 40),
  area               text not null check (char_length(area) between 2 and 80),
  society_name       text check (society_name is null or char_length(society_name) <= 80),
  title              text not null check (char_length(title) between 5 and 120),
  description        text not null default '' check (char_length(description) <= 3000),
  price              bigint not null check (price > 0),
  advance_months     numeric(4,1) not null default 0 check (advance_months between 0 and 24),
  security_months    numeric(4,1) not null default 0 check (security_months between 0 and 24),
  commission_months  numeric(4,1) not null default 0 check (commission_months between 0 and 12),
  size_value         numeric check (size_value is null or size_value > 0),
  size_unit          text check (size_unit is null or size_unit in ('marla','kanal','sqft','sqyd')),
  beds               int check (beds is null or beds between 0 and 50),
  baths              int check (baths is null or baths between 0 and 50),
  verification_level int not null default 0 check (verification_level between 0 and 3),
  status             text not null default 'pending' check (status in ('pending','active','rejected','sold','rented','archived')),
  cover_path         text,
  featured_until     timestamptz,
  verified_deal      boolean not null default false,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index if not exists listings_search_idx on public.listings (status, mode, city, type, price);
create index if not exists listings_owner_idx on public.listings (owner_id);

-- Owners cannot approve or verify their own listings. Edits to a live listing send it back to review.
create or replace function public.listings_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.owner_id := auth.uid();
    if new.owner_id is null then raise exception 'Please log in first'; end if;
    if not public.is_admin() then
      new.status := 'pending';
      new.verification_level := 0;
      if (select count(*) from public.listings
          where owner_id = new.owner_id and created_at > now() - interval '1 day') >= 15 then
        raise exception 'Daily listing limit reached. Try again tomorrow.';
      end if;
    end if;
  else
    new.owner_id   := old.owner_id;
    new.created_at := old.created_at;
    if not public.is_admin() and coalesce(current_setting('chaabi.trusted', true), '') <> '1' then
      new.verification_level := old.verification_level;
      new.verified_deal      := old.verified_deal;
      new.featured_until     := old.featured_until;
      if new.status <> old.status and new.status not in ('sold','rented','archived') then
        new.status := old.status;
      end if;
      if old.status = 'active' and new.status = 'active' and
         (new.price <> old.price or new.title <> old.title or new.area <> old.area or new.description <> old.description) then
        new.status := 'pending';
      end if;
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists listings_guard on public.listings;
create trigger listings_guard before insert or update on public.listings
  for each row execute function public.listings_guard();

-- ---------- LISTING PHOTOS ----------
create table if not exists public.listing_photos (
  id         uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.listings (id) on delete cascade,
  owner_id   uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  path       text not null,
  position   int not null default 0 check (position between 0 and 19),
  created_at timestamptz not null default now()
);
create index if not exists listing_photos_listing_idx on public.listing_photos (listing_id, position);

-- ---------- FAVOURITES ----------
create table if not exists public.favorites (
  user_id    uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  listing_id uuid not null references public.listings (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, listing_id)
);

-- ---------- INQUIRIES (messages, visits, offers, token and deal records) ----------
create table if not exists public.inquiries (
  id         uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.listings (id) on delete cascade,
  sender_id  uuid not null references public.profiles (id) on delete cascade,
  owner_id   uuid not null references public.profiles (id) on delete cascade,
  kind       text not null check (kind in ('message','visit','offer','token','deal')),
  message    text check (message is null or char_length(message) <= 1000),
  amount     bigint check (amount is null or amount > 0),
  visit_at   timestamptz,
  status     text not null default 'open' check (status in ('open','accepted','declined','completed','cancelled')),
  ref_code   text not null unique default ('CH-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists inquiries_sender_idx on public.inquiries (sender_id);
create index if not exists inquiries_owner_idx on public.inquiries (owner_id);

create or replace function public.inquiries_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare l_owner uuid; l_status text;
begin
  if tg_op = 'INSERT' then
    select owner_id, status into l_owner, l_status from public.listings where id = new.listing_id;
    if not found or l_status <> 'active' then raise exception 'This listing is not available'; end if;
    new.sender_id := auth.uid();
    if new.sender_id is null then raise exception 'Please log in first'; end if;
    new.owner_id := l_owner;
    if new.sender_id = new.owner_id then raise exception 'You cannot send a request on your own listing'; end if;
    new.status := 'open';
    if new.kind in ('offer','token','deal') and new.amount is null then raise exception 'Amount is required'; end if;
    if new.kind = 'visit' and new.visit_at is null then raise exception 'Visit time is required'; end if;
    if (select count(*) from public.inquiries
        where sender_id = new.sender_id and created_at > now() - interval '1 day') >= 30 then
      raise exception 'Daily request limit reached. Try again tomorrow.';
    end if;
  else
    -- Only the status can change, and only in allowed directions.
    new.listing_id := old.listing_id; new.sender_id := old.sender_id; new.owner_id := old.owner_id;
    new.kind := old.kind; new.message := old.message; new.amount := old.amount;
    new.visit_at := old.visit_at; new.ref_code := old.ref_code; new.created_at := old.created_at;
    if auth.uid() = old.owner_id then
      if not ((old.status = 'open' and new.status in ('accepted','declined'))
           or (old.status = 'accepted' and new.status = 'completed')) then
        new.status := old.status;
      end if;
    elsif auth.uid() = old.sender_id then
      if not (old.status in ('open','accepted') and new.status = 'cancelled') then
        new.status := old.status;
      end if;
    else
      new.status := old.status;
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists inquiries_guard on public.inquiries;
create trigger inquiries_guard before insert or update on public.inquiries
  for each row execute function public.inquiries_guard();

-- ---------- PROOF EMAIL LOG (written by the edge function only) ----------
create table if not exists public.proof_emails (
  id          uuid primary key default gen_random_uuid(),
  inquiry_id  uuid not null references public.inquiries (id) on delete cascade,
  event       text not null check (event in ('created','accepted','declined','completed','cancelled')),
  status      text not null default 'sending' check (status in ('sending','sent','failed')),
  error       text,
  sent_at     timestamptz,
  created_at  timestamptz not null default now(),
  unique (inquiry_id, event)
);

-- =====================================================================
-- ROW LEVEL SECURITY
-- =====================================================================
alter table public.profiles       enable row level security;
alter table public.listings       enable row level security;
alter table public.listing_photos enable row level security;
alter table public.favorites      enable row level security;
alter table public.inquiries      enable row level security;
alter table public.proof_emails   enable row level security;

-- Profiles: public name/role only. Phone numbers are never readable by others.
revoke all on public.profiles from anon, authenticated;
grant select (id, full_name, role, city, cnic_verified, created_at) on public.profiles to anon, authenticated;
grant update (full_name, phone, role, city) on public.profiles to authenticated;

drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to anon, authenticated using (true);
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Your own full profile (with phone) through a function.
create or replace function public.my_profile()
returns setof public.profiles language sql stable security definer set search_path = public as $$
  select * from public.profiles where id = auth.uid();
$$;
grant execute on function public.my_profile() to authenticated;

-- Listings
drop policy if exists listings_read on public.listings;
create policy listings_read on public.listings for select to anon, authenticated
  using (status = 'active' or owner_id = auth.uid() or public.is_admin());
drop policy if exists listings_insert on public.listings;
create policy listings_insert on public.listings for insert to authenticated
  with check (owner_id = auth.uid());
drop policy if exists listings_update on public.listings;
create policy listings_update on public.listings for update to authenticated
  using (owner_id = auth.uid() or public.is_admin())
  with check (owner_id = auth.uid() or public.is_admin());
drop policy if exists listings_delete on public.listings;
create policy listings_delete on public.listings for delete to authenticated
  using (owner_id = auth.uid() or public.is_admin());

-- Photos
drop policy if exists photos_read on public.listing_photos;
create policy photos_read on public.listing_photos for select to anon, authenticated
  using (exists (select 1 from public.listings l where l.id = listing_id
                 and (l.status = 'active' or l.owner_id = auth.uid() or public.is_admin())));
drop policy if exists photos_insert on public.listing_photos;
create policy photos_insert on public.listing_photos for insert to authenticated
  with check (owner_id = auth.uid()
              and exists (select 1 from public.listings l where l.id = listing_id and l.owner_id = auth.uid())
              and path like auth.uid()::text || '/%');
drop policy if exists photos_delete on public.listing_photos;
create policy photos_delete on public.listing_photos for delete to authenticated
  using (owner_id = auth.uid() or public.is_admin());

-- Favourites
drop policy if exists favs_all on public.favorites;
create policy favs_all on public.favorites for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Inquiries
drop policy if exists inq_read on public.inquiries;
create policy inq_read on public.inquiries for select to authenticated
  using (sender_id = auth.uid() or owner_id = auth.uid() or public.is_admin());
drop policy if exists inq_insert on public.inquiries;
create policy inq_insert on public.inquiries for insert to authenticated
  with check (sender_id = auth.uid());
drop policy if exists inq_update on public.inquiries;
create policy inq_update on public.inquiries for update to authenticated
  using (sender_id = auth.uid() or owner_id = auth.uid())
  with check (sender_id = auth.uid() or owner_id = auth.uid());

-- Proof log: participants can read, nobody writes from the app.
drop policy if exists proof_read on public.proof_emails;
create policy proof_read on public.proof_emails for select to authenticated
  using (exists (select 1 from public.inquiries i where i.id = inquiry_id
                 and (i.sender_id = auth.uid() or i.owner_id = auth.uid())));

-- Contact numbers unlock only after the owner accepts.
create or replace function public.inquiry_contact(p_id uuid)
returns table (sender_name text, sender_phone text, owner_name text, owner_phone text)
language sql stable security definer set search_path = public as $$
  select s.full_name, s.phone, o.full_name, o.phone
  from public.inquiries i
  join public.profiles s on s.id = i.sender_id
  join public.profiles o on o.id = i.owner_id
  where i.id = p_id
    and i.status in ('accepted','completed')
    and auth.uid() in (i.sender_id, i.owner_id);
$$;
grant execute on function public.inquiry_contact(uuid) to authenticated;

-- =====================================================================
-- PHOTO STORAGE (public bucket, 5 MB per photo, images only)
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('listing-photos', 'listing-photos', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 5242880,
  allowed_mime_types = array['image/jpeg','image/png','image/webp'];

drop policy if exists "chaabi photos upload" on storage.objects;
create policy "chaabi photos upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'listing-photos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "chaabi photos delete" on storage.objects;
create policy "chaabi photos delete" on storage.objects for delete to authenticated
  using (bucket_id = 'listing-photos' and (storage.foldername(name))[1] = auth.uid()::text);

-- =====================================================================
-- MAPS + WORLDWIDE: location pin, address, country and currency per listing
-- =====================================================================
alter table public.listings add column if not exists lat double precision;
alter table public.listings add column if not exists lng double precision;
alter table public.listings add column if not exists address text;
alter table public.listings add column if not exists country text not null default 'Pakistan';
alter table public.listings add column if not exists currency text not null default 'PKR';
alter table public.listings drop constraint if exists listings_city_check;
alter table public.listings drop constraint if exists listings_geo_check;
alter table public.listings add constraint listings_geo_check check (
  char_length(city) between 1 and 60
  and (lat is null or lat between -90 and 90)
  and (lng is null or lng between -180 and 180)
  and (address is null or char_length(address) <= 300)
  and char_length(country) between 2 and 60
  and currency ~ '^[A-Z]{3}$');
create index if not exists listings_geo_idx on public.listings (lat, lng);
create index if not exists listings_country_city_idx on public.listings (country, lower(city));

-- =====================================================================
-- DEAL ROOM: deal token, bayana, iqrarnama, checks, 2% commission
-- All changes go through the functions below; the app cannot edit deals directly.
-- =====================================================================
create table if not exists public.deals (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null unique default ('CHD-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6))),
  listing_id          uuid not null references public.listings (id) on delete restrict,
  inquiry_id          uuid references public.inquiries (id) on delete set null,
  seller_id           uuid not null references public.profiles (id),
  buyer_id            uuid references public.profiles (id),
  currency            text not null default 'PKR',
  price               bigint not null check (price > 0),
  stage               text not null default 'token' check (stage in ('token','bayana','iqrar','completed','cancelled')),
  bayana_amount       bigint check (bayana_amount is null or bayana_amount > 0),
  bayana_mode         text check (bayana_mode is null or bayana_mode in ('cash','bank','cheque','online')),
  bayana_ref          text,
  bayana_paid_at      date,
  bayana_confirmed_at timestamptz,
  balance_due_date    date,
  possession_date     date,
  terms               text check (terms is null or char_length(terms) <= 2000),
  seller_name text, seller_father text, seller_cnic text check (seller_cnic is null or seller_cnic ~ '^[0-9]{5}-[0-9]{7}-[0-9]$'),
  buyer_name  text, buyer_father  text, buyer_cnic  text check (buyer_cnic  is null or buyer_cnic  ~ '^[0-9]{5}-[0-9]{7}-[0-9]$'),
  seller_sign text, seller_signed_at timestamptz,
  buyer_sign  text, buyer_signed_at  timestamptz,
  seller_done_at timestamptz, buyer_done_at timestamptz,
  doc_check     text not null default 'pending' check (doc_check in ('pending','passed','failed')),
  doc_note      text,
  society_check text not null default 'pending' check (society_check in ('pending','passed','failed','na')),
  society_note  text,
  verified      boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists deals_seller_idx on public.deals (seller_id);
create index if not exists deals_buyer_idx on public.deals (buyer_id);
create index if not exists deals_listing_idx on public.deals (listing_id);

create table if not exists public.deal_docs (
  id          uuid primary key default gen_random_uuid(),
  deal_id     uuid not null references public.deals (id) on delete cascade,
  uploaded_by uuid not null default auth.uid() references public.profiles (id),
  kind        text not null check (kind in ('fard','registry','allotment','noc','map','cnic','other')),
  path        text not null,
  created_at  timestamptz not null default now()
);

create table if not exists public.commissions (
  id         uuid primary key default gen_random_uuid(),
  deal_id    uuid not null references public.deals (id) on delete cascade,
  user_id    uuid not null references public.profiles (id),
  party      text not null check (party in ('buyer','seller')),
  amount     bigint not null check (amount >= 0),
  currency   text not null default 'PKR',
  status     text not null default 'due' check (status in ('due','paid','waived')),
  receipt_no text not null unique default ('CHR-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))),
  paid_at    timestamptz,
  created_at timestamptz not null default now(),
  unique (deal_id, party)
);

alter table public.deals       enable row level security;
alter table public.deal_docs   enable row level security;
alter table public.commissions enable row level security;

create or replace function public.is_deal_party(p_deal uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.deals d where d.id = p_deal and auth.uid() in (d.seller_id, d.buyer_id));
$$;

drop policy if exists deals_read on public.deals;
create policy deals_read on public.deals for select to authenticated
  using (auth.uid() = seller_id or auth.uid() = buyer_id or public.is_admin());
drop policy if exists docs_read on public.deal_docs;
create policy docs_read on public.deal_docs for select to authenticated
  using (public.is_deal_party(deal_id) or public.is_admin());
drop policy if exists docs_insert on public.deal_docs;
create policy docs_insert on public.deal_docs for insert to authenticated
  with check (uploaded_by = auth.uid() and public.is_deal_party(deal_id) and path like deal_id::text || '/%');
drop policy if exists comm_read on public.commissions;
create policy comm_read on public.commissions for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- Proof emails now also cover deals
alter table public.proof_emails add column if not exists deal_id uuid references public.deals (id) on delete cascade;
alter table public.proof_emails alter column inquiry_id drop not null;
alter table public.proof_emails drop constraint if exists proof_emails_event_check;
alter table public.proof_emails add constraint proof_emails_event_check check (event in (
  'created','accepted','declined','completed','cancelled',
  'deal_created','buyer_joined','bayana_recorded','bayana_confirmed','seller_signed','buyer_signed','deal_completed','deal_cancelled'));
create unique index if not exists proof_emails_deal_event on public.proof_emails (deal_id, event) where deal_id is not null;
drop policy if exists proof_read on public.proof_emails;
create policy proof_read on public.proof_emails for select to authenticated using (
  (inquiry_id is not null and exists (select 1 from public.inquiries i where i.id = inquiry_id and auth.uid() in (i.sender_id, i.owner_id)))
  or (deal_id is not null and public.is_deal_party(deal_id)));

-- Private bucket for property documents (only the two parties and admin can open them)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('deal-docs', 'deal-docs', false, 10485760, array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do update set public = false, file_size_limit = 10485760,
  allowed_mime_types = array['image/jpeg','image/png','image/webp','application/pdf'];
drop policy if exists "chaabi deal docs upload" on storage.objects;
create policy "chaabi deal docs upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'deal-docs' and exists (select 1 from public.deals d
    where d.id::text = (storage.foldername(name))[1] and auth.uid() in (d.seller_id, d.buyer_id)));
drop policy if exists "chaabi deal docs read" on storage.objects;
create policy "chaabi deal docs read" on storage.objects for select to authenticated
  using (bucket_id = 'deal-docs' and exists (select 1 from public.deals d
    where d.id::text = (storage.foldername(name))[1]));

-- ---------- deal functions ----------
create or replace function public._deal_lock(p_deal uuid)
returns public.deals language plpgsql security definer set search_path = public as $$
declare d public.deals;
begin
  select * into d from public.deals where id = p_deal for update;
  if not found then raise exception 'Deal not found'; end if;
  if auth.uid() is null or not (auth.uid() = d.seller_id or auth.uid() is not distinct from d.buyer_id or public.is_admin()) then
    raise exception 'Not allowed';
  end if;
  return d;
end $$;
revoke execute on function public._deal_lock(uuid) from public, anon, authenticated;

create or replace function public.create_deal(p_listing uuid, p_price bigint, p_inquiry uuid default null)
returns public.deals language plpgsql security definer set search_path = public as $$
declare l public.listings; i public.inquiries; d public.deals; b uuid := null;
begin
  if auth.uid() is null then raise exception 'Please log in first'; end if;
  select * into l from public.listings where id = p_listing;
  if not found or l.status not in ('active','pending') then raise exception 'This listing is not available'; end if;
  if p_inquiry is not null then
    select * into i from public.inquiries where id = p_inquiry and listing_id = p_listing;
    if not found or i.status not in ('accepted','completed') then raise exception 'The request must be accepted first'; end if;
    b := i.sender_id;
  end if;
  if auth.uid() <> l.owner_id and auth.uid() is distinct from b then
    raise exception 'Only the owner or the accepted buyer can start a deal';
  end if;
  if exists (select 1 from public.deals where listing_id = p_listing and stage in ('token','bayana','iqrar')) then
    raise exception 'This listing already has an open deal';
  end if;
  insert into public.deals (listing_id, inquiry_id, seller_id, buyer_id, currency, price)
  values (p_listing, p_inquiry, l.owner_id, b, l.currency, coalesce(nullif(p_price, 0), l.price))
  returning * into d;
  return d;
end $$;

create or replace function public.join_deal(p_code text)
returns public.deals language plpgsql security definer set search_path = public as $$
declare d public.deals;
begin
  if auth.uid() is null then raise exception 'Please log in first'; end if;
  select * into d from public.deals where code = upper(trim(p_code)) for update;
  if not found then raise exception 'Deal code not found'; end if;
  if d.stage <> 'token' then raise exception 'This deal is no longer open to join'; end if;
  if d.seller_id = auth.uid() then raise exception 'You are the seller in this deal'; end if;
  if d.buyer_id is not null and d.buyer_id <> auth.uid() then raise exception 'This deal already has a buyer'; end if;
  update public.deals set buyer_id = auth.uid(), updated_at = now() where id = d.id returning * into d;
  return d;
end $$;

create or replace function public.record_bayana(p_deal uuid, p_amount bigint, p_mode text, p_ref text, p_paid date)
returns public.deals language plpgsql security definer set search_path = public as $$
declare d public.deals;
begin
  d := public._deal_lock(p_deal);
  if auth.uid() is distinct from d.buyer_id then raise exception 'Only the buyer records the bayana'; end if;
  if d.stage <> 'token' then raise exception 'Bayana is already recorded'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > d.price then raise exception 'Enter a valid bayana amount'; end if;
  if p_mode is null or p_mode not in ('cash','bank','cheque','online') then raise exception 'Choose how it was paid'; end if;
  update public.deals set bayana_amount = p_amount, bayana_mode = p_mode, bayana_ref = left(nullif(trim(p_ref), ''), 80),
    bayana_paid_at = coalesce(p_paid, current_date), stage = 'bayana', updated_at = now()
  where id = d.id returning * into d;
  return d;
end $$;

create or replace function public.confirm_bayana(p_deal uuid)
returns public.deals language plpgsql security definer set search_path = public as $$
declare d public.deals;
begin
  d := public._deal_lock(p_deal);
  if auth.uid() <> d.seller_id then raise exception 'Only the seller confirms receipt'; end if;
  if d.stage <> 'bayana' or d.bayana_confirmed_at is not null then raise exception 'Nothing to confirm'; end if;
  update public.deals set bayana_confirmed_at = now(), updated_at = now() where id = d.id returning * into d;
  return d;
end $$;

create or replace function public.save_party(p_deal uuid, p_name text, p_father text, p_cnic text)
returns public.deals language plpgsql security definer set search_path = public as $$
declare d public.deals;
begin
  d := public._deal_lock(p_deal);
  if d.bayana_confirmed_at is null or d.stage <> 'bayana' then raise exception 'Confirm the bayana first'; end if;
  if d.seller_sign is not null or d.buyer_sign is not null then raise exception 'Details are locked after the first signature'; end if;
  if char_length(trim(coalesce(p_name, ''))) < 3 or char_length(trim(coalesce(p_father, ''))) < 3 then raise exception 'Enter full names'; end if;
  if coalesce(p_cnic, '') !~ '^[0-9]{5}-[0-9]{7}-[0-9]$' then raise exception 'Enter CNIC like 12345-1234567-1'; end if;
  if auth.uid() = d.seller_id then
    update public.deals set seller_name = left(trim(p_name), 80), seller_father = left(trim(p_father), 80), seller_cnic = p_cnic, updated_at = now() where id = d.id returning * into d;
  elsif auth.uid() = d.buyer_id then
    update public.deals set buyer_name = left(trim(p_name), 80), buyer_father = left(trim(p_father), 80), buyer_cnic = p_cnic, updated_at = now() where id = d.id returning * into d;
  else raise exception 'Only the buyer or seller can do this'; end if;
  return d;
end $$;

create or replace function public.set_terms(p_deal uuid, p_due date, p_possession date, p_terms text)
returns public.deals language plpgsql security definer set search_path = public as $$
declare d public.deals;
begin
  d := public._deal_lock(p_deal);
  if auth.uid() not in (d.seller_id, d.buyer_id) then raise exception 'Only the buyer or seller can do this'; end if;
  if d.bayana_confirmed_at is null or d.stage <> 'bayana' then raise exception 'Confirm the bayana first'; end if;
  if d.seller_sign is not null or d.buyer_sign is not null then raise exception 'Terms are locked after the first signature'; end if;
  if p_due is null or p_due < current_date then raise exception 'Choose a balance payment date'; end if;
  update public.deals set balance_due_date = p_due, possession_date = p_possession, terms = left(p_terms, 2000), updated_at = now()
  where id = d.id returning * into d;
  return d;
end $$;

create or replace function public.sign_iqrar(p_deal uuid, p_sign text)
returns public.deals language plpgsql security definer set search_path = public as $$
declare d public.deals; mine text;
begin
  d := public._deal_lock(p_deal);
  if d.stage <> 'bayana' or d.bayana_confirmed_at is null then raise exception 'This deal is not ready for signing'; end if;
  if d.seller_name is null or d.buyer_name is null or d.balance_due_date is null then
    raise exception 'Both parties'' details and the terms are needed before signing';
  end if;
  mine := case when auth.uid() = d.seller_id then d.seller_name when auth.uid() = d.buyer_id then d.buyer_name end;
  if mine is null then raise exception 'Only the buyer or seller can sign'; end if;
  if lower(trim(p_sign)) <> lower(trim(mine)) then raise exception 'The signature must match your saved full name'; end if;
  if auth.uid() = d.seller_id then
    update public.deals set seller_sign = trim(p_sign), seller_signed_at = now(), updated_at = now() where id = d.id and seller_sign is null returning * into d;
  else
    update public.deals set buyer_sign = trim(p_sign), buyer_signed_at = now(), updated_at = now() where id = d.id and buyer_sign is null returning * into d;
  end if;
  select * into d from public.deals where id = p_deal;
  if d.seller_sign is not null and d.buyer_sign is not null then
    update public.deals set stage = 'iqrar', updated_at = now() where id = d.id returning * into d;
  end if;
  return d;
end $$;

create or replace function public._deal_refresh_verified(p_deal uuid)
returns void language plpgsql security definer set search_path = public as $$
declare d public.deals;
begin
  select * into d from public.deals where id = p_deal;
  if d.stage <> 'completed' then return; end if;
  update public.deals set verified = (doc_check = 'passed' and society_check in ('passed','na')) where id = d.id returning * into d;
  perform set_config('chaabi.trusted', '1', true);
  update public.listings set verified_deal = d.verified where id = d.listing_id;
  perform set_config('chaabi.trusted', '', true);
end $$;
revoke execute on function public._deal_refresh_verified(uuid) from public, anon, authenticated;

create or replace function public.complete_deal(p_deal uuid)
returns public.deals language plpgsql security definer set search_path = public as $$
declare d public.deals;
begin
  d := public._deal_lock(p_deal);
  if d.stage <> 'iqrar' then raise exception 'Both parties must sign the iqrarnama first'; end if;
  if auth.uid() = d.seller_id then update public.deals set seller_done_at = coalesce(seller_done_at, now()) where id = d.id returning * into d;
  elsif auth.uid() = d.buyer_id then update public.deals set buyer_done_at = coalesce(buyer_done_at, now()) where id = d.id returning * into d;
  else raise exception 'Only the buyer or seller can do this'; end if;
  if d.seller_done_at is not null and d.buyer_done_at is not null then
    update public.deals set stage = 'completed', updated_at = now() where id = d.id returning * into d;
    perform set_config('chaabi.trusted', '1', true);
    update public.listings set status = case when mode = 'rent' then 'rented' else 'sold' end, updated_at = now() where id = d.listing_id;
    perform set_config('chaabi.trusted', '', true);
    insert into public.commissions (deal_id, user_id, party, amount, currency) values
      (d.id, d.seller_id, 'seller', round(d.price * 0.02), d.currency),
      (d.id, d.buyer_id,  'buyer',  round(d.price * 0.02), d.currency)
    on conflict (deal_id, party) do nothing;
    perform public._deal_refresh_verified(d.id);
    select * into d from public.deals where id = p_deal;
  end if;
  return d;
end $$;

create or replace function public.cancel_deal(p_deal uuid)
returns public.deals language plpgsql security definer set search_path = public as $$
declare d public.deals;
begin
  d := public._deal_lock(p_deal);
  if d.stage = 'completed' or d.stage = 'cancelled' then raise exception 'This deal cannot be cancelled'; end if;
  if d.stage = 'iqrar' and not public.is_admin() then raise exception 'A signed iqrarnama can only be cancelled by Chaabi.com support'; end if;
  update public.deals set stage = 'cancelled', updated_at = now() where id = d.id returning * into d;
  return d;
end $$;

create or replace function public.admin_check(p_deal uuid, p_doc text, p_doc_note text, p_soc text, p_soc_note text)
returns public.deals language plpgsql security definer set search_path = public as $$
declare d public.deals;
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  if p_doc not in ('pending','passed','failed') or p_soc not in ('pending','passed','failed','na') then raise exception 'Invalid status'; end if;
  update public.deals set doc_check = p_doc, doc_note = left(p_doc_note, 500), society_check = p_soc, society_note = left(p_soc_note, 500), updated_at = now()
  where id = p_deal returning * into d;
  if not found then raise exception 'Deal not found'; end if;
  perform public._deal_refresh_verified(d.id);
  select * into d from public.deals where id = p_deal;
  return d;
end $$;

create or replace function public.mark_commission(p_id uuid, p_status text)
returns public.commissions language plpgsql security definer set search_path = public as $$
declare c public.commissions;
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  if p_status not in ('due','paid','waived') then raise exception 'Invalid status'; end if;
  update public.commissions set status = p_status, paid_at = case when p_status = 'paid' then now() else null end
  where id = p_id returning * into c;
  return c;
end $$;

-- Public check of a printed code (no names, CNICs or amounts are shown)
create or replace function public.verify_deal(p_code text)
returns table (code text, stage text, listing_title text, city text, country text, started_at timestamptz,
               bayana_confirmed boolean, iqrar_signed boolean, completed boolean, doc_check text, society_check text, verified boolean)
language sql stable security definer set search_path = public as $$
  select d.code, d.stage, l.title, l.city, l.country, d.created_at,
         d.bayana_confirmed_at is not null, (d.seller_sign is not null and d.buyer_sign is not null),
         d.stage = 'completed', d.doc_check, d.society_check, d.verified
  from public.deals d join public.listings l on l.id = d.listing_id
  where d.code = upper(trim(p_code));
$$;
grant execute on function public.verify_deal(text) to anon, authenticated;

-- =====================================================================
-- SERVICES: requests for plans, featured listing, Ghar Health Check, document and society checks
-- =====================================================================
create table if not exists public.service_requests (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  kind         text not null check (kind in ('health_check','doc_check','society_check','featured','dealer_plan','valuation')),
  plan         text check (plan is null or char_length(plan) <= 40),
  city         text check (city is null or char_length(city) <= 60),
  details      text check (details is null or char_length(details) <= 1500),
  preferred_at timestamptz,
  status       text not null default 'new' check (status in ('new','contacted','scheduled','done','cancelled')),
  created_at   timestamptz not null default now()
);
alter table public.service_requests enable row level security;
drop policy if exists sr_insert on public.service_requests;
create policy sr_insert on public.service_requests for insert to authenticated with check (user_id = auth.uid());
drop policy if exists sr_read on public.service_requests;
create policy sr_read on public.service_requests for select to authenticated using (user_id = auth.uid() or public.is_admin());
drop policy if exists sr_admin on public.service_requests;
create policy sr_admin on public.service_requests for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- AI expert daily usage (written only by the ai-agent function)
create table if not exists public.ai_usage (
  user_id uuid not null references public.profiles (id) on delete cascade,
  day     date not null default current_date,
  count   int not null default 0,
  primary key (user_id, day)
);
alter table public.ai_usage enable row level security;

-- =====================================================================
-- AFTER YOU SIGN UP YOURSELF, make your account the admin (change the email):
--   update public.profiles set is_admin = true, cnic_verified = true
--   where id = (select id from auth.users where email = 'chaabi.official@gmail.com');
-- =====================================================================
