-- ============================================================================
-- SÉKITO — lxs devotxs: buscar a alguien y ver quién es
-- ============================================================================
-- El problema de fondo: los códigos sektarios todavía no se aprendieron.
-- Poner el nombre al lado del código en cada pantalla donde aparece una
-- persona es un parche por lugar; esto es la solución general. Donde sea que
-- veas un código, lo podés buscar acá.
--
-- Hay buscador, pero NO hay lista. No se puede scrollear el padrón, no hay
-- un contador de cuántos somos, no se puede pasear por la sekta. Encontrás a
-- quien buscás y nada más. Son 18: una lista de 18 no parece una sekta,
-- parece un grupo de WhatsApp. La opacidad es parte de lo que se vende.
--
-- Lo que la ficha NO devuelve nunca: mail, teléfono, apellido, código de
-- acceso, cómo llegó. Nombre de pila, código sektario, de quién vino, a
-- cuántos trajo, y en qué ritos está atestiguado.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. buscar
-- ----------------------------------------------------------------------------
-- Dos caracteres alcanzan: los prefijos sektarios son de tres letras y uno
-- quiere poder tipear "md" y encontrar a MDL·842.
--
-- Busca sobre el dato crudo —quien se anotó "MAIA" tiene que aparecer
-- buscando "maia"— pero devuelve el nombre parejo.
--
-- Los dados de baja no aparecen. No se borran de la base, pero dejan de
-- estar en el padrón: es justamente lo que significa dar de baja a alguien.
create or replace function public.buscar_en_el_sekito(p_codigo text, p_query text)
returns table (
  sektario  text,
  nombre    text,
  pantalla  text,
  es_sekta  boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
  v_q  text := btrim(coalesce(p_query, ''));
begin
  if length(v_q) < 2 then
    return;
  end if;

  return query
    select m.nombre_sektario,
           public.nombre_lindo(m.nombre_real),
           m.pantalla,
           (m.estado_codigo = 'simbolico')
      from public.miembros m
     where m.estado_codigo in ('activo', 'simbolico')
       and m.nombre_sektario is not null
       and (
             m.nombre_sektario ilike '%' || v_q || '%'
          or m.nombre_real     ilike '%' || v_q || '%'
          or m.apellido        ilike '%' || v_q || '%'
           )
     order by
       -- primero los que empiezan con lo que escribiste: si tipeás "mau",
       -- MAU·000 va antes que cualquiera que tenga "mau" en el medio
       (m.nombre_sektario ilike v_q || '%' or m.nombre_real ilike v_q || '%') desc,
       m.nombre_real nulls last
     limit 8;

  -- v_yo no se usa más que para exigir un código válido: el padrón es de los
  -- que están adentro
  perform v_yo;
end;
$$;


-- ----------------------------------------------------------------------------
-- 2. la ficha
-- ----------------------------------------------------------------------------
-- Un solo objeto y no filas, por lo mismo que mi_rama: "de quién vino" y
-- "a cuántos trajo" no son listas, y con filas se perderían justo en la
-- ficha de quien todavía no trajo a nadie.
create or replace function public.ficha_del_sekito(p_codigo text, p_sektario text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
    'nombre',    public.nombre_lindo(m.nombre_real),
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
                           'nombre',   public.nombre_lindo(q.nombre_real))
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
                 ), '[]'::jsonb)
  ) into v_res
  from public.miembros m
 where m.id = v_id;

  return v_res;
end;
$$;


-- ----------------------------------------------------------------------------
-- 3. mi rama, con los nombres parejos
-- ----------------------------------------------------------------------------
-- Devolvía nombre_real crudo; que quede igual que en todas las otras
-- pantallas. Suma el sektario de la guía para poder abrir su ficha.
create or replace function public.mi_rama(p_codigo text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo  uuid := public.miembro_de(p_codigo);
  v_res jsonb;
begin
  with recursive rama as (
    select m.id, m.invitado_por as de, m.nombre_sektario, m.nombre_real, 1 as profundidad,
           array[coalesce(m.nombre_sektario, m.codigo_acceso)] as camino
      from public.miembros m
     where m.invitado_por = v_yo

    union all

    select h.id, h.invitado_por, h.nombre_sektario, h.nombre_real, r.profundidad + 1,
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
                            'nombre_real', public.nombre_lindo(r.nombre_real),
                            'profundidad', r.profundidad
                          ) order by r.camino)
                     from rama r
                 ), '[]'::jsonb)
  ) into v_res;

  return v_res;
end;
$$;


-- ----------------------------------------------------------------------------
-- 4. permisos
-- ----------------------------------------------------------------------------
revoke all on function public.buscar_en_el_sekito(text, text) from public;
revoke all on function public.ficha_del_sekito(text, text)    from public;
revoke all on function public.mi_rama(text)                   from public;

grant execute on function public.buscar_en_el_sekito(text, text) to anon, authenticated;
grant execute on function public.ficha_del_sekito(text, text)    to anon, authenticated;
grant execute on function public.mi_rama(text)                   to anon, authenticated;


-- ============================================================================
-- Verificación
-- ============================================================================
-- select * from public.buscar_en_el_sekito('UNCODIGO', 'md');
-- select jsonb_pretty(public.ficha_del_sekito('UNCODIGO', 'MDL·842'));
-- select * from public.buscar_en_el_sekito('UNCODIGO', 'a');  -> vacío (< 2)
