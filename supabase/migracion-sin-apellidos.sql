-- ---------------------------------------------------------------------------
-- SIN APELLIDOS ENTRE MIEMBROS (09/10)
--
-- Adentro del portal cualquiera puede encontrar a cualquiera, pero el
-- apellido no se muestra: se ve cómo le dicen, el nombre con la inicial del
-- apellido ("Juan N.") y el código sektario. La inicial se arma acá, así que
-- el apellido entero nunca llega al celular.
--
-- Cambian el_arbol, buscar_en_el_sekito, buscar_miembros (el "¿quién te
-- trajo?" del registro), buscar_testigos y buscar_para_entrada: además,
-- buscar por el apellido completo deja de encontrar (si "narbaitz" trajera a
-- "Juan N.", lo confirmaría). "juan n" sí encuentra.
--
-- El panel de admin, la puerta y tu propia entrada siguen con el apellido.
-- ---------------------------------------------------------------------------

create or replace function public.inicial_apellido(p_apellido text)
returns text language sql immutable set search_path = public as $$
  select upper(left(public.nombre_lindo(p_apellido), 1)) || '.';
$$;

create or replace function public.nombre_con_inicial(p_nombre text, p_apellido text)
returns text language sql immutable set search_path = public as $$
  select nullif(concat_ws(' ', public.nombre_lindo(p_nombre), public.inicial_apellido(p_apellido)), '');
$$;

revoke execute on function public.inicial_apellido(text) from public, anon, authenticated;
revoke execute on function public.nombre_con_inicial(text, text) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.el_arbol(p_codigo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_yo    uuid := public.miembro_de(p_codigo);
  v_sekta uuid := public.id_la_sekta();
begin
  return jsonb_build_object(
    'yo', v_yo::text,
    'nodos', (
      select jsonb_agg(to_jsonb(x) order by x.orden)
        from (
          select 'raiz' as id, null::text as padre, '' as sektario, '' as titulo,
                 null::text as nombre, 'raiz' as tipo, timestamptz '2000-01-01' as orden
          union all
          select v_sekta::text, 'raiz', m.nombre_sektario, 'LA SEKTA', null, 'sekta', m.creado_en
            from public.miembros m
           where m.id = v_sekta
          union all
          select m.id::text,
                 case when p.estado_codigo in ('activo', 'simbolico') then m.invitado_por::text
                      when m.invitado_por is null and m.es_fundador then 'raiz'
                      else v_sekta::text end,
                 m.nombre_sektario,
                 public.como_le_dicen(m.apodo, m.nombre_real),
                 public.nombre_con_inicial(m.nombre_real, m.apellido),
                 'persona',
                 coalesce(m.registrado_en, m.creado_en)
            from public.miembros m
            left join public.miembros p on p.id = m.invitado_por
           where m.estado_codigo = 'activo'
             and m.nombre_real is not null
             and m.id <> v_sekta
        ) x
    )
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.buscar_en_el_sekito(p_codigo text, p_query text)
 RETURNS TABLE(sektario text, nombre text, pantalla text, es_sekta boolean, nombre_completo text)
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
           (m.estado_codigo = 'simbolico'),
           public.nombre_con_inicial(m.nombre_real, m.apellido)
      from public.miembros m
     where m.estado_codigo in ('activo', 'simbolico')
       and m.nombre_sektario is not null
       and public.coincide(v_q, m.nombre_sektario, m.nombre_real, public.inicial_apellido(m.apellido), m.apodo)
     order by
       public.empieza(v_q, m.nombre_sektario, m.nombre_real, m.apodo) desc,
       m.nombre_real nulls last
     limit 8;

  perform v_yo;
end;
$function$;

CREATE OR REPLACE FUNCTION public.buscar_miembros(p_codigo text, p_query text)
 RETURNS TABLE(id uuid, nombre_sektario text, nombre_real text, apellido text, apodo text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select m.id, m.nombre_sektario, m.nombre_real, public.inicial_apellido(m.apellido), m.apodo
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
     and public.coincide(p_query, m.nombre_sektario, m.nombre_real, public.inicial_apellido(m.apellido), m.apodo)
   order by public.empieza(p_query, m.nombre_sektario, m.nombre_real, m.apodo) desc,
            m.nombre_real nulls last, m.nombre_sektario
   limit 8;
$function$;

CREATE OR REPLACE FUNCTION public.buscar_testigos(p_codigo text, p_fiesta uuid, p_query text)
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
       and public.coincide(v_q, m.nombre_sektario, m.nombre_real, public.inicial_apellido(m.apellido), m.apodo)
     order by
       -- con una sola letra esto es lo que hace la diferencia: primero los
       -- que empiezan así, después el resto
       public.empieza(v_q, m.nombre_sektario, m.nombre_real, m.apodo) desc,
       m.nombre_real nulls last
     limit 8;
end;
$function$;

CREATE OR REPLACE FUNCTION public.buscar_para_entrada(p_codigo text, p_query text)
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
                    where e.duenio = m.id and e.evento = 'seki7' and e.anulada_en is null)
      from public.miembros m
     where m.estado_codigo = 'activo'
       and m.nombre_real is not null
       and public.coincide(v_q, m.nombre_sektario, m.nombre_real, public.inicial_apellido(m.apellido), m.apodo)
     order by
       public.empieza(v_q, m.nombre_sektario, m.nombre_real, m.apodo) desc,
       m.nombre_real nulls last
     limit 8;
end;
$function$;
