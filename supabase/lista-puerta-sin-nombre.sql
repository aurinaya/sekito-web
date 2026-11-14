-- SEKI 7 · la lista de puerta también trae las entradas sin asignar (14/11/2026)
--
-- Una entrada sin asignar no tiene código, así que no sale en admin_lista_puerta.
-- Esta función las junta por quien las tiene ("Agustín Ferrero · 3 sin nombre"):
-- en la puerta, quien llegue de parte de esa persona entra con una de esas.
-- Las que tiene LA SEKTA no salen (son de la casa, no de alguien que compró).
-- Las guardadas en un link cuentan igual: si la persona no lo abrió, llega sin QR.

create or replace function public.admin_lista_puerta_sin_nombre(p_codigo text)
returns table(titulo text, nombre text, sektario text, cuantas integer, tipos text)
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  perform public.admin_id_de(p_codigo);
  return query
    with sueltas as (
      select e.tenedor, e.tipo, count(*)::integer n
        from public.entradas e
       where e.evento = 'seki7' and e.anulada_en is null
         and e.codigo is null and e.duenio is null and e.externo_nombre is null
       group by 1, 2
    )
    select upper(coalesce(m.apodo, m.nombre_real, 'sin datos')),
           coalesce(nullif(trim(coalesce(public.nombre_lindo(m.nombre_real), '') || ' ' ||
                                coalesce(public.nombre_lindo(m.apellido), '')), ''),
                    'compró y todavía no completó sus datos'),
           m.nombre_sektario,
           sum(s.n)::integer,
           string_agg(s.n || ' ' || s.tipo, ' · ' order by s.tipo)
      from sueltas s
      join public.miembros m on m.id = s.tenedor
     where coalesce(m.nombre_sektario, '') <> 'LA SEKTA'
     group by m.id, m.apodo, m.nombre_real, m.apellido, m.nombre_sektario
     order by public.para_buscar(upper(coalesce(m.apodo, m.nombre_real, 'sin datos')));
end;
$function$;

revoke all on function public.admin_lista_puerta_sin_nombre(text) from public;
grant execute on function public.admin_lista_puerta_sin_nombre(text) to anon, authenticated;
