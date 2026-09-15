-- ============================================================================
-- SÉKITO — panel de administración (parte 2: hacer cosas)
-- ============================================================================
-- Crear códigos para gente nueva, dar de baja, corregir datos.
--
-- Todas empiezan igual: el portero (admin_id_de) traduce el código en un
-- administrador o corta el paso. Y todas dejan constancia en admin_acciones.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. inventar un código de acceso libre
-- ----------------------------------------------------------------------------
-- Mismo formato que los que ya existen: tres letras y tres números, sin
-- relación con el nombre de la persona.
--
-- Sin I ni O: escritas a mano se confunden con 1 y 0, y estos códigos se
-- dictan por mensaje.
create or replace function public.generar_codigo_acceso()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_letras text := 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  v_codigo text;
  v_i      int;
begin
  for v_i in 1 .. 200 loop
    v_codigo :=
        substr(v_letras, floor(random() * length(v_letras))::int + 1, 1)
     || substr(v_letras, floor(random() * length(v_letras))::int + 1, 1)
     || substr(v_letras, floor(random() * length(v_letras))::int + 1, 1)
     || lpad(floor(random() * 1000)::int::text, 3, '0');

    if not exists (select 1 from public.miembros m where m.codigo_acceso = v_codigo) then
      return v_codigo;
    end if;
  end loop;

  raise exception 'No se pudo generar un código libre después de 200 intentos.';
end;
$$;

revoke all on function public.generar_codigo_acceso() from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 2. crear un miembro nuevo
-- ----------------------------------------------------------------------------
-- El caso típico: alguien escribe por Instagram y se le manda un código.
-- No se cargan nombre ni mail acá: los completa la propia persona cuando entra
-- al portal por primera vez y le aparece el formulario de bienvenida.
create or replace function public.admin_crear_miembro(
  p_codigo        text,
  p_nota          text default null,
  p_invitado_por  uuid default null
)
returns table (id uuid, codigo_acceso text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin  uuid := public.admin_id_de(p_codigo);
  v_nuevo  uuid;
  v_cod    text := public.generar_codigo_acceso();
begin
  if p_invitado_por is not null
     and not exists (select 1 from public.miembros m where m.id = p_invitado_por) then
    raise exception 'El invitador elegido no existe.';
  end if;

  insert into public.miembros (codigo_acceso, nota_admin, invitado_por, estado_codigo)
  values (v_cod, nullif(btrim(coalesce(p_nota, '')), ''), p_invitado_por, 'activo')
  returning miembros.id into v_nuevo;

  -- en el registro va el nombre del invitador, no su identificador: el registro
  -- se lee, y un uuid no se lee
  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'crear_miembro', v_nuevo,
          jsonb_build_object(
            'codigo_acceso', v_cod,
            'invitado_por', (select coalesce(q.nombre_sektario, q.codigo_acceso)
                               from public.miembros q where q.id = p_invitado_por)));

  return query select v_nuevo, v_cod;
end;
$$;


-- ----------------------------------------------------------------------------
-- 3. dar de baja / reactivar
-- ----------------------------------------------------------------------------
-- No hay borrar. 'suspendido' es una baja temporal, 'revocado' es definitiva,
-- y en los dos casos la persona sigue en el árbol.
create or replace function public.admin_cambiar_estado(
  p_codigo      text,
  p_miembro_id  uuid,
  p_estado      text
)
returns table (estado_codigo text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin   uuid := public.admin_id_de(p_codigo);
  v_previo  text;
begin
  if p_estado not in ('activo', 'suspendido', 'revocado') then
    raise exception 'Estado inválido: %. Sólo activo, suspendido o revocado.', p_estado;
  end if;

  select m.estado_codigo into v_previo
    from public.miembros m where m.id = p_miembro_id;

  if v_previo is null then
    raise exception 'Ese miembro no existe.';
  end if;

  -- FISURA no es una persona, es la opción "no me trajo nadie en particular"
  -- del formulario. Si se la desactiva, esa opción desaparece del buscador.
  if v_previo = 'simbolico' then
    raise exception 'Ese miembro es simbólico y no se le cambia el estado.';
  end if;

  update public.miembros m set estado_codigo = p_estado where m.id = p_miembro_id;

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'cambiar_estado', p_miembro_id,
          jsonb_build_object('de', v_previo, 'a', p_estado));

  return query select p_estado;
end;
$$;


-- ----------------------------------------------------------------------------
-- 4. corregir los datos de alguien
-- ----------------------------------------------------------------------------
-- Cada parámetro en null significa "esto no lo toques". Para vaciar un campo
-- a propósito se manda una cadena vacía.
--
-- El invitador es aparte: p_cambiar_invitador dice si hay que tocarlo, así se
-- puede dejar a alguien sin invitador (mandando p_invitado_por en null con
-- p_cambiar_invitador en true).
--
-- Los círculos en el linaje los frena el trigger de la base, no esta función.
create or replace function public.admin_editar_miembro(
  p_codigo             text,
  p_miembro_id         uuid,
  p_nombre             text default null,
  p_apellido           text default null,
  p_email              text default null,
  p_telefono           text default null,
  p_nota               text default null,
  p_invitado_por       uuid default null,
  p_cambiar_invitador  boolean default false
)
returns table (id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := public.admin_id_de(p_codigo);
begin
  if not exists (select 1 from public.miembros m where m.id = p_miembro_id) then
    raise exception 'Ese miembro no existe.';
  end if;

  if p_cambiar_invitador and p_invitado_por is not null
     and not exists (select 1 from public.miembros m where m.id = p_invitado_por) then
    raise exception 'El invitador elegido no existe.';
  end if;

  update public.miembros m set
    nombre_real  = coalesce(nullif(btrim(p_nombre),   ''), m.nombre_real),
    apellido     = coalesce(nullif(btrim(p_apellido), ''), m.apellido),
    email        = coalesce(nullif(btrim(p_email),    ''), m.email),
    telefono     = coalesce(nullif(btrim(p_telefono), ''), m.telefono),
    nota_admin   = coalesce(nullif(btrim(p_nota),     ''), m.nota_admin),
    invitado_por = case when p_cambiar_invitador then p_invitado_por else m.invitado_por end
  where m.id = p_miembro_id;

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'editar_miembro', p_miembro_id,
          jsonb_strip_nulls(jsonb_build_object(
            'nombre',   nullif(btrim(coalesce(p_nombre, '')),   ''),
            'apellido', nullif(btrim(coalesce(p_apellido, '')), ''),
            'email',    case when nullif(btrim(coalesce(p_email, '')), '')    is not null then 'cambiado' end,
            'telefono', case when nullif(btrim(coalesce(p_telefono, '')), '') is not null then 'cambiado' end,
            'nota',     nullif(btrim(coalesce(p_nota, '')), ''),
            'invitador', case when p_cambiar_invitador then coalesce(
                            (select coalesce(q.nombre_sektario, q.codigo_acceso)
                               from public.miembros q where q.id = p_invitado_por),
                            'sin invitador') end
          )));

  return query select p_miembro_id;
end;
$$;


-- ----------------------------------------------------------------------------
-- 5. ver el registro de acciones
-- ----------------------------------------------------------------------------
create or replace function public.admin_acciones_recientes(
  p_codigo  text,
  p_limite  int default 100
)
returns table (
  creado_en        timestamptz,
  admin_nombre     text,
  accion           text,
  miembro_id       uuid,
  miembro_nombre   text,
  detalle          jsonb
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_id_de(p_codigo);

  return query
    select ac.creado_en, a.nombre, ac.accion, ac.miembro_id,
           coalesce(m.nombre_sektario, m.codigo_acceso), ac.detalle
      from public.admin_acciones ac
      join public.admins a on a.id = ac.admin_id
      left join public.miembros m on m.id = ac.miembro_id
     order by ac.creado_en desc
     limit greatest(1, least(coalesce(p_limite, 100), 500));
end;
$$;


-- ----------------------------------------------------------------------------
-- 6. permisos
-- ----------------------------------------------------------------------------
revoke all on function public.admin_crear_miembro(text, text, uuid)                              from public;
revoke all on function public.admin_cambiar_estado(text, uuid, text)                             from public;
revoke all on function public.admin_editar_miembro(text, uuid, text, text, text, text, text, uuid, boolean) from public;
revoke all on function public.admin_acciones_recientes(text, int)                                from public;

grant execute on function public.admin_crear_miembro(text, text, uuid)                              to anon, authenticated;
grant execute on function public.admin_cambiar_estado(text, uuid, text)                             to anon, authenticated;
grant execute on function public.admin_editar_miembro(text, uuid, text, text, text, text, text, uuid, boolean) to anon, authenticated;
grant execute on function public.admin_acciones_recientes(text, int)                                to anon, authenticated;
