-- ============================================================================
-- SÉKITO — el árbol
-- ============================================================================
-- Lo que dibuja sekito.ar/arbol (y la miniatura de "mi rama" en el perfil):
-- todo el linaje, de una vez.
--
-- Arriba de todo el abanico ('raiz'). De él cuelgan LA SEKTA y los
-- fundadores. Cada persona cuelga de quien la trajo; si quien la trajo ya no
-- está activo (suspendido, revocado), cuelga de LA SEKTA. Quien no tiene
-- invitador y no es fundador (lo cargó el panel), también.
--
-- Solo activos registrados: los suspendidos no aparecen, y las llaves sin
-- usar tampoco. Nada de llaves ni de contacto: cómo le dicen, nombre y
-- apellido (lo mismo que ya muestra devotxs) y el código sektario.
--
--   select public.el_arbol('<llave>');  →  { "yo": "<id>", "nodos": [...] }
-- ============================================================================

create or replace function public.el_arbol(p_codigo text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
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
                 nullif(trim(coalesce(public.nombre_lindo(m.nombre_real), '') || ' ' ||
                             coalesce(public.nombre_lindo(m.apellido), '')), ''),
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
$$;

revoke execute on function public.el_arbol(text) from public;
grant execute on function public.el_arbol(text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
