-- ---------------------------------------------------------------------------
-- LOS NÚMEROS DE ARRIBA EN "MIEMBROS" (10/10)
--
-- Por dónde llegó la gente que está adentro (activa y registrada), y cuántos
-- susurros hay. Solo números: el panel borra susurros pero no los lee.
--   por_invitacion: entró con un link de invitación de un miembro
--   por_panel:      entró con una llave hecha en el panel (sin invitación)
--   fundadores:     MAU, NAYA y FLOR, que no llegaron por ningún lado
-- Los tres suman el total de miembros.
-- ---------------------------------------------------------------------------

create or replace function public.admin_numeros_miembros(p_codigo text)
returns table(por_invitacion integer, por_panel integer, fundadores integer, susurros integer)
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_id_de(p_codigo);

  return query
    with adentro as (
      select m.id, m.es_fundador,
             exists (select 1 from public.invitaciones i where i.usada_por = m.id) as invitado
        from public.miembros m
       where m.estado_codigo = 'activo' and m.nombre_real is not null
    )
    select count(*) filter (where invitado)::integer,
           count(*) filter (where not invitado and not es_fundador)::integer,
           count(*) filter (where es_fundador and not invitado)::integer,
           (select count(*)::integer from public.susurros)
      from adentro;
end;
$$;
