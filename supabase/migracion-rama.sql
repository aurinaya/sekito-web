-- ============================================================================
-- SÉKITO — mi rama del árbol, y los nombres de las fiestas en mayúscula
-- ============================================================================
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. SEKI y SEKTA en mayúscula, como COLAPSO
-- ----------------------------------------------------------------------------
update public.fiestas set nombre = replace(nombre, 'Seki ',       'SEKI ')       where nombre like 'Seki %';
update public.fiestas set nombre = replace(nombre, 'Tiny Sekta ', 'Tiny SEKTA ') where nombre like 'Tiny Sekta %';


-- ----------------------------------------------------------------------------
-- 2. mi rama
-- ----------------------------------------------------------------------------
-- Quién me trajo, y toda la gente que cuelga de mí: los que traje yo, los que
-- trajeron ellos, y así hacia abajo.
--
-- Devuelve un solo objeto en vez de una fila por persona porque hay dos cosas
-- que no son una lista —quién me trajo y cuántos son— y con filas se perderían
-- justo en el caso de quien todavía no trajo a nadie.
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
    -- los que traje yo
    select m.id, m.nombre_sektario, m.nombre_real, 1 as profundidad,
           array[coalesce(m.nombre_sektario, m.codigo_acceso)] as camino
      from public.miembros m
     where m.invitado_por = v_yo

    union all

    -- y colgando de cada uno, los que trajo
    select h.id, h.nombre_sektario, h.nombre_real, r.profundidad + 1,
           r.camino || coalesce(h.nombre_sektario, h.codigo_acceso)
      from public.miembros h
      join rama r on h.invitado_por = r.id
     where r.profundidad < 20   -- red de seguridad; los ciclos ya los frena un trigger
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
                            'nombre',      r.nombre_sektario,
                            'nombre_real', r.nombre_real,
                            'profundidad', r.profundidad
                          ) order by r.camino)
                     from rama r
                 ), '[]'::jsonb)
  ) into v_res;

  return v_res;
end;
$$;

revoke all on function public.mi_rama(text) from public;
grant execute on function public.mi_rama(text) to anon, authenticated;


-- ============================================================================
-- Verificación
-- ============================================================================
-- select nombre from public.fiestas order by fecha;   -> SEKI 1 ... Tiny SEKTA 2
-- select public.mi_rama('UNCODIGO');
