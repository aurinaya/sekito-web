-- 19/11/2026 · todos los buscadores del portal encuentran por apellido completo
--
-- Criterio de Mau: "siempre que haya un buscador del sékito, que sea fácil
-- encontrar a la persona". El apellido entero sirve para BUSCAR ("raele" trae a
-- Camu), pero nunca se muestra: en pantalla sigue yendo la inicial ("Camila R.").
-- Antes estos buscadores solo comparaban contra la inicial del apellido.
-- (buscar_para_ofrendar ya busca así: ver los-siete-pecados.sql)
--
-- Se puede correr más de una vez.

CREATE OR REPLACE FUNCTION public.buscar_en_el_sekito(p_codigo text, p_query text)
 RETURNS TABLE(sektario text, nombre text, pantalla text, es_sekta boolean, nombre_completo text, estuvo_s7 boolean)
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
           public.nombre_con_inicial(m.nombre_real, m.apellido),
           public.estuvo_en_s7(m.id)
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
$function$

;

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
     and public.coincide(p_query, m.nombre_sektario, m.nombre_real, m.apellido, m.apodo)
   order by public.empieza(p_query, m.nombre_sektario, m.nombre_real, m.apodo) desc,
            m.nombre_real nulls last, m.nombre_sektario
   limit 8;
$function$

;

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
       and public.coincide(v_q, m.nombre_sektario, m.nombre_real, m.apellido, m.apodo)
     order by
       public.empieza(v_q, m.nombre_sektario, m.nombre_real, m.apodo) desc,
       m.nombre_real nulls last
     limit 8;
end;
$function$

;

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
       and public.coincide(v_q, m.nombre_sektario, m.nombre_real, m.apellido, m.apodo)
     order by
       -- con una sola letra esto es lo que hace la diferencia: primero los
       -- que empiezan así, después el resto
       public.empieza(v_q, m.nombre_sektario, m.nombre_real, m.apodo) desc,
       m.nombre_real nulls last
     limit 8;
end;
$function$

;

