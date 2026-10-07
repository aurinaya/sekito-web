-- ============================================================================
-- SÉKITO — la puerta de SEKI 7
-- ============================================================================
-- sekito.ar/puerta: un celu, o varios a la vez, que escanean el QR de la
-- entrada (o buscan a la persona) y la marcan adentro.
--
-- Quien acredita entra con una LLAVE DE PUERTA, no con una de admin: solo
-- puede leer una entrada, buscar y marcar. No ve mails, teléfonos ni llaves
-- de nadie. Una llave por persona, para saber quién marcó a quién.
--
-- Marcar es "el primero gana": si dos celus marcan a la misma persona, vale
-- el primero y el otro ve "ya entró a las 00:43 (Vicky)". No bloquea: quien
-- acredita decide (puede haber salido a fumar).
-- ============================================================================

create table if not exists public.puertas (
  id          uuid primary key default gen_random_uuid(),
  nombre      text not null,
  llave       text not null unique,
  estado      text not null default 'activa' check (estado in ('activa', 'revocada')),
  creada_por  uuid references public.admins(id) on delete set null,
  creada_en   timestamptz not null default now(),
  ultimo_uso  timestamptz
);
alter table public.puertas enable row level security;

comment on table public.puertas is
  'Las llaves de la puerta de SEKI 7: solo sirven para leer, buscar y marcar entradas.';

-- la llave de puerta, con o sin espacios y guiones, en mayúscula
create or replace function public.puerta_de(p_llave text)
returns table(id uuid, nombre text)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  return query
    update public.puertas p set ultimo_uso = now()
     where p.llave = upper(regexp_replace(coalesce(p_llave, ''), '[^a-zA-Z0-9]', '', 'g'))
       and p.estado = 'activa'
    returning p.id, p.nombre;
  if not found then
    raise exception 'llave_de_puerta_invalida' using errcode = 'insufficient_privilege';
  end if;
end;
$$;

-- el código como lo tipeen: "s7 xjnrm", "XJNRM", "S7-XJNRM" → S7-XJNRM
create or replace function public.codigo_de_entrada(p_texto text)
returns text
language sql
immutable
set search_path to 'public'
as $$
  select case
           when length(t) = 7 and t like 'S7%' then 'S7-' || substr(t, 3)
           when length(t) = 5                 then 'S7-' || t
           else null end
    from (select upper(regexp_replace(coalesce(p_texto, ''), '[^a-zA-Z0-9]', '', 'g')) as t) x;
$$;

-- lo que ve la puerta de una entrada. La foto la busca la página por el
-- código sektario, si la persona tiene
create or replace function public.puerta_fila(e public.entradas)
returns table(entrada_id uuid, codigo text, titulo text, nombre text, sektario text,
              tipo text, de_afuera boolean, adentro_en timestamptz, adentro_por text)
language sql
stable
security definer
set search_path to 'public'
as $$
  select e.id, e.codigo,
         upper(coalesce(m.apodo, e.externo_apodo, m.nombre_real, e.externo_nombre)),
         coalesce(nullif(trim(coalesce(public.nombre_lindo(m.nombre_real), '') || ' ' ||
                              coalesce(public.nombre_lindo(m.apellido), '')), ''),
                  nullif(trim(coalesce(e.externo_nombre, '') || ' ' || coalesce(e.externo_apellido, '')), '')),
         m.nombre_sektario, e.tipo, e.externo_nombre is not null,
         e.adentro_en, e.adentro_por
    from (select 1) uno
    left join public.miembros m on m.id = e.duenio;
$$;

create or replace function public.puerta_entrar(p_llave text)
returns table(nombre text)
language sql
security definer
set search_path to 'public'
as $$ select p.nombre from public.puerta_de(p_llave) p; $$;

-- escaneó un QR o tipeó un código
create or replace function public.puerta_leer(p_llave text, p_codigo text)
returns table(entrada_id uuid, codigo text, titulo text, nombre text, sektario text,
              tipo text, de_afuera boolean, adentro_en timestamptz, adentro_por text)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_e public.entradas;
begin
  perform public.puerta_de(p_llave);
  select * into v_e from public.entradas e
   where e.codigo = public.codigo_de_entrada(p_codigo) and e.anulada_en is null;
  if v_e.id is null then return; end if;
  return query select * from public.puerta_fila(v_e);
end;
$$;

-- buscó por apodo, nombre, apellido o código
create or replace function public.puerta_buscar(p_llave text, p_q text)
returns table(entrada_id uuid, codigo text, titulo text, nombre text, sektario text,
              tipo text, de_afuera boolean, adentro_en timestamptz, adentro_por text)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_q text := btrim(coalesce(p_q, ''));
begin
  perform public.puerta_de(p_llave);
  if length(v_q) < 2 then return; end if;

  return query
    select f.*
      from public.entradas e
      left join public.miembros m on m.id = e.duenio
      cross join lateral public.puerta_fila(e) f
     where e.anulada_en is null and e.codigo is not null
       and (public.coincide(v_q, m.nombre_sektario,
                            coalesce(m.nombre_real, e.externo_nombre),
                            coalesce(m.apellido, e.externo_apellido),
                            coalesce(m.apodo, e.externo_apodo))
            or e.codigo = public.codigo_de_entrada(v_q))
     order by public.empieza(v_q, m.nombre_sektario, coalesce(m.nombre_real, e.externo_nombre),
                             coalesce(m.apodo, e.externo_apodo)) desc,
              f.titulo
     limit 8;
end;
$$;

-- entra: el primero que marca, gana. Devuelve cómo quedó y si ya estaba
create or replace function public.puerta_marcar(p_llave text, p_entrada uuid)
returns table(ya_estaba boolean, adentro_en timestamptz, adentro_por text)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_p record;
begin
  select * into v_p from public.puerta_de(p_llave);

  update public.entradas e
     set adentro_en = now(), adentro_por = v_p.nombre
   where e.id = p_entrada and e.anulada_en is null and e.codigo is not null
     and e.adentro_en is null;

  if found then
    return query select false, e.adentro_en, e.adentro_por from public.entradas e where e.id = p_entrada;
  else
    return query select true, e.adentro_en, e.adentro_por from public.entradas e
                  where e.id = p_entrada and e.anulada_en is null;
  end if;
end;
$$;

-- me equivoqué de persona: se deshace
create or replace function public.puerta_desmarcar(p_llave text, p_entrada uuid)
returns table(ok boolean)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  perform public.puerta_de(p_llave);
  update public.entradas e set adentro_en = null, adentro_por = null
   where e.id = p_entrada and e.adentro_en is not null;
  return query select found;
end;
$$;

create or replace function public.puerta_conteo(p_llave text)
returns table(adentro integer, total integer)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  perform public.puerta_de(p_llave);
  return query
    select count(*) filter (where e.adentro_en is not null)::integer,
           count(*) filter (where e.codigo is not null)::integer
      from public.entradas e where e.anulada_en is null;
end;
$$;


-- ---------------------------------------------------------------------------
-- el panel: las llaves de puerta y la lista impresa
-- ---------------------------------------------------------------------------
create or replace function public.admin_crear_puerta(p_codigo text, p_nombre text)
returns table(llave text)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_admin  uuid := public.admin_id_de(p_codigo);
  v_nombre text := nullif(btrim(coalesce(p_nombre, '')), '');
  v_llave  text;
begin
  if v_nombre is null then raise exception 'falta_nombre'; end if;
  loop
    select 'PUERTA' || string_agg(substr('ACDEFGHJKMNPQRTUVWXY34679', 1 + floor(random() * 25)::int, 1), '')
      into v_llave from generate_series(1, 6);
    exit when not exists (select 1 from public.puertas where puertas.llave = v_llave);
  end loop;

  insert into public.puertas (nombre, llave, creada_por) values (v_nombre, v_llave, v_admin);
  insert into public.admin_acciones (admin_id, accion, detalle)
  values (v_admin, 'crear_puerta', jsonb_build_object('nombre', v_nombre));

  return query select v_llave;
end;
$$;

create or replace function public.admin_puertas(p_codigo text)
returns table(puerta_id uuid, nombre text, llave text, estado text, marcadas integer, ultimo_uso timestamptz)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  perform public.admin_id_de(p_codigo);
  return query
    select p.id, p.nombre, p.llave, p.estado,
           (select count(*)::integer from public.entradas e where e.adentro_por = p.nombre),
           p.ultimo_uso
      from public.puertas p
     order by p.creada_en;
end;
$$;

create or replace function public.admin_revocar_puerta(p_codigo text, p_puerta uuid)
returns table(ok boolean)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_admin uuid := public.admin_id_de(p_codigo);
begin
  update public.puertas set estado = 'revocada' where id = p_puerta and estado = 'activa';
  if not found then raise exception 'puerta_invalida'; end if;
  insert into public.admin_acciones (admin_id, accion, detalle)
  values (v_admin, 'revocar_puerta', jsonb_build_object('puerta', p_puerta));
  return query select true;
end;
$$;

-- la lista de papel, por si se cae internet: en orden de como se le dice
create or replace function public.admin_lista_puerta(p_codigo text)
returns table(titulo text, nombre text, sektario text, codigo text, tipo text)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  perform public.admin_id_de(p_codigo);
  return query
    select f.titulo, f.nombre, f.sektario, f.codigo, f.tipo
      from public.entradas e
      cross join lateral public.puerta_fila(e) f
     where e.anulada_en is null and e.codigo is not null
     order by public.para_buscar(f.titulo), public.para_buscar(f.nombre);
end;
$$;

revoke execute on function public.puerta_de(text) from public, anon, authenticated;
revoke execute on function public.codigo_de_entrada(text) from public, anon, authenticated;
revoke execute on function public.puerta_fila(public.entradas) from public, anon, authenticated;

notify pgrst, 'reload schema';
