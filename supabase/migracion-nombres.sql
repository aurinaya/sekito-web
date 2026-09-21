-- ============================================================================
-- SÉKITO — el nombre al lado del código
-- ============================================================================
-- A quien le llega un pedido de fe le llegaba solo el código sektario:
-- "MDL·842 te pide que des fe". Nadie sabe quién es MDL·842. El código es el
-- nombre de acá adentro, pero todavía no reemplaza al de afuera: hay que
-- mostrar los dos hasta que uno se aprenda el otro.
--
-- Y el nombre se muestra siempre en el mismo formato. En la base hay
-- "diego", "MAIA" y "Juan MANUEL", tal como los escribió cada uno. Se
-- guardan igual —nadie le corrige el nombre a nadie— pero se muestran
-- parejos. No le gritamos a nadie.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. el nombre, presentable
-- ----------------------------------------------------------------------------
-- initcap hace justo esto: primera en mayúscula, el resto en minúscula, y
-- por cada palabra. "MAIA" -> "Maia", "diego" -> "Diego", "Juan MANUEL" ->
-- "Juan Manuel".
--
-- Es a la hora de mostrar, no al guardar: lo que la persona escribió queda
-- como lo escribió. Si algún día hay un "McKenna" que quiere su K, está su
-- dato intacto para arreglarlo.
create or replace function public.nombre_lindo(p_nombre text)
returns text
language sql
immutable
set search_path = public
as $$
  select nullif(initcap(btrim(coalesce(p_nombre, ''))), '');
$$;

revoke all on function public.nombre_lindo(text) from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 2. los pedidos que me hicieron a mí
-- ----------------------------------------------------------------------------
-- Suma el nombre. LA SEKTA no tiene nombre real y devuelve null: la pantalla
-- muestra el código solo, que en ese caso ya se entiende.
drop function if exists public.mis_pedidos(text);

create or replace function public.mis_pedidos(p_codigo text)
returns table (
  validacion_id  uuid,
  quien          text,
  quien_nombre   text,
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
    select v.id, m.nombre_sektario, public.nombre_lindo(m.nombre_real),
           f.nombre, f.fecha,
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
-- 3. mis ritos, con los testigos por su nombre
-- ----------------------------------------------------------------------------
-- Mismo problema una semana después: elegiste dos testigos y ya no te
-- acordás cuál era cuál.
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
                 'nombre_real',   public.nombre_lindo(t.nombre_real),
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
-- 4. el buscador de testigos, parejo
-- ----------------------------------------------------------------------------
-- Ya devolvía el nombre real; ahora lo devuelve con el mismo formato que el
-- resto. La búsqueda sigue siendo sobre el dato crudo: quien escribió "maia"
-- tiene que poder encontrarse buscando "maia".
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
    select m.id, m.nombre_sektario, public.nombre_lindo(m.nombre_real),
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
-- 5. permisos
-- ----------------------------------------------------------------------------
revoke all on function public.mis_pedidos(text)                  from public;
revoke all on function public.mis_ritos(text)                    from public;
revoke all on function public.buscar_testigos(text, uuid, text)  from public;

grant execute on function public.mis_pedidos(text)                  to anon, authenticated;
grant execute on function public.mis_ritos(text)                    to anon, authenticated;
grant execute on function public.buscar_testigos(text, uuid, text)  to anon, authenticated;


-- ============================================================================
-- Verificación
-- ============================================================================
-- select public.nombre_lindo('MAIA');        -> Maia
-- select public.nombre_lindo('Juan MANUEL'); -> Juan Manuel
-- select public.nombre_lindo('diego');       -> Diego
-- select * from public.mis_pedidos('UNCODIGO');
