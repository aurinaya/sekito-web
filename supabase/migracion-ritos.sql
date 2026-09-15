-- ============================================================================
-- SÉKITO — los ritos: declarar a qué fiestas viniste y quién da fe
-- ============================================================================
-- Cada miembro declara a qué fiestas vino y nombra DOS TESTIGOS. Cuando los dos
-- dan fe, ese rito queda ATESTIGUADO. Mientras tanto, espera.
--
-- La regla: solo puede dar fe quien ya está atestiguado en esa misma fiesta.
-- Se puede nombrar a alguien que todavía no lo está — el pedido queda
-- esperando a que esa persona se atestigüe, y recién ahí puede contestar.
--
-- Lo que hace que la rueda arranque: los tres fundadores quedan atestiguados
-- en las 10 fiestas ya pasadas. Desde ellos la red se expande sola. Sin eso,
-- nadie podría dar fe de nadie nunca: si para validar hay que estar validado
-- y nadie lo está, la puerta queda cerrada con la llave adentro.
--
-- LA SEKTA también puede ser testigo. De esa mitad dan fe los admins.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. validaciones pasa a guardar el PEDIDO, no solo la respuesta
-- ----------------------------------------------------------------------------
-- Antes una fila significaba "esta persona validó". Ahora se crea en el momento
-- en que alguien la nombra como testigo, y queda esperando:
--
--   validado_en vacío  -> la nombraron, todavía no contestó
--   validado_en con fecha -> dio fe
alter table public.validaciones alter column validado_en drop not null;
alter table public.validaciones alter column validado_en drop default;

-- quién de los admins dio fe por LA SEKTA (vacío en los testigos de carne y hueso)
alter table public.validaciones
  add column if not exists confirmado_por_admin uuid references public.admins(id);

-- nadie puede figurar dos veces como testigo del mismo rito
create unique index if not exists validaciones_una_por_testigo
  on public.validaciones (asistencia_id, validado_por);


-- ----------------------------------------------------------------------------
-- 2. ¿está atestiguado fulano en tal fiesta?
-- ----------------------------------------------------------------------------
-- La pregunta que se hace en todos lados. LA SEKTA nunca declara asistencias,
-- así que se la trata aparte: siempre puede ser testigo.
create or replace function public.esta_atestiguado(p_miembro uuid, p_fiesta uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.asistencias a
     where a.miembro_id = p_miembro
       and a.fiesta_id  = p_fiesta
       and a.estado     = 'confirmada'
  );
$$;

revoke all on function public.esta_atestiguado(uuid, uuid) from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 3. el miembro del código, o corta
-- ----------------------------------------------------------------------------
create or replace function public.miembro_de(p_codigo text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  select m.id into v_id
    from public.miembros m
   where m.codigo_acceso = upper(btrim(coalesce(p_codigo, '')))
     and m.estado_codigo = 'activo';

  if v_id is null then
    raise exception 'codigo_invalido' using errcode = 'insufficient_privilege';
  end if;

  return v_id;
end;
$$;

revoke all on function public.miembro_de(text) from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 4. mis ritos
-- ----------------------------------------------------------------------------
-- Todas las fiestas ya pasadas, con mi estado en cada una. Las que todavía no
-- pasaron no aparecen: no se puede declarar que fuiste a algo que no ocurrió.
create or replace function public.mis_ritos(p_codigo text)
returns table (
  fiesta_id  uuid,
  nombre     text,
  fecha      timestamptz,
  lugar      text,
  estado     text,      -- 'atestiguado' | 'esperando' | 'sin_declarar'
  testigos   jsonb
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  return query
    select
      f.id, f.nombre, f.fecha, f.lugar,
      case
        when a.id is null                then 'sin_declarar'
        when a.estado = 'confirmada'     then 'atestiguado'
        else                                  'esperando'
      end,
      coalesce((
        select jsonb_agg(jsonb_build_object(
                 'validacion_id', v.id,
                 'nombre',        t.nombre_sektario,
                 'dio_fe',        (v.validado_en is not null),
                 'es_sekta',      (t.estado_codigo = 'simbolico')
               ) order by t.nombre_sektario)
          from public.validaciones v
          join public.miembros t on t.id = v.validado_por
         where v.asistencia_id = a.id
      ), '[]'::jsonb)
    from public.fiestas f
    left join public.asistencias a
           on a.fiesta_id = f.id and a.miembro_id = v_yo
   where f.fecha <= now()
   order by f.fecha desc;
end;
$$;


-- ----------------------------------------------------------------------------
-- 5. buscar testigos para una fiesta
-- ----------------------------------------------------------------------------
-- Devuelve gente activa más LA SEKTA, diciendo de cada uno si ya está
-- atestiguado en esa fiesta. Los que sí pueden contestar enseguida; los que no,
-- quedan esperando. No me devuelve a mí mismo.
create or replace function public.buscar_testigos(
  p_codigo text,
  p_fiesta uuid,
  p_query  text
)
returns table (
  id            uuid,
  nombre        text,
  nombre_real   text,
  puede_ya      boolean,
  es_sekta      boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  if length(btrim(coalesce(p_query, ''))) < 3 then
    return;
  end if;

  return query
    select m.id, m.nombre_sektario, m.nombre_real,
           (m.estado_codigo = 'simbolico' or public.esta_atestiguado(m.id, p_fiesta)),
           (m.estado_codigo = 'simbolico')
      from public.miembros m
     where m.id <> v_yo
       and m.estado_codigo in ('activo', 'simbolico')
       -- los paréntesis importan: sin ellos el "or" se lleva puesta la
       -- condición de búsqueda y devuelve a todo el mundo
       and (m.nombre_real is not null or m.estado_codigo = 'simbolico')
       and (
             m.nombre_sektario ilike '%' || btrim(p_query) || '%'
          or m.nombre_real     ilike '%' || btrim(p_query) || '%'
          or m.apellido        ilike '%' || btrim(p_query) || '%'
           )
     order by m.nombre_real nulls last
     limit 8;
end;
$$;


-- ----------------------------------------------------------------------------
-- 6. declarar un rito
-- ----------------------------------------------------------------------------
create or replace function public.declarar_rito(
  p_codigo   text,
  p_fiesta   uuid,
  p_testigo1 uuid,
  p_testigo2 uuid
)
returns table (estado text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo        uuid := public.miembro_de(p_codigo);
  v_asistencia uuid;
  v_fecha     timestamptz;
begin
  if p_testigo1 is null or p_testigo2 is null then
    raise exception 'faltan_testigos';
  end if;
  if p_testigo1 = p_testigo2 then
    raise exception 'testigos_repetidos';
  end if;
  if p_testigo1 = v_yo or p_testigo2 = v_yo then
    raise exception 'no_podes_ser_tu_testigo';
  end if;

  select f.fecha into v_fecha from public.fiestas f where f.id = p_fiesta;
  if v_fecha is null then
    raise exception 'fiesta_no_existe';
  end if;
  if v_fecha > now() then
    raise exception 'fiesta_futura';
  end if;

  if not exists (select 1 from public.miembros m
                  where m.id in (p_testigo1, p_testigo2)
                    and m.estado_codigo in ('activo','simbolico')
                 having count(*) = 2) then
    raise exception 'testigo_invalido';
  end if;

  insert into public.asistencias (miembro_id, fiesta_id, estado)
  values (v_yo, p_fiesta, 'pendiente')
  returning asistencias.id into v_asistencia;

  insert into public.validaciones (asistencia_id, validado_por) values
    (v_asistencia, p_testigo1),
    (v_asistencia, p_testigo2);

  return query select 'esperando'::text;
exception
  when unique_violation then
    raise exception 'ya_declaraste_esta_fiesta';
end;
$$;


-- ----------------------------------------------------------------------------
-- 7. cambiar un testigo que no contestó
-- ----------------------------------------------------------------------------
-- No existe rechazar. Si alguien no contesta, se lo cambia. Al que ya dio fe
-- no se lo toca.
-- Apunta a la validación y no al testigo viejo: la validación ES la fila que
-- se está cambiando, y así no hace falta ir a buscar de quién era.
drop function if exists public.cambiar_testigo(text, uuid, uuid, uuid);

create or replace function public.cambiar_testigo(
  p_codigo     text,
  p_validacion uuid,
  p_nuevo      uuid
)
returns table (ok boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo         uuid := public.miembro_de(p_codigo);
  v_asistencia uuid;
begin
  -- que la validación sea de un rito MÍO y que el testigo no haya contestado
  select v.asistencia_id into v_asistencia
    from public.validaciones v
    join public.asistencias a on a.id = v.asistencia_id
   where v.id = p_validacion
     and a.miembro_id = v_yo
     and v.validado_en is null;

  if v_asistencia is null then
    raise exception 'ese_testigo_ya_dio_fe';
  end if;

  if p_nuevo = v_yo then
    raise exception 'no_podes_ser_tu_testigo';
  end if;

  if not exists (select 1 from public.miembros m
                  where m.id = p_nuevo and m.estado_codigo in ('activo','simbolico')) then
    raise exception 'testigo_invalido';
  end if;

  if exists (select 1 from public.validaciones v
              where v.asistencia_id = v_asistencia and v.validado_por = p_nuevo) then
    raise exception 'ya_es_testigo';
  end if;

  update public.validaciones v
     set validado_por = p_nuevo
   where v.id = p_validacion;

  return query select true;
end;
$$;


-- ----------------------------------------------------------------------------
-- 8. lo que me piden a mí
-- ----------------------------------------------------------------------------
-- puedo_ya dice si ya estoy atestiguado en esa fiesta. Si no, el pedido se ve
-- igual, pero todavía no puedo contestarlo.
create or replace function public.mis_pedidos(p_codigo text)
returns table (
  validacion_id  uuid,
  quien          text,
  fiesta         text,
  fecha          timestamptz,
  puedo_ya       boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  return query
    select v.id, m.nombre_sektario, f.nombre, f.fecha,
           public.esta_atestiguado(v_yo, f.id)
      from public.validaciones v
      join public.asistencias a on a.id = v.asistencia_id
      join public.miembros    m on m.id = a.miembro_id
      join public.fiestas     f on f.id = a.fiesta_id
     where v.validado_por = v_yo
       and v.validado_en is null
     order by f.fecha desc;
end;
$$;


-- ----------------------------------------------------------------------------
-- 9. dar fe
-- ----------------------------------------------------------------------------
create or replace function public.dar_fe(p_codigo text, p_validacion uuid)
returns table (rito_completo boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo         uuid := public.miembro_de(p_codigo);
  v_asistencia uuid;
  v_fiesta     uuid;
  v_faltan     int;
begin
  select v.asistencia_id, a.fiesta_id into v_asistencia, v_fiesta
    from public.validaciones v
    join public.asistencias a on a.id = v.asistencia_id
   where v.id = p_validacion
     and v.validado_por = v_yo
     and v.validado_en is null;

  if v_asistencia is null then
    raise exception 'no_te_toca';
  end if;

  if not public.esta_atestiguado(v_yo, v_fiesta) then
    raise exception 'todavia_no_podes';
  end if;

  update public.validaciones v set validado_en = now() where v.id = p_validacion;

  -- si ya no falta ninguno, el rito queda atestiguado
  select count(*) into v_faltan
    from public.validaciones v
   where v.asistencia_id = v_asistencia and v.validado_en is null;

  if v_faltan = 0 then
    update public.asistencias a set estado = 'confirmada' where a.id = v_asistencia;
  end if;

  return query select (v_faltan = 0);
end;
$$;


-- ----------------------------------------------------------------------------
-- 10. los pedidos que esperan a LA SEKTA (panel)
-- ----------------------------------------------------------------------------
create or replace function public.admin_pedidos_sekta(p_codigo text)
returns table (
  validacion_id uuid,
  quien         text,
  quien_real    text,
  fiesta        text,
  fecha         timestamptz,
  pedido_en     timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_id_de(p_codigo);

  return query
    select v.id, m.nombre_sektario, m.nombre_real, f.nombre, f.fecha, a.creado_en
      from public.validaciones v
      join public.miembros    s on s.id = v.validado_por and s.estado_codigo = 'simbolico'
      join public.asistencias a on a.id = v.asistencia_id
      join public.miembros    m on m.id = a.miembro_id
      join public.fiestas     f on f.id = a.fiesta_id
     where v.validado_en is null
     order by a.creado_en;
end;
$$;


create or replace function public.admin_dar_fe_sekta(p_codigo text, p_validacion uuid)
returns table (rito_completo boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin      uuid := public.admin_id_de(p_codigo);
  v_asistencia uuid;
  v_faltan     int;
begin
  select v.asistencia_id into v_asistencia
    from public.validaciones v
    join public.miembros s on s.id = v.validado_por and s.estado_codigo = 'simbolico'
   where v.id = p_validacion
     and v.validado_en is null;

  if v_asistencia is null then
    raise exception 'ese_pedido_no_es_de_la_sekta';
  end if;

  update public.validaciones v
     set validado_en = now(), confirmado_por_admin = v_admin
   where v.id = p_validacion;

  select count(*) into v_faltan
    from public.validaciones v
   where v.asistencia_id = v_asistencia and v.validado_en is null;

  if v_faltan = 0 then
    update public.asistencias a set estado = 'confirmada' where a.id = v_asistencia;
  end if;

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  select v_admin, 'dar_fe_sekta', a.miembro_id,
         jsonb_build_object('fiesta', f.nombre)
    from public.asistencias a join public.fiestas f on f.id = a.fiesta_id
   where a.id = v_asistencia;

  return query select (v_faltan = 0);
end;
$$;


-- ----------------------------------------------------------------------------
-- 11. la siembra: los tres fundadores, atestiguados en todo lo ya pasado
-- ----------------------------------------------------------------------------
-- Sin esto la rueda no arranca. No lleva testigos: es un hecho que asentamos,
-- no algo que alguien tenga que confirmar.
insert into public.asistencias (miembro_id, fiesta_id, estado)
select m.id, f.id, 'confirmada'
  from public.miembros m
  cross join public.fiestas f
 where m.es_fundador = true
   and f.fecha <= now()
on conflict (miembro_id, fiesta_id) do nothing;


-- ----------------------------------------------------------------------------
-- 12. permisos
-- ----------------------------------------------------------------------------
revoke all on function public.mis_ritos(text)                          from public;
revoke all on function public.buscar_testigos(text, uuid, text)        from public;
revoke all on function public.declarar_rito(text, uuid, uuid, uuid)    from public;
revoke all on function public.cambiar_testigo(text, uuid, uuid)        from public;
revoke all on function public.mis_pedidos(text)                        from public;
revoke all on function public.dar_fe(text, uuid)                       from public;
revoke all on function public.admin_pedidos_sekta(text)                from public;
revoke all on function public.admin_dar_fe_sekta(text, uuid)           from public;

grant execute on function public.mis_ritos(text)                         to anon, authenticated;
grant execute on function public.buscar_testigos(text, uuid, text)       to anon, authenticated;
grant execute on function public.declarar_rito(text, uuid, uuid, uuid)   to anon, authenticated;
grant execute on function public.cambiar_testigo(text, uuid, uuid)       to anon, authenticated;
grant execute on function public.mis_pedidos(text)                       to anon, authenticated;
grant execute on function public.dar_fe(text, uuid)                      to anon, authenticated;
grant execute on function public.admin_pedidos_sekta(text)               to anon, authenticated;
grant execute on function public.admin_dar_fe_sekta(text, uuid)          to anon, authenticated;
