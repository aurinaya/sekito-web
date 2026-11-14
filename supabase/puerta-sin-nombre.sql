-- SEKI 7 · la puerta encuentra a todos (14/11/2026)
--
-- 1. Quien compró por link y no completó sus datos no tenía nombre en la base:
--    la puerta lo mostraba vacío. Ahora usa el nombre que puso al comprar
--    (nota_admin = "palabra · nombre") y se lo busca por ese nombre o su mail.
-- 2. Las entradas sin asignar (sin código) aparecen buscando a quien las tiene:
--    una fila por persona, "DE PARTE DE AGUSTIN · quedan 2 de 3". Al tocar
--    "entra" se marca una; la próxima búsqueda muestra las que quedan.
--    Las de LA SEKTA no salen (son de la casa), igual que en la lista impresa.
-- 3. La puerta puede marcar esas entradas, y el conteo las suma.

-- el nombre que dejó al comprar por link, si nunca completó sus datos
create or replace function public.nombre_del_pedido(p_nota text)
returns text language sql immutable set search_path to 'public' as $$
  select nullif(btrim(substring(coalesce(p_nota, '') from position(' · ' in coalesce(p_nota, '')) + 3)), '')
   where position(' · ' in coalesce(p_nota, '')) > 0;
$$;

create or replace function public.puerta_fila(e entradas)
returns table(entrada_id uuid, codigo text, titulo text, nombre text, sektario text, tipo text,
              de_afuera boolean, adentro_en timestamptz, adentro_por text)
language sql stable security definer set search_path to 'public' as $function$
  select e.id, e.codigo,
         case when e.duenio is null and e.externo_nombre is null then
                'DE PARTE DE ' || upper(coalesce(t.apodo, t.nombre_real, public.nombre_del_pedido(t.nota_admin), 'alguien'))
              else upper(coalesce(m.apodo, e.externo_apodo, m.nombre_real, e.externo_nombre,
                                  public.nombre_del_pedido(m.nota_admin))) end,
         case when e.duenio is null and e.externo_nombre is null then
                'sin nombre · la tiene ' ||
                coalesce(nullif(trim(coalesce(public.nombre_lindo(t.nombre_real), '') || ' ' ||
                                     coalesce(public.nombre_lindo(t.apellido), '')), ''),
                         public.nombre_del_pedido(t.nota_admin), 'alguien') ||
                coalesce(' (' || t.nombre_sektario || ')', '')
              else coalesce(nullif(trim(coalesce(public.nombre_lindo(m.nombre_real), '') || ' ' ||
                                        coalesce(public.nombre_lindo(m.apellido), '')), ''),
                            nullif(trim(coalesce(e.externo_nombre, '') || ' ' || coalesce(e.externo_apellido, '')), ''),
                            public.nombre_del_pedido(m.nota_admin) || ' · compró sin completar sus datos') end,
         case when e.duenio is null and e.externo_nombre is null then null else m.nombre_sektario end,
         e.tipo, e.externo_nombre is not null,
         e.adentro_en, e.adentro_por
    from (select 1) uno
    left join public.miembros m on m.id = e.duenio
    left join public.miembros t on t.id = e.tenedor;
$function$;

-- una entrada que entra por la puerta: con QR, o sin asignar y no de LA SEKTA
create or replace function public.puerta_cuenta(e entradas)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select e.anulada_en is null and (
           e.codigo is not null
        or (e.duenio is null and e.externo_nombre is null and e.evento = 'seki7'
            and not exists (select 1 from public.miembros t
                             where t.id = e.tenedor and t.nombre_sektario = 'LA SEKTA')));
$$;

create or replace function public.puerta_buscar(p_llave text, p_q text)
returns table(entrada_id uuid, codigo text, titulo text, nombre text, sektario text, tipo text,
              de_afuera boolean, adentro_en timestamptz, adentro_por text)
language plpgsql security definer set search_path to 'public' as $function$
declare
  v_q text := btrim(coalesce(p_q, ''));
begin
  perform public.puerta_de(p_llave);
  if length(v_q) < 2 then return; end if;

  return query
    with con_qr as (
      select f.*, public.empieza(v_q, m.nombre_sektario,
                                 coalesce(m.nombre_real, e.externo_nombre, public.nombre_del_pedido(m.nota_admin)),
                                 coalesce(m.apodo, e.externo_apodo)) as primero
        from public.entradas e
        left join public.miembros m on m.id = e.duenio
        cross join lateral public.puerta_fila(e) f
       where e.anulada_en is null and e.codigo is not null
         and (public.coincide(v_q, m.nombre_sektario,
                              coalesce(m.nombre_real, e.externo_nombre, public.nombre_del_pedido(m.nota_admin)),
                              coalesce(m.apellido, e.externo_apellido),
                              coalesce(m.apodo, e.externo_apodo))
              or e.codigo = public.codigo_de_entrada(v_q)
              or (m.nombre_real is null and length(v_q) >= 4
                  and lower(coalesce(m.email, '')) like '%' || lower(v_q) || '%'))
    ),
    -- las sin asignar: por persona, la próxima que falta entrar (o la última, si ya entraron todas)
    sueltas as (
      select e.id, t.id as quien,
             count(*) over (partition by t.id) as n,
             count(*) filter (where e.adentro_en is null) over (partition by t.id) as faltan,
             row_number() over (partition by t.id order by (e.adentro_en is null) desc, e.adentro_en desc, e.creada_en) as orden,
             public.empieza(v_q, t.nombre_sektario, coalesce(t.nombre_real, public.nombre_del_pedido(t.nota_admin)), t.apodo) as primero
        from public.entradas e
        join public.miembros t on t.id = e.tenedor
       where e.codigo is null and public.puerta_cuenta(e)
         and public.coincide(v_q, t.nombre_sektario,
                             coalesce(t.nombre_real, public.nombre_del_pedido(t.nota_admin)), t.apellido, t.apodo)
    ),
    sin_qr as (
      select f.entrada_id, f.codigo, f.titulo,
             case when s.faltan = 0 then 'entraron las ' || s.n || ' · '
                  else 'quedan ' || s.faltan || ' de ' || s.n || ' · ' end || f.nombre,
             f.sektario, f.tipo, f.de_afuera, f.adentro_en, f.adentro_por, s.primero
        from sueltas s
        join public.entradas e2 on e2.id = s.id
        cross join lateral public.puerta_fila(e2) f
       where s.orden = 1
    )
    select x.entrada_id, x.codigo, x.titulo, x.nombre, x.sektario, x.tipo, x.de_afuera, x.adentro_en, x.adentro_por
      from (select * from con_qr union all select * from sin_qr) x
     order by x.primero desc, (x.codigo is null), x.titulo
     limit 10;
end;
$function$;

create or replace function public.puerta_marcar(p_llave text, p_entrada uuid)
returns table(ya_estaba boolean, adentro_en timestamptz, adentro_por text)
language plpgsql security definer set search_path to 'public' as $function$
declare
  v_p record;
begin
  select * into v_p from public.puerta_de(p_llave);

  update public.entradas e
     set adentro_en = now(), adentro_por = v_p.nombre
   where e.id = p_entrada and public.puerta_cuenta(e)
     and e.adentro_en is null;

  if found then
    return query select false, e.adentro_en, e.adentro_por from public.entradas e where e.id = p_entrada;
  else
    return query select true, e.adentro_en, e.adentro_por from public.entradas e
                  where e.id = p_entrada and e.anulada_en is null;
  end if;
end;
$function$;

create or replace function public.puerta_conteo(p_llave text)
returns table(adentro integer, total integer)
language plpgsql security definer set search_path to 'public' as $function$
begin
  perform public.puerta_de(p_llave);
  return query
    select count(*) filter (where e.adentro_en is not null)::integer,
           count(*)::integer
      from public.entradas e where public.puerta_cuenta(e);
end;
$function$;

revoke all on function public.nombre_del_pedido(text) from public;
revoke all on function public.puerta_cuenta(entradas) from public, anon, authenticated;

-- la lista impresa también usa el nombre del pedido para quien no completó sus datos
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
       where e.codigo is null and public.puerta_cuenta(e)
       group by 1, 2
    )
    select upper(coalesce(m.apodo, m.nombre_real, public.nombre_del_pedido(m.nota_admin), 'sin datos')),
           coalesce(nullif(trim(coalesce(public.nombre_lindo(m.nombre_real), '') || ' ' ||
                                coalesce(public.nombre_lindo(m.apellido), '')), ''),
                    public.nombre_del_pedido(m.nota_admin) || ' · compró sin completar sus datos',
                    'compró y todavía no completó sus datos'),
           m.nombre_sektario,
           sum(s.n)::integer,
           string_agg(s.n || ' ' || s.tipo, ' · ' order by s.tipo)
      from sueltas s
      join public.miembros m on m.id = s.tenedor
     group by m.id, m.apodo, m.nombre_real, m.apellido, m.nombre_sektario, m.nota_admin
     order by public.para_buscar(upper(coalesce(m.apodo, m.nombre_real, public.nombre_del_pedido(m.nota_admin), 'sin datos')));
end;
$function$;
