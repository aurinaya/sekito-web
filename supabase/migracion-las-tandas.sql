-- ---------------------------------------------------------------------------
-- LAS TRES TANDAS EN LA PANTALLA DE COMPRA (15/10)
-- La pantalla de SEKI 7 solo mostraba la tanda activa. Esto devuelve las tres
-- con su estado, para la lista de abajo: cerrada (las de antes de la activa),
-- activa, pendiente (las de después). Por id: sekreta → hermética → abierta.
-- ---------------------------------------------------------------------------

create or replace function public.las_tandas(p_codigo text)
returns table(nombre text, precio integer, estado text)
language plpgsql security definer set search_path = public as $$
declare v_activa integer;
begin
  perform public.miembro_de(p_codigo);
  select id into v_activa from public.tandas where activa limit 1;
  return query
    select t.nombre, t.precio,
           case when t.activa then 'activa'
                when v_activa is not null and t.id < v_activa then 'cerrada'
                else 'pendiente' end
      from public.tandas t
     order by t.id;
end;
$$;
