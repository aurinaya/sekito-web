-- ===========================================================================
-- UN SOLO BUSCADOR DE PERSONAS
--
-- Todos los buscadores de personas del portal y del panel encuentran a
-- alguien por cualquiera de estas cuatro cosas:
--     el apodo · el nombre · el apellido · el código sektario
-- y las comparan de la misma manera:
--   * sin mayúsculas ni tildes: "maria" encuentra a "María" (la ñ sigue
--     siendo ñ: es otra letra, no una n con tilde)
--   * el código sin separadores: "mau000", "mau 000" o "MAU-000" encuentran
--     a "MAU·000" (el punto del medio casi no se puede tipear en el celu)
--   * nombre y apellido juntos: "juan perez" encuentra a Juan Pérez
--
-- Es una superficie más grande, nunca más chica: todo lo que se encontraba
-- antes se sigue encontrando. Las firmas de las funciones no cambian, así
-- que el sitio publicado sigue andando igual mientras tanto.
--
-- Lo único que cambia de forma es admin_listar_miembros, que ahora también
-- devuelve el apodo (el panel lo necesita para filtrar y mostrarlo).
-- ===========================================================================

-- el texto como se compara: minúsculas, sin tildes, espacios simples
create or replace function public.para_buscar(t text)
returns text
language sql
immutable
set search_path to 'public'
as $$
  select btrim(regexp_replace(
           translate(lower(coalesce(t, '')),
                     'áàäâãéèëêíìïîóòöôõúùüûç',
                     'aaaaaeeeeiiiiooooouuuuc'),   -- la ñ no: es otra letra
           '\s+', ' ', 'g'));
$$;

-- el código sektario sin nada que no sea letra o número: MAU·000 → mau000
create or replace function public.codigo_para_buscar(t text)
returns text
language sql
immutable
set search_path to 'public'
as $$
  select regexp_replace(public.para_buscar(t), '[^a-z0-9]', '', 'g');
$$;

-- ¿esta persona es la que se busca?
create or replace function public.coincide(p_q text, p_sektario text, p_nombre text,
                                           p_apellido text, p_apodo text)
returns boolean
language sql
immutable
set search_path to 'public'
as $$
  with q as (select public.para_buscar(p_q) as t, public.codigo_para_buscar(p_q) as c)
  select (q.t <> '' and (
             public.para_buscar(p_apodo)    like '%' || q.t || '%'
          or public.para_buscar(p_nombre)   like '%' || q.t || '%'
          or public.para_buscar(p_apellido) like '%' || q.t || '%'
          or public.para_buscar(concat_ws(' ', p_nombre, p_apellido)) like '%' || q.t || '%'
          or public.para_buscar(p_sektario) like '%' || q.t || '%'))
      or (q.c <> '' and public.codigo_para_buscar(p_sektario) like '%' || q.c || '%')
    from q;
$$;

-- ¿empieza así? Para ordenar: primero quienes empiezan con lo tipeado
create or replace function public.empieza(p_q text, p_sektario text, p_nombre text, p_apodo text)
returns boolean
language sql
immutable
set search_path to 'public'
as $$
  with q as (select public.para_buscar(p_q) as t, public.codigo_para_buscar(p_q) as c)
  select (q.t <> '' and (public.para_buscar(p_apodo)  like q.t || '%'
                      or public.para_buscar(p_nombre) like q.t || '%'))
      or (q.c <> '' and public.codigo_para_buscar(p_sektario) like q.c || '%')
    from q;
$$;

-- son herramientas internas, como como_le_dicen: nadie de afuera las llama
revoke execute on function public.para_buscar(text) from public, anon, authenticated;
revoke execute on function public.codigo_para_buscar(text) from public, anon, authenticated;
revoke execute on function public.coincide(text, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.empieza(text, text, text, text) from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- los buscadores del portal
-- ---------------------------------------------------------------------------

-- "¿quién te trajo al sékito?" en la bienvenida
create or replace function public.buscar_miembros(p_codigo text, p_query text)
returns table(id uuid, nombre_sektario text, nombre_real text, apellido text, apodo text)
language sql
security definer
set search_path to 'public'
as $function$
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
     and public.coincide(p_query, m.nombre_sektario, m.nombre_real, m.apellido, m.apodo)
   order by public.empieza(p_query, m.nombre_sektario, m.nombre_real, m.apodo) desc,
            m.nombre_real nulls last, m.nombre_sektario
   limit 8;
$function$;

-- devotxs: el padrón
create or replace function public.buscar_en_el_sekito(p_codigo text, p_query text)
returns table(sektario text, nombre text, pantalla text, es_sekta boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
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
       and public.coincide(v_q, m.nombre_sektario, m.nombre_real, m.apellido, m.apodo)
     order by
       public.empieza(v_q, m.nombre_sektario, m.nombre_real, m.apodo) desc,
       m.nombre_real nulls last
     limit 8;

  perform v_yo;
end;
$function$;

-- los testigos de un rito
create or replace function public.buscar_testigos(p_codigo text, p_fiesta uuid, p_query text)
returns table(id uuid, nombre text, nombre_real text, puede_ya boolean, es_sekta boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
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
       and public.coincide(v_q, m.nombre_sektario, m.nombre_real, m.apellido, m.apodo)
     order by
       -- con una sola letra esto es lo que hace la diferencia: primero los
       -- que empiezan así, después el resto
       public.empieza(v_q, m.nombre_sektario, m.nombre_real, m.apodo) desc,
       m.nombre_real nulls last
     limit 8;
end;
$function$;

-- a quién asignarle una entrada de SEKI 7 (preventa)
create or replace function public.buscar_para_entrada(p_codigo text, p_query text)
returns table(id uuid, sektario text, nombre text, ya_tiene boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
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
       and public.coincide(v_q, m.nombre_sektario, m.nombre_real, m.apellido, m.apodo)
     order by
       public.empieza(v_q, m.nombre_sektario, m.nombre_real, m.apodo) desc,
       m.nombre_real nulls last
     limit 8;
end;
$function$;


-- ---------------------------------------------------------------------------
-- los del panel
-- ---------------------------------------------------------------------------

-- a quién darle una entrada desde el panel (preventa). Antes no miraba el
-- apodo; ahora sí, como todos
create or replace function public.admin_buscar_persona(p_codigo text, p_query text)
returns table(id uuid, sektario text, nombre text, ya_tiene boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_q text := btrim(coalesce(p_query, ''));
begin
  perform public.admin_id_de(p_codigo);
  if length(v_q) < 1 then return; end if;

  return query
    select m.id, m.nombre_sektario, public.nombre_lindo(m.nombre_real),
           exists (select 1 from public.entradas e
                    where e.duenio = m.id and e.evento = 'seki7')
      from public.miembros m
     where m.estado_codigo = 'activo'
       and m.nombre_real is not null
       and public.coincide(v_q, m.nombre_sektario, m.nombre_real, m.apellido, m.apodo)
     order by public.empieza(v_q, m.nombre_sektario, m.nombre_real, m.apodo) desc,
              m.nombre_real nulls last
     limit 8;
end;
$function$;

-- la lista de miembros del panel: ahora con el apodo, al final (el panel
-- busca en la lista que ya tiene, sin ir a la base por cada letra)
drop function public.admin_listar_miembros(text);
create function public.admin_listar_miembros(p_codigo text)
returns table(id uuid, codigo_acceso text, nombre_sektario text, nombre_real text, apellido text,
              email text, telefono text, como_llegaste text, nota_admin text, estado_codigo text,
              es_fundador boolean, pantalla text, invitado_por uuid, invitado_por_nombre text,
              registro_completo boolean, fecha_ingreso timestamp with time zone,
              creado_en timestamp with time zone, apodo text)
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  perform public.admin_id_de(p_codigo);

  return query
    select
      m.id, m.codigo_acceso, m.nombre_sektario, m.nombre_real, m.apellido,
      m.email, m.telefono, m.como_llegaste, m.nota_admin, m.estado_codigo,
      m.es_fundador, m.pantalla, m.invitado_por,
      quien.nombre_sektario as invitado_por_nombre,
      (m.nombre_real is not null) as registro_completo,
      m.fecha_ingreso, m.creado_en, m.apodo
    from public.miembros m
    left join public.miembros quien on quien.id = m.invitado_por
    order by m.creado_en;
end;
$function$;
revoke execute on function public.admin_listar_miembros(text) from public;
grant execute on function public.admin_listar_miembros(text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
