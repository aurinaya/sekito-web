-- ---------------------------------------------------------------------------
-- EL MISMO COMPROBANTE DOS VECES (10/10)
--
-- Lucas pidió su lugar, subió el comprobante, y siete segundos después volvió
-- a pedir y subió la misma foto: dos compras confirmadas por una sola
-- transferencia. El panel ahora avisa cuando un comprobante es idéntico
-- (byte a byte) a otro ya subido, y pregunta de nuevo antes de confirmar.
--
-- Va aparte de admin_compras para no cambiarle la forma: el panel viejo sigue
-- andando mientras se publica el nuevo. Una foto distinta de la misma
-- transferencia (otra captura) no se detecta: esto agarra el doble envío.
-- ---------------------------------------------------------------------------

create or replace function public.admin_comprobantes_repetidos(p_codigo text)
returns table(compra_id uuid, igual_a text)
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_id_de(p_codigo);

  return query
    with h as (
      select c.id, c.creada_en, c.comprador, md5(c.comprobante) as huella
        from public.compras c
       where c.comprobante is not null
    )
    select a.id,
           string_agg(
             trim(coalesce(public.nombre_lindo(m.nombre_real), '') || ' ' ||
                  coalesce(public.nombre_lindo(m.apellido), '')) || ' · ' ||
             to_char(b.creada_en at time zone 'America/Argentina/Buenos_Aires', 'DD/MM HH24:MI'),
             ', ' order by b.creada_en)
      from h a
      join h b on b.huella = a.huella and b.id <> a.id
      join public.miembros m on m.id = b.comprador
     group by a.id;
end;
$$;
