-- QUIÉN FALTA (09/11/2026) — panel, pestaña entradas s7
--
-- Para decidir los últimos empujones de SEKI 7: una fila por persona a la que
-- todavía se le puede vender o recordar algo. Solo lee: no manda nada.
--
--   portal      registrados activos sin entrada propia ni compra en curso
--               (sin fundadores)
--   base        la base de mail de la campaña que no compró ni pidió la baja
--               y que no está en el portal
--   sin_asignar quien tiene entradas sin dueño (o guardadas en un link sin abrir)
--
-- Para volver atrás: drop function public.admin_quien_falta(text);

create or replace function public.admin_quien_falta(p_codigo text)
returns table(
  grupo        text,
  nombre       text,     -- como le dicen
  completo     text,     -- nombre y apellido (panel)
  sektario     text,
  mail         text,
  acepta_mails boolean,
  ultima_visita timestamptz,
  registrado_en timestamptz,
  trajo        text,     -- quién lo trajo
  trajo_va     boolean,  -- quien lo trajo ya tiene entrada
  sin_asignar  integer,
  en_link      integer,
  tiene_la_suya boolean,
  falta_comprobante boolean,
  mail_ronda1  boolean
)
language plpgsql stable security definer
set search_path to 'public'
as $$
begin
  perform public.admin_id_de(p_codigo);

  return query
  with con_entrada as (
    select distinct x.m from (
      select e.duenio m from public.entradas e where e.evento = 'seki7' and e.anulada_en is null and e.duenio is not null
      union all
      select e.tenedor from public.entradas e where e.evento = 'seki7' and e.anulada_en is null
      union all
      select c.comprador from public.compras c where c.estado in ('a_revisar', 'confirmada')
    ) x
  ),
  ronda1 as (
    select c.mail from public.campania_s7 c
      join public.campania_s7_envios v on v.token = c.token and v.ronda = 1 and v.estado = 'enviado'
  )
  -- los del portal
  select 'portal'::text,
         public.como_le_dicen(m.apodo, m.nombre_real),
         btrim(coalesce(m.nombre_real, '') || ' ' || coalesce(m.apellido, '')),
         m.nombre_sektario,
         m.email,
         m.acepta_mails,
         m.ultima_visita,
         m.registrado_en,
         public.como_le_dicen(r.apodo, coalesce(r.nombre_real, r.nombre_sektario)),
         (r.id is not null and r.id in (select ce.m from con_entrada ce)),
         0, 0, false,
         exists (select 1 from public.compras c where c.comprador = m.id and c.estado = 'esperando_comprobante'),
         lower(btrim(m.email)) in (select r1.mail from ronda1 r1)
    from public.miembros m
    left join public.miembros r on r.id = m.invitado_por
   where m.estado_codigo = 'activo'
     and m.nombre_real is not null
     and not m.es_fundador
     and m.id not in (select ce.m from con_entrada ce)

  union all

  -- la base de mail que no está en el portal
  select 'base'::text,
         c.saludo,
         c.saludo,
         null::text,
         c.mail,
         true,
         null::timestamptz,
         null::timestamptz,
         null::text,
         false,
         0, 0, false, false,
         c.mail in (select r1.mail from ronda1 r1)
    from public.campania_s7 c
   where c.origen = 'base'
     and c.baja_en is null
     and not public.campania_s7_ya_tiene(c.mail)
     and not exists (select 1 from public.miembros m
                      where lower(btrim(m.email)) = c.mail and m.estado_codigo = 'activo')

  union all

  -- los que tienen entradas sin dueño
  select 'sin_asignar'::text,
         public.como_le_dicen(t.apodo, coalesce(t.nombre_real,
           split_part(case when t.nota_admin like 'link de venta · %' then substr(t.nota_admin, 17)
                           when t.por_anfitrion is not null then substr(t.nota_admin, strpos(t.nota_admin, ' · ') + 3) end, ' ', 1))),
         btrim(coalesce(t.nombre_real, '') || ' ' || coalesce(t.apellido, '')),
         t.nombre_sektario,
         t.email,
         t.acepta_mails,
         t.ultima_visita,
         t.registrado_en,
         null::text,
         false,
         s.sin::integer,
         s.esperando::integer,
         exists (select 1 from public.entradas e where e.duenio = t.id and e.anulada_en is null),
         false,
         false
    from (select e.tenedor,
                 count(*) filter (where e.para_invitacion is null)     sin,
                 count(*) filter (where e.para_invitacion is not null) esperando
            from public.entradas e
           where e.evento = 'seki7' and e.anulada_en is null and e.duenio is null and e.externo_nombre is null
           group by e.tenedor) s
    join public.miembros t on t.id = s.tenedor;
end;
$$;

-- el ritmo: entradas que nacieron cada día (sin anuladas, sin staff ni free)
create or replace function public.admin_ritmo_s7(p_codigo text)
returns table(dia date, entradas integer)
language plpgsql stable security definer
set search_path to 'public'
as $$
begin
  perform public.admin_id_de(p_codigo);
  return query
    select (e.creada_en at time zone 'America/Argentina/Buenos_Aires')::date, count(*)::integer
      from public.entradas e
     where e.evento = 'seki7' and e.anulada_en is null and e.tipo in ('sekreta', 'hermética', 'abierta')
     group by 1 order by 1;
end;
$$;

revoke all on function public.admin_quien_falta(text) from public;
revoke all on function public.admin_ritmo_s7(text) from public;
grant execute on function public.admin_quien_falta(text) to anon, authenticated;
grant execute on function public.admin_ritmo_s7(text) to anon, authenticated;
