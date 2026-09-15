-- ============================================================================
-- SÉKITO — panel de administración (parte 1: entrar y mirar)
-- ============================================================================
-- El panel no usa cuentas con mail y contraseña: se entra con un código de
-- administración, uno por persona.
--
-- Uno por persona y no uno compartido para que se pueda revocar el de alguien
-- sin obligar a los otros a aprenderse uno nuevo, y para que cada acción quede
-- registrada con quién la hizo.
--
-- Los códigos son largos a propósito (16 caracteres, ~79 bits). En un sitio
-- estático como éste el código ES la única barrera: no hay servidor propio que
-- pueda frenar a alguien que pruebe códigos uno tras otro. Con este largo,
-- probarlos todos es inviable; con un código corto tipo XXX111 no lo sería.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. quiénes son administradores
-- ----------------------------------------------------------------------------
create table if not exists public.admins (
  id             uuid primary key default gen_random_uuid(),
  miembro_id     uuid references public.miembros(id) on delete restrict,
  nombre         text not null,
  codigo_admin   text not null unique,
  estado         text not null default 'activo'
                 check (estado in ('activo', 'revocado')),
  creado_en      timestamptz not null default now(),
  ultimo_acceso  timestamptz
);

comment on table public.admins is
  'Quiénes pueden entrar al panel. El código se guarda normalizado: sin guiones y en mayúsculas.';

alter table public.admins enable row level security;
-- sin políticas: nadie llega a esta tabla con la clave pública del sitio.
-- El único camino son las funciones de abajo.


-- ----------------------------------------------------------------------------
-- 2. registro de lo que hace cada admin
-- ----------------------------------------------------------------------------
-- Tres personas comparten el panel. Cuando aparezca un "¿quién suspendió a
-- éste?", la respuesta tiene que estar en algún lado.

create table if not exists public.admin_acciones (
  id          bigserial primary key,
  admin_id    uuid not null references public.admins(id) on delete restrict,
  accion      text not null,
  miembro_id  uuid references public.miembros(id) on delete set null,
  detalle     jsonb,
  creado_en   timestamptz not null default now()
);

create index if not exists admin_acciones_creado_idx
  on public.admin_acciones (creado_en desc);

alter table public.admin_acciones enable row level security;


-- ----------------------------------------------------------------------------
-- 3. una nota del admin sobre cada miembro
-- ----------------------------------------------------------------------------
-- Distinta de como_llegaste, que la escribe el propio miembro. Ésta es para
-- el que crea el código: "escribió por IG el 3/9", "amiga de Maia".
alter table public.miembros add column if not exists nota_admin text;


-- ----------------------------------------------------------------------------
-- 4. normalizar el código escrito a mano
-- ----------------------------------------------------------------------------
-- Se muestra como XXXX-XXXX-XXXX-XXXX pero alguien lo va a pegar con espacios,
-- en minúscula o sin guiones. Todo eso tiene que entrar igual.
create or replace function public.normalizar_codigo_admin(p_codigo text)
returns text
language sql
immutable
as $$
  select upper(regexp_replace(coalesce(p_codigo, ''), '[^a-zA-Z0-9]', '', 'g'));
$$;


-- ----------------------------------------------------------------------------
-- 5. el portero: traduce un código en un admin, o corta
-- ----------------------------------------------------------------------------
-- Todas las funciones del panel empiezan llamando a ésta. Si el código no
-- sirve, largan un error y no llegan a tocar ningún dato.
create or replace function public.admin_id_de(p_codigo text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  select a.id into v_id
    from public.admins a
   where a.codigo_admin = public.normalizar_codigo_admin(p_codigo)
     and a.estado = 'activo';

  if v_id is null then
    raise exception 'codigo_admin_invalido' using errcode = 'insufficient_privilege';
  end if;

  return v_id;
end;
$$;

-- a propósito NO se le da permiso a anon: sólo la usan las otras funciones,
-- por dentro. Si estuviera expuesta, serviría para probar códigos sin más.
revoke all on function public.admin_id_de(text) from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 6. entrar al panel
-- ----------------------------------------------------------------------------
create or replace function public.admin_entrar(p_codigo text)
returns table (nombre text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := public.admin_id_de(p_codigo);
begin
  update public.admins a set ultimo_acceso = now() where a.id = v_admin;

  return query
    select a.nombre from public.admins a where a.id = v_admin;
end;
$$;


-- ----------------------------------------------------------------------------
-- 7. la lista de miembros, completa
-- ----------------------------------------------------------------------------
-- Acá sí van el mail y el teléfono: es el panel de los fundadores, es el lugar
-- donde esos datos tienen que poder verse.
create or replace function public.admin_listar_miembros(p_codigo text)
returns table (
  id                   uuid,
  codigo_acceso        text,
  nombre_sektario      text,
  nombre_real          text,
  apellido             text,
  email                text,
  telefono             text,
  como_llegaste        text,
  nota_admin           text,
  estado_codigo        text,
  es_fundador          boolean,
  pantalla             text,
  invitado_por         uuid,
  invitado_por_nombre  text,
  registro_completo    boolean,
  fecha_ingreso        timestamptz,
  creado_en            timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_id_de(p_codigo);

  return query
    select
      m.id, m.codigo_acceso, m.nombre_sektario, m.nombre_real, m.apellido,
      m.email, m.telefono, m.como_llegaste, m.nota_admin, m.estado_codigo,
      m.es_fundador, m.pantalla, m.invitado_por,
      quien.nombre_sektario as invitado_por_nombre,
      (m.nombre_real is not null) as registro_completo,
      m.fecha_ingreso, m.creado_en
    from public.miembros m
    left join public.miembros quien on quien.id = m.invitado_por
    order by m.creado_en;
end;
$$;


-- ----------------------------------------------------------------------------
-- 8. el linaje, como lista con sangrías
-- ----------------------------------------------------------------------------
-- Devuelve cada miembro con su profundidad (0 = nadie lo invitó) y el camino
-- por el que se llega a él. El "camino" es lo que ordena la lista: hace que
-- cada persona aparezca justo debajo de quien la trajo.
--
-- Cuando hagamos el árbol dibujado, esta misma consulta sirve: profundidad y
-- camino son exactamente lo que necesita un árbol para ubicar cada nodo.
create or replace function public.admin_linaje(p_codigo text)
returns table (
  id               uuid,
  nombre_sektario  text,
  nombre_real      text,
  estado_codigo    text,
  invitado_por     uuid,
  profundidad      int,
  invitados        bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_id_de(p_codigo);

  return query
    with recursive arbol as (
      -- raíces: los que no tienen invitador cargado
      select m.id, m.nombre_sektario, m.nombre_real, m.estado_codigo,
             m.invitado_por, 0 as profundidad,
             array[coalesce(m.nombre_sektario, m.codigo_acceso)] as camino
        from public.miembros m
       where m.invitado_por is null

      union all

      -- y colgando de cada uno, los que invitó
      select h.id, h.nombre_sektario, h.nombre_real, h.estado_codigo,
             h.invitado_por, a.profundidad + 1,
             a.camino || coalesce(h.nombre_sektario, h.codigo_acceso)
        from public.miembros h
        join arbol a on h.invitado_por = a.id
    )
    select a.id, a.nombre_sektario, a.nombre_real, a.estado_codigo,
           a.invitado_por, a.profundidad,
           (select count(*) from public.miembros h where h.invitado_por = a.id) as invitados
      from arbol a
     order by a.camino;
end;
$$;


-- ----------------------------------------------------------------------------
-- 9. permisos
-- ----------------------------------------------------------------------------
-- Estas tres sí se exponen: el código que traen adentro es lo que las protege.
revoke all on function public.admin_entrar(text)           from public;
revoke all on function public.admin_listar_miembros(text)  from public;
revoke all on function public.admin_linaje(text)           from public;

grant execute on function public.admin_entrar(text)          to anon, authenticated;
grant execute on function public.admin_listar_miembros(text) to anon, authenticated;
grant execute on function public.admin_linaje(text)          to anon, authenticated;


-- ============================================================================
-- Los administradores se cargan aparte
-- ============================================================================
-- Los códigos reales NO van en este archivo: el repositorio es público.
-- Se cargan con un archivo suelto, con esta forma:
--
--   insert into public.admins (nombre, codigo_admin, miembro_id)
--   values ('MAU', public.normalizar_codigo_admin('XXXX-XXXX-XXXX-XXXX'),
--           (select id from public.miembros where nombre_sektario = 'MAU·000'));
-- ============================================================================
