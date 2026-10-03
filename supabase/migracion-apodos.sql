-- ============================================================================
-- SÉKITO — cómo te dicen
-- ============================================================================
-- Cada uno puede decir cómo quiere que lo llamen. Es opcional: si no lo dice,
-- se lo llama por su nombre, como hasta ahora.
--
-- El apodo se ve donde la gente se ve entre sí: el título del perfil,
-- devotxs y la ficha, la rama, los pedidos de fe, los susurros y los mails
-- tipo "Luchi te dio una entrada". El buscador lo encuentra.
-- El nombre real queda para lo que lo necesita: el panel y Passline, que
-- emite el QR a nombre de la persona.
--
-- Una sola función decide qué nombre mostrar (como_le_dicen), y todas las
-- demás la usan. Mientras nadie tenga apodo, devuelve exactamente lo mismo
-- que antes: esta migración no cambia nada visible hasta que alguien elige
-- el suyo.
--
-- Las funciones que sólo cambian en cómo eligen el nombre se bajaron de la
-- base y se tocaron en esa línea y nada más.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. la columna
-- ----------------------------------------------------------------------------
alter table public.miembros add column if not exists apodo text;

alter table public.miembros drop constraint if exists apodo_corto;
alter table public.miembros add  constraint apodo_corto
  check (apodo is null or char_length(apodo) between 1 and 24);

comment on column public.miembros.apodo is
  'Cómo quiere que lo llamen. Opcional. Lo muestra como_le_dicen(); el nombre real queda para el panel y Passline.';


-- ----------------------------------------------------------------------------
-- 2. qué nombre se muestra
-- ----------------------------------------------------------------------------
-- La misma regla que los nombres: si alguien escribe LUCHI, se muestra Luchi.
-- No le gritamos a nadie.
create or replace function public.como_le_dicen(p_apodo text, p_nombre text)
returns text
language sql
immutable
set search_path = public
as $$
  select public.nombre_lindo(coalesce(nullif(btrim(coalesce(p_apodo, '')), ''), p_nombre));
$$;

revoke all on function public.como_le_dicen(text, text) from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 3. cambiar el propio apodo, desde el perfil
-- ----------------------------------------------------------------------------
-- Para los que ya estaban adentro cuando apareció la pregunta, y para quien
-- quiera cambiarlo. Vacío lo borra: vuelve a llamarse por su nombre.
create or replace function public.cambiar_apodo(p_codigo text, p_apodo text)
returns table (apodo text, se_ve text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo    uuid := public.miembro_de(p_codigo);
  v_apodo text := nullif(btrim(coalesce(p_apodo, '')), '');
begin
  if v_apodo is not null and char_length(v_apodo) > 24 then
    raise exception 'apodo_largo';
  end if;

  update public.miembros m set apodo = v_apodo where m.id = v_yo;

  return query
    select m.apodo, public.como_le_dicen(m.apodo, m.nombre_real)
      from public.miembros m where m.id = v_yo;
end;
$$;

grant execute on function public.cambiar_apodo(text, text) to anon, authenticated;


-- ----------------------------------------------------------------------------
-- 4. entrar: ahora también devuelve el apodo
-- ----------------------------------------------------------------------------
-- Cambia la forma de lo que devuelve, así que hay que soltarla y volver a
-- crearla. Lo de antes sigue igual: el sitio publicado lee los campos por su
-- nombre y no se entera de que hay uno más.
drop function if exists public.validar_codigo(text);

create function public.validar_codigo(p_codigo text)
returns table (nombre_sektario text, nombre_real text, pantalla text,
               fecha_ingreso timestamptz, es_fundador boolean,
               invitado_por_nombre text, registro_completo boolean, apodo text)
language sql
security definer
set search_path = public
as $$
  select
    m.nombre_sektario,
    m.nombre_real,
    m.pantalla,
    m.fecha_ingreso,
    m.es_fundador,
    quien.nombre_sektario           as invitado_por_nombre,
    (m.nombre_real is not null)     as registro_completo,
    m.apodo
  from public.miembros m
  left join public.miembros quien on quien.id = m.invitado_por
  where m.codigo_acceso = upper(btrim(p_codigo))
    and m.estado_codigo = 'activo'
  limit 1;
$$;

grant execute on function public.validar_codigo(text) to anon, authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 5. registrarse: el apodo entra con el resto de los datos
-- ----------------------------------------------------------------------------
-- p_apodo va al final y con valor por defecto: el sitio publicado, que no lo
-- manda, sigue registrando igual.
drop function if exists public.completar_registro(text, text, text, text, text, uuid, text);

create function public.completar_registro(
  p_codigo text, p_nombre text, p_apellido text, p_email text, p_telefono text,
  p_invitado_por uuid, p_como_llegaste text, p_apodo text default null
)
returns table (nombre_sektario text, nombre_real text, pantalla text,
               fecha_ingreso timestamptz, es_fundador boolean,
               invitado_por_nombre text, registro_completo boolean, apodo text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id         uuid;
  v_sektario   text;
  v_fundador   boolean;
  v_ya         boolean;
  v_cand       text;
  v_apodo      text := nullif(btrim(coalesce(p_apodo, '')), '');
  i            int;
begin
  select m.id, m.nombre_sektario, m.es_fundador, (m.nombre_real is not null)
    into v_id, v_sektario, v_fundador, v_ya
    from public.miembros m
   where m.codigo_acceso = upper(btrim(p_codigo))
     and m.estado_codigo = 'activo';

  if v_id is null then
    raise exception 'codigo_invalido';
  end if;

  if v_ya then
    raise exception 'registro_ya_completo';
  end if;

  if btrim(coalesce(p_nombre, ''))   = '' or btrim(coalesce(p_apellido, '')) = ''
  or btrim(coalesce(p_email, ''))    = '' or btrim(coalesce(p_telefono, '')) = '' then
    raise exception 'faltan_datos';
  end if;

  if v_apodo is not null and char_length(v_apodo) > 24 then
    raise exception 'apodo_largo';
  end if;

  -- a los fundadores no los trajo nadie; al resto sí
  if not v_fundador and p_invitado_por is null then
    raise exception 'falta_invitado_por';
  end if;

  for i in 1..50 loop
    begin
      if v_sektario is null then
        v_cand := public.generar_nombre_sektario(p_nombre, p_apellido);
      else
        v_cand := v_sektario;
      end if;

      update public.miembros m set
        nombre_real     = btrim(p_nombre),
        apellido        = btrim(p_apellido),
        email           = btrim(p_email),
        telefono        = btrim(p_telefono),
        invitado_por    = p_invitado_por,
        como_llegaste   = nullif(btrim(coalesce(p_como_llegaste, '')), ''),
        apodo           = v_apodo,
        nombre_sektario = v_cand
      where m.id = v_id;

      exit;  -- salió bien
    exception when unique_violation then
      -- si ya tenía nombre, la colisión no es del número: que salte
      if v_sektario is not null then
        raise;
      end if;
      -- si no, el loop vuelve a sortear
    end;
  end loop;

  return query
    select m.nombre_sektario,
           m.nombre_real,
           m.pantalla,
           m.fecha_ingreso,
           m.es_fundador,
           quien.nombre_sektario,
           true,
           m.apodo
      from public.miembros m
      left join public.miembros quien on quien.id = m.invitado_por
     where m.id = v_id;
end;
$$;

grant execute on function public.completar_registro(text, text, text, text, text, uuid, text, text)
  to anon, authenticated, service_role;


drop function if exists public.registrar_con_invitacion(text, text, text, text, text, text);

create function public.registrar_con_invitacion(
  p_invitacion text, p_nombre text, p_apellido text, p_email text, p_telefono text,
  p_como_llegaste text default null, p_apodo text default null
)
returns table (codigo_acceso text, nombre_sektario text, nombre_real text, pantalla text,
               fecha_ingreso timestamptz, es_fundador boolean,
               invitado_por_nombre text, registro_completo boolean, apodo text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inv       uuid;
  v_referente uuid;
  v_estado    record;
  v_nuevo     uuid;
  v_cod       text;
  v_apodo     text := nullif(btrim(coalesce(p_apodo, '')), '');
  v_i         int;
begin
  if nullif(btrim(coalesce(p_nombre,   '')), '') is null
  or nullif(btrim(coalesce(p_apellido, '')), '') is null
  or nullif(btrim(coalesce(p_email,    '')), '') is null
  or nullif(btrim(coalesce(p_telefono, '')), '') is null then
    raise exception 'faltan_datos';
  end if;

  if v_apodo is not null and char_length(v_apodo) > 24 then
    raise exception 'apodo_largo';
  end if;

  -- buscar y gastar, todo junto
  update public.invitaciones i
     set usada = true, usada_en = now()
   where i.codigo   = upper(btrim(coalesce(p_invitacion, '')))
     and i.usada    = false
     and i.revocada = false
     and i.vence_en > now()
  returning i.id, i.generada_por into v_inv, v_referente;

  if v_inv is null then
    -- no se pudo gastar: averiguar por qué, para poder explicarlo
    select i.usada, i.revocada, (i.vence_en <= now()) as vencida
      into v_estado
      from public.invitaciones i
     where i.codigo = upper(btrim(coalesce(p_invitacion, '')));

    if not found             then raise exception 'invitacion_no_existe';
    elsif v_estado.usada     then raise exception 'invitacion_ya_usada';
    elsif v_estado.revocada  then raise exception 'invitacion_revocada';
    elsif v_estado.vencida   then raise exception 'invitacion_vencida';
    else                          raise exception 'invitacion_no_existe';
    end if;
  end if;

  -- el miembro nuevo, con su código permanente
  for v_i in 1 .. 200 loop
    begin
      v_cod := public.generar_codigo_acceso();

      insert into public.miembros
        (codigo_acceso, nombre_real, apellido, email, telefono,
         como_llegaste, invitado_por, estado_codigo, apodo)
      values
        (v_cod, btrim(p_nombre), btrim(p_apellido), btrim(p_email),
         btrim(p_telefono), nullif(btrim(coalesce(p_como_llegaste, '')), ''),
         v_referente, 'activo', v_apodo)
      returning miembros.id into v_nuevo;

      exit;
    exception when unique_violation then
      -- entre el "está libre" y el insert se lo quedó otro registro
      v_nuevo := null;
    end;
  end loop;

  if v_nuevo is null then
    raise exception 'no_se_pudo_generar';
  end if;

  -- el nombre sektario, con su propio reintento por si el número ya existía
  for v_i in 1 .. 25 loop
    begin
      update public.miembros m
         set nombre_sektario = public.generar_nombre_sektario(p_nombre, p_apellido)
       where m.id = v_nuevo;
      exit;
    exception when unique_violation then
      null;
    end;
  end loop;

  update public.invitaciones i set usada_por = v_nuevo where i.id = v_inv;

  return query
    select m.codigo_acceso, m.nombre_sektario, m.nombre_real, m.pantalla,
           m.fecha_ingreso, m.es_fundador,
           quien.nombre_sektario,
           (m.nombre_real is not null),
           m.apodo
      from public.miembros m
      left join public.miembros quien on quien.id = m.invitado_por
     where m.id = v_nuevo;
end;
$$;

grant execute on function public.registrar_con_invitacion(text, text, text, text, text, text, text)
  to anon, authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 6. "¿quién te trajo?": también lo encuentra por el apodo, y lo devuelve
-- ----------------------------------------------------------------------------
drop function if exists public.buscar_miembros(p_codigo text, p_query text);
create function public.buscar_miembros(p_codigo text, p_query text)
 RETURNS TABLE(id uuid, nombre_sektario text, nombre_real text, apellido text, apodo text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select m.id, m.nombre_sektario, m.nombre_real, m.apellido, m.apodo
    from public.miembros m
   where exists (
           select 1 from public.miembros c
            where c.codigo_acceso = upper(btrim(p_codigo))
              and c.estado_codigo = 'activo'
         )
     and length(btrim(coalesce(p_query, ''))) >= 3
     -- solo miembros vigentes y LA SEKTA: un código suspendido o revocado no
     -- tiene por qué seguir ofreciéndose como "quién te trajo"
     and m.estado_codigo in ('activo', 'simbolico')
     and (
           m.nombre_sektario ilike '%' || btrim(p_query) || '%'
        or m.nombre_real     ilike '%' || btrim(p_query) || '%'
        or m.apellido        ilike '%' || btrim(p_query) || '%'
        or m.apodo           ilike '%' || btrim(p_query) || '%'
         )
   order by m.nombre_real nulls last, m.nombre_sektario
   limit 8;
$function$;

grant execute on function public.buscar_miembros(p_codigo text, p_query text) to anon, authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 7. todo lo demás que muestra a alguien
-- ----------------------------------------------------------------------------

-- buscar_en_el_sekito: el nombre que muestra pasa a ser el apodo, si hay
create or replace function public.buscar_en_el_sekito(p_codigo text, p_query text)
 RETURNS TABLE(sektario text, nombre text, pantalla text, es_sekta boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_yo uuid := public.miembro_de(p_codigo);
  v_q  text := btrim(coalesce(p_query, ''));
begin
  if length(v_q) < 1 then
    return;
  end if;

  return query
    select m.nombre_sektario,
           public.como_le_dicen(m.apodo, m.nombre_real),
           m.pantalla,
           (m.estado_codigo = 'simbolico')
      from public.miembros m
     where m.estado_codigo in ('activo', 'simbolico')
       and m.nombre_sektario is not null
       and (
             m.nombre_sektario ilike '%' || v_q || '%'
          or m.nombre_real     ilike '%' || v_q || '%'
          or m.apellido        ilike '%' || v_q || '%'
          or m.apodo           ilike '%' || v_q || '%'
           )
     order by
       (m.nombre_sektario ilike v_q || '%' or m.nombre_real ilike v_q || '%') desc,
       m.nombre_real nulls last
     limit 8;

  perform v_yo;
end;
$function$;

-- buscar_testigos: el nombre que muestra pasa a ser el apodo, si hay
create or replace function public.buscar_testigos(p_codigo text, p_fiesta uuid, p_query text)
 RETURNS TABLE(id uuid, nombre text, nombre_real text, puede_ya boolean, es_sekta boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_yo uuid := public.miembro_de(p_codigo);
  v_q  text := btrim(coalesce(p_query, ''));
begin
  if length(v_q) < 1 then
    return;
  end if;

  return query
    select m.id, m.nombre_sektario, public.como_le_dicen(m.apodo, m.nombre_real),
           (m.estado_codigo = 'simbolico' or public.esta_atestiguado(m.id, p_fiesta)),
           (m.estado_codigo = 'simbolico')
      from public.miembros m
     where m.id <> v_yo
       and m.estado_codigo in ('activo', 'simbolico')
       -- los paréntesis importan: sin ellos el "or" se lleva puesta la
       -- condición de búsqueda y devuelve a todo el mundo
       and (m.nombre_real is not null or m.estado_codigo = 'simbolico')
       and (
             m.nombre_sektario ilike '%' || v_q || '%'
          or m.nombre_real     ilike '%' || v_q || '%'
          or m.apellido        ilike '%' || v_q || '%'
          or m.apodo           ilike '%' || v_q || '%'
           )
     order by
       -- con una sola letra esto es lo que hace la diferencia: primero los
       -- que empiezan así, después el resto
       (m.nombre_real ilike v_q || '%' or m.nombre_sektario ilike v_q || '%') desc,
       m.nombre_real nulls last
     limit 8;
end;
$function$;

-- buscar_para_entrada: el nombre que muestra pasa a ser el apodo, si hay
create or replace function public.buscar_para_entrada(p_codigo text, p_query text)
 RETURNS TABLE(id uuid, sektario text, nombre text, ya_tiene boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_yo uuid := public.miembro_de(p_codigo);
  v_q  text := btrim(coalesce(p_query, ''));
begin
  if length(v_q) < 1 then return; end if;

  return query
    select m.id, m.nombre_sektario, public.como_le_dicen(m.apodo, m.nombre_real),
           exists (select 1 from public.entradas e
                    where e.duenio = m.id and e.evento = 'seki7')
      from public.miembros m
     where m.estado_codigo = 'activo'
       and m.nombre_real is not null
       and (
             m.nombre_sektario ilike '%' || v_q || '%'
          or m.nombre_real     ilike '%' || v_q || '%'
          or m.apellido        ilike '%' || v_q || '%'
          or m.apodo           ilike '%' || v_q || '%'
           )
     order by
       (m.nombre_real ilike v_q || '%' or m.nombre_sektario ilike v_q || '%') desc,
       m.nombre_real nulls last
     limit 8;
end;
$function$;

-- ficha_del_sekito: el nombre que muestra pasa a ser el apodo, si hay
create or replace function public.ficha_del_sekito(p_codigo text, p_sektario text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_yo  uuid := public.miembro_de(p_codigo);
  v_id  uuid;
  v_res jsonb;
begin
  select m.id into v_id
    from public.miembros m
   where m.nombre_sektario = btrim(coalesce(p_sektario, ''))
     and m.estado_codigo in ('activo', 'simbolico');

  if v_id is null then
    raise exception 'no_esta_en_el_padron';
  end if;

  with recursive rama as (
    select m.id, 1 as profundidad
      from public.miembros m
     where m.invitado_por = v_id
       and m.estado_codigo in ('activo', 'simbolico')

    union all

    select h.id, r.profundidad + 1
      from public.miembros h
      join rama r on h.invitado_por = r.id
     where r.profundidad < 20   -- red de seguridad; los ciclos los frena un trigger
       and h.estado_codigo in ('activo', 'simbolico')
  )
  select jsonb_build_object(
    'sektario',  m.nombre_sektario,
    'nombre',    public.como_le_dicen(m.apodo, m.nombre_real),
    'pantalla',  m.pantalla,
    'fundador',  m.es_fundador,
    'es_sekta',  (m.estado_codigo = 'simbolico'),
    'es_vos',    (m.id = v_yo),
    'desde',     least(
                   m.fecha_ingreso,
                   (select min(f.fecha)
                      from public.asistencias a
                      join public.fiestas f on f.id = a.fiesta_id
                     where a.miembro_id = m.id and a.estado = 'confirmada')
                 ),
    'guia',      (select jsonb_build_object(
                           'sektario', q.nombre_sektario,
                           'nombre',   public.como_le_dicen(q.apodo, q.nombre_real))
                    from public.miembros q where q.id = m.invitado_por),
    'directos',  (select count(*) from rama where profundidad = 1),
    'total',     (select count(*) from rama),
    'ritos',     coalesce((
                   select jsonb_agg(jsonb_build_object(
                            'nombre', f.nombre,
                            'fecha',  f.fecha
                          ) order by f.fecha desc)
                     from public.asistencias a
                     join public.fiestas f on f.id = a.fiesta_id
                    where a.miembro_id = m.id
                      and a.estado = 'confirmada'
                 ), '[]'::jsonb),
    'susurro',   case
                   when m.id = v_yo or m.estado_codigo = 'simbolico' then null
                   else coalesce(
                     (select jsonb_build_object(
                               'mio',   true,
                               'texto', s.texto,
                               'desde', s.creado_en,
                               'dias',  greatest(0, 7 - floor(extract(epoch from (now() - s.creado_en)) / 86400)::int))
                        from public.susurros s
                       where s.de = v_yo and s.para = m.id
                         and s.creado_en > now() - interval '7 days'
                       order by s.creado_en desc
                       limit 1),
                     jsonb_build_object('mio', false))
                 end
  ) into v_res
  from public.miembros m
 where m.id = v_id;

  return v_res;
end;
$function$;

-- mi_rama: el nombre que muestra pasa a ser el apodo, si hay
create or replace function public.mi_rama(p_codigo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_yo  uuid := public.miembro_de(p_codigo);
  v_res jsonb;
begin
  with recursive rama as (
    select m.id, m.invitado_por as de, m.nombre_sektario, m.nombre_real, m.apodo, 1 as profundidad,
           array[coalesce(m.nombre_sektario, m.codigo_acceso)] as camino
      from public.miembros m
     where m.invitado_por = v_yo

    union all

    select h.id, h.invitado_por, h.nombre_sektario, h.nombre_real, h.apodo, r.profundidad + 1,
           r.camino || coalesce(h.nombre_sektario, h.codigo_acceso)
      from public.miembros h
      join rama r on h.invitado_por = r.id
     where r.profundidad < 20
  )
  select jsonb_build_object(
    'guia',      (select q.nombre_sektario
                    from public.miembros m
                    left join public.miembros q on q.id = m.invitado_por
                   where m.id = v_yo),
    'fundador',  (select m.es_fundador from public.miembros m where m.id = v_yo),
    'directos',  (select count(*) from rama where profundidad = 1),
    'total',     (select count(*) from rama),
    'rama',      coalesce((
                   select jsonb_agg(jsonb_build_object(
                            'id',          r.id,
                            'de',          r.de,
                            'nombre',      r.nombre_sektario,
                            'nombre_real', public.como_le_dicen(r.apodo, r.nombre_real),
                            'profundidad', r.profundidad
                          ) order by r.camino)
                     from rama r
                 ), '[]'::jsonb)
  ) into v_res;

  return v_res;
end;
$function$;

-- mis_pedidos: el nombre que muestra pasa a ser el apodo, si hay
create or replace function public.mis_pedidos(p_codigo text)
 RETURNS TABLE(validacion_id uuid, quien text, quien_nombre text, fiesta text, fecha timestamp with time zone, puedo_ya boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  return query
    select v.id, m.nombre_sektario, public.como_le_dicen(m.apodo, m.nombre_real),
           f.nombre, f.fecha,
           public.esta_atestiguado(v_yo, f.id)
      from public.validaciones v
      join public.asistencias a on a.id = v.asistencia_id
      join public.miembros    m on m.id = a.miembro_id
      join public.fiestas     f on f.id = a.fiesta_id
     where v.validado_por = v_yo
       and v.validado_en    is null
       and v.no_recuerda_en is null
     order by f.fecha desc;
end;
$function$;

-- mis_ritos: el nombre que muestra pasa a ser el apodo, si hay
create or replace function public.mis_ritos(p_codigo text)
 RETURNS TABLE(fiesta_id uuid, nombre text, fecha timestamp with time zone, lugar text, estado text, testigos jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
                 'nombre_real',   public.como_le_dicen(t.apodo, t.nombre_real),
                 'dio_fe',        (v.validado_en is not null),
                 'no_recuerda',   (v.no_recuerda_en is not null),
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
$function$;

-- mis_susurros: el nombre que muestra pasa a ser el apodo, si hay
create or replace function public.mis_susurros(p_codigo text)
 RETURNS TABLE(id uuid, mio boolean, sektario text, nombre text, texto text, creado_en timestamp with time zone, es_nuevo boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  return query
    select s.id, false, m.nombre_sektario, public.como_le_dicen(m.apodo, m.nombre_real),
           s.texto, s.creado_en, (s.leido_en is null)
      from public.susurros s
      join public.miembros m on m.id = s.de
     where s.para = v_yo

    union all

    -- los que dejé yo: "es_nuevo" no aplica y va en false. El que los mandó
    -- no tiene que enterarse de si los leyeron, ni siquiera cuando es uno mismo.
    select s.id, true, m.nombre_sektario, public.como_le_dicen(m.apodo, m.nombre_real),
           s.texto, s.creado_en, false
      from public.susurros s
      join public.miembros m on m.id = s.para
     where s.de = v_yo

     order by 2, 6 desc;   -- primero los que me dejaron, y dentro de cada lado lo más nuevo

  update public.susurros s
     set leido_en = now()
   where s.para = v_yo and s.leido_en is null;
end;
$function$;

-- mis_entradas: el nombre que muestra pasa a ser el apodo, si hay
create or replace function public.mis_entradas(p_codigo text)
 RETURNS TABLE(entrada_id uuid, tipo text, soy_tenedor boolean, soy_duenio boolean, duenio_nombre text, quien_me_la_dio text, estado text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  return query
    select e.id,
           e.tipo,
           e.tenedor = v_yo,
           e.duenio is not distinct from v_yo,
           public.como_le_dicen(d.apodo, d.nombre_real),
           case when e.tenedor = v_yo and p.id is not null
                then public.como_le_dicen(p.apodo, p.nombre_real) end,
           case
             when e.duenio is null                        then 'sin_asignar'
             when e.enviada_en is not null                then 'enviada'
             when c.id is null                            then 'por_enviar'
             when c.estado = 'confirmada'                 then 'por_enviar'
             else 'esperando'
           end
      from public.entradas e
      left join public.compras  c on c.id = e.compra_id
      left join public.miembros d on d.id = e.duenio
      left join public.miembros p on p.id = e.pasada_por
     where (e.tenedor = v_yo or e.duenio = v_yo)
       and (c.id is null or c.estado <> 'rechazada')
     order by (e.duenio is null) desc, e.creada_en;
end;
$function$;

-- avisar_ingreso: el nombre que muestra pasa a ser el apodo, si hay
create or replace function public.avisar_ingreso()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_quien  record;
  v_nombre text := public.como_le_dicen(new.apodo, new.nombre_real);
begin
  if new.invitado_por is null or new.nombre_sektario is null then
    return new;
  end if;

  select * into v_quien from public.a_quien_escribirle(new.invitado_por);
  if v_quien.email is null then
    return new;
  end if;

  perform public.mandar_mail(
    v_quien.email,
    'entró alguien por tu mano',
    public.mail_armado(
      'tu rama creció',
      case when v_nombre is null
           then 'AHORA ES ' || new.nombre_sektario
           else upper(v_nombre) || ', AHORA ES ' || new.nombre_sektario end,
      'entró de tu mano<br>al árbol de la sekta',
      v_quien.baja));

  return new;
exception when others then
  return new;
end;
$function$;

-- avisar_asignacion_suelta: el nombre que muestra pasa a ser el apodo, si hay
create or replace function public.avisar_asignacion_suelta(p_entrada uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_e record;
  v_de text;
begin
  select e.duenio, e.tenedor into v_e
    from public.entradas e where e.id = p_entrada;

  if v_e.duenio is null or v_e.duenio = v_e.tenedor then return; end if;

  select public.como_le_dicen(m.apodo, m.nombre_real) into v_de
    from public.miembros m where m.id = v_e.tenedor;

  perform public.mail_de_preventa(
    v_e.duenio, 'seki 7', 'tenés tu lugar',
    coalesce(v_de, 'Alguien') || ' te dio una entrada para SEKI 7.' ||
    '<br><br>Te va a llegar el QR por separado.',
    'tenés tu lugar en seki 7');
end;
$function$;

-- que la API se entere de las funciones nuevas
notify pgrst, 'reload schema';
