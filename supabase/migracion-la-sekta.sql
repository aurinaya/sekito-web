-- ============================================================================
-- SÉKITO — FISURA pasa a llamarse LA SEKTA
-- ============================================================================
-- El miembro simbólico se llamaba FISURA y significaba "no me trajo nadie en
-- particular". Ahora se llama LA SEKTA, y pasa a cumplir dos papeles con la
-- misma figura:
--
--   * en el formulario de bienvenida: a esta persona la trajo la sekta misma
--   * en las validaciones de asistencia: la sekta confirma que estuviste
--
-- Tener dos entidades simbólicas distintas —una para el linaje y otra para
-- validar— habría sido confuso. Es la misma idea las dos veces.
--
-- No cambia nada estructural: es el mismo registro, con el mismo id, así que
-- todos los que ya lo tienen como invitador siguen apuntando a él.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================

update public.miembros
   set nombre_sektario = 'LA SEKTA'
 where nombre_sektario = 'FISURA';


-- ----------------------------------------------------------------------------
-- el comentario de buscar_miembros nombraba a FISURA
-- ----------------------------------------------------------------------------
-- Mismo cuerpo y mismo retorno que antes; se recrea sólo para que lo que dice
-- la función en la base coincida con lo que dice el repo.
create or replace function public.buscar_miembros(p_codigo text, p_query text)
returns table (
  id               uuid,
  nombre_sektario  text,
  nombre_real      text,
  apellido         text
)
language sql
security definer
set search_path = public
as $$
  select m.id, m.nombre_sektario, m.nombre_real, m.apellido
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
         )
   order by m.nombre_real nulls last, m.nombre_sektario
   limit 8;
$$;

revoke all on function public.buscar_miembros(text, text) from public;
grant execute on function public.buscar_miembros(text, text) to anon, authenticated;


-- ============================================================================
-- Verificación
-- ============================================================================
-- select nombre_sektario, estado_codigo from public.miembros
--   where estado_codigo = 'simbolico';           -> LA SEKTA
-- select * from public.buscar_miembros('CODIGO', 'sekta');  -> LA SEKTA
