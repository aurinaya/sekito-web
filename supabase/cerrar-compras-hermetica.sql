-- ---------------------------------------------------------------------------
-- LAS COMPRAS DE LA HERMÉTICA SIN COMPROBANTE SE CIERRAN SOLAS (26/10)
--
-- Se les mantuvo el precio hasta el lunes 26/10 a las 23:59 (mail del 26/10).
-- A las 00:00 del 27/10 (03:00 UTC) un trabajo de una sola vez borra las que
-- sigan esperando comprobante (sin entradas: todavía no nacieron) y se borra a
-- sí mismo. Al volver, el portal les ofrece la tanda que esté abierta.
-- ---------------------------------------------------------------------------

create or replace function public.cerrar_compras_abiertas(p_tanda text)
returns integer language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  delete from public.compras c using public.tandas t
   where t.id = c.tanda_id and t.nombre = p_tanda and c.estado = 'esperando_comprobante'
     and not exists (select 1 from public.entradas e where e.compra_id = c.id);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function public.cerrar_compras_abiertas(text) from public, anon, authenticated;

select cron.schedule('cerrar-hermetica', '0 3 27 10 *',
  $$select public.cerrar_compras_abiertas('hermética'); select cron.unschedule('cerrar-hermetica');$$);
