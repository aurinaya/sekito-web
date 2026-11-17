-- 16/11/2026 · lo que dejó S7 y lo próximo
--
-- En el perfil, arriba de todo, dos secciones nuevas en lugar del cartel de S7:
--   * lo que dejó S7: "estuviste" (con la hora en que entró) o "te lo perdiste..",
--     y la palabra: quien estuvo deja una sola, y se ven todas en una nube.
--   * lo próximo: "quiero saber" deja anotada a la persona.
-- Estuvo = tiene SEKI 7 atestiguada (asistencias confirmada), que el 16/11 se
-- les dio a todos los que pasaron por la puerta y a MAU, NAYA y la REINA.
-- Las palabras no tienen nombre para nadie. El panel puede ocultar una (nadie se
-- borra, nada se borra), y ve cuántos quieren saber.

-- ------------------------------------------------------------------ tablas
-- miembro_id es único pero puede ir vacío: las sembradas (abajo) no son de nadie
create table if not exists public.palabras_s7 (
  id         bigserial primary key,
  miembro_id uuid unique references public.miembros(id),
  palabra    text not null check (palabra ~ '^\S{1,20}$'),
  creada_en  timestamptz not null default now(),
  oculta     boolean not null default false,
  sembrada   boolean not null default false
);
alter table public.palabras_s7 enable row level security;

create table if not exists public.quieren_saber (
  miembro_id uuid primary key references public.miembros(id),
  creado_en  timestamptz not null default now()
);
alter table public.quieren_saber enable row level security;

-- las sembradas (Mau, 16/11): al principio casi nadie escribe, así que la nube
-- arranca con estas ocho (manija tres veces y musicón dos, para que no salgan
-- todas del mismo tamaño), para que se vea viva y anime a dejar la propia. En el
-- panel se ven marcadas como sembradas; en el portal, como cualquier otra.
insert into public.palabras_s7 (palabra, sembrada)
select p, true
  from unnest(array['manija','manija','manija','próxima','musicón','musicón','sebailó','lookazos','aguanteseki','otra','hermosxs']) as p
 where not exists (select 1 from public.palabras_s7 where sembrada);

-- ------------------------------------------------------------------ portal
create or replace function public.estuvo_en_s7(p_miembro uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.asistencias a
     where a.miembro_id = p_miembro
       and a.fiesta_id = 'df8003db-b883-4f95-9d34-446b900f0345'
       and a.estado = 'confirmada');
$$;

-- lo de cada uno: si estuvo, a qué hora entró, su palabra y si ya pidió saber
create or replace function public.mi_s7(p_codigo text)
returns table(estuvo boolean, entro_en timestamptz, mi_palabra text, quiero_saber boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  return query select
    public.estuvo_en_s7(v_yo),
    (select min(e.adentro_en) from public.entradas e
      where e.duenio = v_yo and e.evento = 'seki7' and e.anulada_en is null),
    (select p.palabra from public.palabras_s7 p where p.miembro_id = v_yo),
    exists (select 1 from public.quieren_saber q where q.miembro_id = v_yo);
end;
$$;

-- la nube: cada palabra con cuántas veces se dijo, sin nombres
create or replace function public.palabras_s7(p_codigo text)
returns table(palabra text, cuantas integer)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.miembro_de(p_codigo);
  return query
    select p.palabra, count(*)::integer
      from public.palabras_s7 p
     where not p.oculta
     group by p.palabra
     order by count(*) desc, min(p.creada_en)
     limit 150;
end;
$$;

-- una sola palabra, una sola vez, y solo quien estuvo
create or replace function public.dejar_palabra_s7(p_codigo text, p_palabra text)
returns table(palabra text)
language plpgsql security definer set search_path = public as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
  v_p  text := lower(btrim(coalesce(p_palabra, '')));
begin
  if not public.estuvo_en_s7(v_yo) then raise exception 'no_estuviste'; end if;
  if v_p !~ '^\S{1,20}$' then raise exception 'palabra_invalida'; end if;
  insert into public.palabras_s7 (miembro_id, palabra) values (v_yo, v_p)
  on conflict (miembro_id) do nothing;
  if not found then raise exception 'ya_dejaste'; end if;
  return query select v_p;
end;
$$;

create or replace function public.quiero_saber(p_codigo text)
returns table(ok boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  insert into public.quieren_saber (miembro_id) values (v_yo)
  on conflict (miembro_id) do nothing;
  return query select true;
end;
$$;

-- ------------------------------------------------------------------ panel
create or replace function public.admin_palabras_s7(p_codigo text)
returns table(palabra text, cuantas integer, oculta boolean, sembrada boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.admin_id_de(p_codigo);
  return query
    select p.palabra, count(*)::integer, bool_or(p.oculta), bool_and(p.sembrada)
      from public.palabras_s7 p
     group by p.palabra
     order by count(*) desc, min(p.creada_en);
end;
$$;

-- ocultar (o volver a mostrar) una palabra: todas las veces que se dijo
create or replace function public.admin_ocultar_palabra_s7(p_codigo text, p_palabra text, p_oculta boolean)
returns table(ok boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_admin uuid := public.admin_id_de(p_codigo);
begin
  update public.palabras_s7 set oculta = p_oculta where palabra = p_palabra;
  insert into public.admin_acciones (admin_id, accion, detalle)
  values (v_admin, case when p_oculta then 'ocultar_palabra_s7' else 'mostrar_palabra_s7' end,
          jsonb_build_object('palabra', p_palabra));
  return query select true;
end;
$$;

create or replace function public.admin_lo_proximo(p_codigo text)
returns table(quieren_saber integer, palabras integer)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.admin_id_de(p_codigo);
  return query select
    (select count(*)::integer from public.quieren_saber),
    (select count(*)::integer from public.palabras_s7);
end;
$$;

-- quiénes quieren saber: para avisarles primero cuando se anuncie lo próximo
create or replace function public.admin_quieren_saber(p_codigo text)
returns table(sektario text, nombre text, apodo text, email text, cuando timestamptz, estuvo_en_s7 boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.admin_id_de(p_codigo);
  return query
    select m.nombre_sektario, trim(coalesce(m.nombre_real, '') || ' ' || coalesce(m.apellido, '')), m.apodo, m.email,
           q.creado_en, public.estuvo_en_s7(m.id)
      from public.quieren_saber q
      join public.miembros m on m.id = q.miembro_id
     order by q.creado_en desc;
end;
$$;

grant execute on function public.admin_quieren_saber(text) to anon, authenticated;
grant execute on function public.mi_s7(text), public.palabras_s7(text), public.dejar_palabra_s7(text, text),
  public.quiero_saber(text), public.admin_palabras_s7(text), public.admin_ocultar_palabra_s7(text, text, boolean),
  public.admin_lo_proximo(text) to anon, authenticated;
revoke execute on function public.estuvo_en_s7(uuid) from public, anon, authenticated;
