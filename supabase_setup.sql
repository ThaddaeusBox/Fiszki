-- =====================================================================
--  FISZKI – konfiguracja bazy danych (Supabase)
--  Wklej CAŁY ten plik w: Supabase → SQL Editor → New query → Run
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- TABELE ----------

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nick text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 40),
  code text not null unique,
  owner_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.group_members (
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','member')),
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

-- group_id = NULL  -> kategoria prywatna (widoczna tylko dla owner_id)
-- group_id != NULL -> kategoria grupowa (widoczna dla członków grupy)
create table if not exists public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  group_id uuid references public.groups(id) on delete cascade,
  created_at timestamptz not null default now()
);
create unique index if not exists categories_private_name_uq
  on public.categories (owner_id, name) where group_id is null;
create unique index if not exists categories_group_name_uq
  on public.categories (group_id, name) where group_id is not null;
create index if not exists categories_group_idx on public.categories (group_id);

create table if not exists public.cards (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.categories(id) on delete cascade,
  front text not null default '',
  back text not null default '',
  image_front text,
  image_back text,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists cards_category_idx on public.cards (category_id);

-- Postęp nauki jest osobny dla każdego użytkownika (też w grupach)
create table if not exists public.progress (
  user_id uuid not null references auth.users(id) on delete cascade,
  card_id uuid not null references public.cards(id) on delete cascade,
  skip_rounds int not null default 0,
  primary key (user_id, card_id)
);

-- ---------- PROFIL TWORZONY AUTOMATYCZNIE PO REJESTRACJI ----------

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, nick)
  values (new.id, coalesce(new.raw_user_meta_data->>'nick', split_part(new.email, '@', 1)));
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- FUNKCJE POMOCNICZE (używane w regułach dostępu) ----------

create or replace function public.is_group_member(gid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.group_members
                 where group_id = gid and user_id = auth.uid());
$$;

create or replace function public.is_group_owner(gid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.group_members
                 where group_id = gid and user_id = auth.uid() and role = 'owner');
$$;

create or replace function public.can_access_category(cid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.categories c
    where c.id = cid
      and ( (c.group_id is null and c.owner_id = auth.uid())
         or (c.group_id is not null and public.is_group_member(c.group_id)) )
  );
$$;

create or replace function public.gen_group_code()
returns text language plpgsql volatile set search_path = public, extensions as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; -- 32 znaki, bez mylących 0/O/1/I
  bytes bytea := extensions.gen_random_bytes(10);
  result text := '';
  i int;
begin
  for i in 0..9 loop
    result := result || substr(alphabet, (get_byte(bytes, i) % 32) + 1, 1);
  end loop;
  return substr(result, 1, 5) || '-' || substr(result, 6, 5);
end $$;

-- ---------- FUNKCJE WYWOŁYWANE Z APLIKACJI ----------

create or replace function public.create_group(p_name text)
returns public.groups language plpgsql security definer set search_path = public as $$
declare
  g public.groups;
  c text;
begin
  if auth.uid() is null then raise exception 'Musisz być zalogowany'; end if;
  p_name := trim(coalesce(p_name, ''));
  if char_length(p_name) < 1 or char_length(p_name) > 40 then
    raise exception 'Nazwa grupy musi mieć od 1 do 40 znaków';
  end if;
  loop
    c := public.gen_group_code();
    exit when not exists (select 1 from public.groups where code = c);
  end loop;
  insert into public.groups (name, code, owner_id) values (p_name, c, auth.uid()) returning * into g;
  insert into public.group_members (group_id, user_id, role) values (g.id, auth.uid(), 'owner');
  return g;
end $$;

create or replace function public.join_group(p_code text)
returns public.groups language plpgsql security definer set search_path = public as $$
declare
  g public.groups;
  norm text := replace(replace(upper(trim(coalesce(p_code, ''))), '-', ''), ' ', '');
begin
  if auth.uid() is null then raise exception 'Musisz być zalogowany'; end if;
  select * into g from public.groups where replace(code, '-', '') = norm;
  if not found then raise exception 'Nieprawidłowy kod grupy'; end if;
  insert into public.group_members (group_id, user_id, role)
  values (g.id, auth.uid(), 'member')
  on conflict do nothing;
  return g;
end $$;

create or replace function public.regenerate_group_code(p_group uuid)
returns text language plpgsql security definer set search_path = public as $$
declare c text;
begin
  if not public.is_group_owner(p_group) then
    raise exception 'Tylko właściciel może zmienić kod';
  end if;
  loop
    c := public.gen_group_code();
    exit when not exists (select 1 from public.groups where code = c);
  end loop;
  update public.groups set code = c where id = p_group;
  return c;
end $$;

create or replace function public.get_group_members(p_group uuid)
returns table (user_id uuid, nick text, role text, joined_at timestamptz)
language sql stable security definer set search_path = public as $$
  select m.user_id, p.nick, m.role, m.joined_at
  from public.group_members m
  join public.profiles p on p.id = m.user_id
  where m.group_id = p_group and public.is_group_member(p_group)
  order by (m.role = 'owner') desc, p.nick;
$$;

create or replace function public.my_groups()
returns table (id uuid, name text, code text, owner_id uuid, role text,
               member_count bigint, card_count bigint)
language sql stable security definer set search_path = public as $$
  select g.id, g.name, g.code, g.owner_id, m.role,
         (select count(*) from public.group_members x where x.group_id = g.id),
         (select count(*) from public.cards c
            join public.categories k on k.id = c.category_id
           where k.group_id = g.id)
  from public.groups g
  join public.group_members m on m.group_id = g.id and m.user_id = auth.uid()
  order by g.created_at desc;
$$;

-- ---------- ZABEZPIECZENIA (Row Level Security) ----------

alter table public.profiles      enable row level security;
alter table public.groups        enable row level security;
alter table public.group_members enable row level security;
alter table public.categories    enable row level security;
alter table public.cards         enable row level security;
alter table public.progress      enable row level security;

-- profiles: każdy widzi tylko własny profil (nicki członków dają funkcje powyżej)
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid());

-- groups: widzą członkowie, zmienia/usuwa właściciel; tworzenie tylko przez create_group()
drop policy if exists groups_select on public.groups;
create policy groups_select on public.groups for select to authenticated
  using (public.is_group_member(id));
drop policy if exists groups_update on public.groups;
create policy groups_update on public.groups for update to authenticated
  using (public.is_group_owner(id)) with check (public.is_group_owner(id));
drop policy if exists groups_delete on public.groups;
create policy groups_delete on public.groups for delete to authenticated
  using (public.is_group_owner(id));

-- group_members: dołączanie tylko przez join_group(); wyjście własne albo usunięcie przez właściciela
drop policy if exists members_select on public.group_members;
create policy members_select on public.group_members for select to authenticated
  using (public.is_group_member(group_id));
drop policy if exists members_delete on public.group_members;
create policy members_delete on public.group_members for delete to authenticated
  using ( (user_id = auth.uid() and role <> 'owner')
       or (public.is_group_owner(group_id) and user_id <> auth.uid()) );

-- categories
drop policy if exists categories_select on public.categories;
create policy categories_select on public.categories for select to authenticated
  using ( (group_id is null and owner_id = auth.uid())
       or (group_id is not null and public.is_group_member(group_id)) );
drop policy if exists categories_insert on public.categories;
create policy categories_insert on public.categories for insert to authenticated
  with check ( owner_id = auth.uid()
           and (group_id is null or public.is_group_member(group_id)) );
drop policy if exists categories_delete on public.categories;
create policy categories_delete on public.categories for delete to authenticated
  using ( owner_id = auth.uid()
       or (group_id is not null and public.is_group_owner(group_id)) );

-- cards: wszyscy z dostępem do kategorii mogą dodawać, edytować i usuwać
drop policy if exists cards_select on public.cards;
create policy cards_select on public.cards for select to authenticated
  using (public.can_access_category(category_id));
drop policy if exists cards_insert on public.cards;
create policy cards_insert on public.cards for insert to authenticated
  with check (public.can_access_category(category_id) and created_by = auth.uid());
drop policy if exists cards_update on public.cards;
create policy cards_update on public.cards for update to authenticated
  using (public.can_access_category(category_id))
  with check (public.can_access_category(category_id));
drop policy if exists cards_delete on public.cards;
create policy cards_delete on public.cards for delete to authenticated
  using (public.can_access_category(category_id));

-- progress: tylko własny
drop policy if exists progress_all on public.progress;
create policy progress_all on public.progress for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------- UPRAWNIENIA DO FUNKCJI ----------
revoke execute on all functions in schema public from public, anon;
grant execute on function
  public.is_group_member(uuid), public.is_group_owner(uuid), public.can_access_category(uuid),
  public.create_group(text), public.join_group(text), public.regenerate_group_code(uuid),
  public.get_group_members(uuid), public.my_groups()
to authenticated;
