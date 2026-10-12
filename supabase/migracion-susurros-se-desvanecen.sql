-- ---------------------------------------------------------------------------
-- LOS SUSURROS SE DESVANECEN (12/10)
--
-- Como un susurro de verdad: se escucha una vez. Llega cerrado ("MAU te
-- susurró · 12 de octubre"); al abrirlo se lee durante 77 segundos y se
-- desvanece. Queda el rastro (quién y cuándo), nunca más el texto.
--
--   * el reloj lo lleva la base (abierto_en): recargar no da otros 77
--   * quien lo manda tampoco vuelve a ver el texto: si lo viera hasta que el
--     otro lo abre, se enteraría de que lo abrió (y no hay visto)
--   * si nadie lo abre, espera cerrado; los domingos a las 19 h llega un
--     recordatorio a quien tenga susurros sin escuchar hace más de 3 días
--   * el texto NO se borra: queda en la base, sin que la web ni el panel lo
--     muestren nunca. Solo para verificar una denuncia, si MAU lo pide.
--     Por eso el portal dice "se desvanece" y no promete que se borra.
--   * los que ya existían vuelven a cerrarse: se escuchan una última vez
--
-- Sigue igual: 90 caracteres, uno por persona cada 7 días, sin respuesta,
-- sin visto, no se retira, y el panel borra pero no lee.
-- ---------------------------------------------------------------------------

alter table public.susurros add column if not exists abierto_en timestamptz;
update public.susurros set abierto_en = null;

create or replace function public.susurro_dura()
returns interval language sql immutable as $$ select interval '77 seconds' $$;

-- el estado de un susurro para quien lo recibe
create or replace function public.estado_susurro(p_abierto timestamptz)
returns text language sql stable set search_path = public as $$
  select case when p_abierto is null then 'cerrado'
              when now() < p_abierto + public.susurro_dura() then 'abierto'
              else 'desvanecido' end;
$$;

drop function if exists public.mis_susurros(text);
create function public.mis_susurros(p_codigo text)
returns table(id uuid, mio boolean, sektario text, nombre text, texto text,
              creado_en timestamptz, estado text, quedan integer)
language plpgsql security definer set search_path = public as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  return query
    -- los que me dejaron: el texto solo viaja mientras está abierto
    select s.id, false, m.nombre_sektario, public.como_le_dicen(m.apodo, m.nombre_real),
           case when public.estado_susurro(s.abierto_en) = 'abierto' then s.texto end,
           s.creado_en, public.estado_susurro(s.abierto_en),
           case when public.estado_susurro(s.abierto_en) = 'abierto'
                then ceil(extract(epoch from (s.abierto_en + public.susurro_dura() - now())))::int end
      from public.susurros s
      join public.miembros m on m.id = s.de
     where s.para = v_yo

    union all

    -- los que dejé yo: a quién y cuándo, sin texto ni estado (no hay visto)
    select s.id, true, m.nombre_sektario, public.como_le_dicen(m.apodo, m.nombre_real),
           null::text, s.creado_en, null::text, null::int
      from public.susurros s
      join public.miembros m on m.id = s.para
     where s.de = v_yo

     order by 2, 6 desc;
end;
$$;

-- abrirlo: arranca el reloj (una sola vez) y devuelve el texto mientras dura
create or replace function public.escuchar_susurro(p_codigo text, p_id uuid)
returns table(texto text, quedan integer, estado text)
language plpgsql security definer set search_path = public as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
  v_s  record;
begin
  update public.susurros s
     set abierto_en = coalesce(s.abierto_en, now()),
         leido_en   = coalesce(s.leido_en, now())
   where s.id = p_id and s.para = v_yo
  returning s.texto, s.abierto_en into v_s;

  if v_s is null then
    raise exception 'ese_susurro_no_esta';
  end if;

  if public.estado_susurro(v_s.abierto_en) <> 'abierto' then
    return query select null::text, 0, 'desvanecido'::text;
    return;
  end if;

  return query
    select v_s.texto,
           ceil(extract(epoch from (v_s.abierto_en + public.susurro_dura() - now())))::int,
           'abierto'::text;
end;
$$;

-- el número del perfil: sin escuchar = cerrados
create or replace function public.susurros_nuevos(p_codigo text)
returns table(nuevos integer, total integer)
language plpgsql security definer set search_path = public as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  return query
    select count(*) filter (where s.abierto_en is null)::int, count(*)::int
      from public.susurros s
     where s.para = v_yo;
end;
$$;

-- los domingos: a quien tenga susurros cerrados hace más de 3 días
create or replace function public.avisar_susurros_sin_escuchar()
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_f record;
  v_n int := 0;
begin
  for v_f in
    select q.email, q.baja, count(*)::int as cuantos
      from public.susurros s
      cross join lateral public.a_quien_escribirle(s.para) q
     where s.abierto_en is null
       and q.email is not null
     group by q.email, q.baja
    having min(s.creado_en) < now() - interval '3 days'
  loop
    perform public.encolar_mail(
      v_f.email,
      'susurros sin escuchar',
      public.mail_armado('',
        case when v_f.cuantos = 1 then 'TENÉS UN SUSURRO SIN ESCUCHAR'
             else 'TENÉS ' || v_f.cuantos || ' SUSURROS SIN ESCUCHAR' end,
        'se escuchan una sola vez, adentro', v_f.baja),
      3::smallint);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

revoke execute on function public.avisar_susurros_sin_escuchar() from public, anon, authenticated;

select cron.unschedule('susurros-sin-escuchar')
 where exists (select 1 from cron.job where jobname = 'susurros-sin-escuchar');
select cron.schedule('susurros-sin-escuchar', '0 22 * * 0',   -- domingo 19 h en Buenos Aires
                     'select public.avisar_susurros_sin_escuchar();');

-- la ficha: "le susurraste el 12 de octubre", sin el texto
CREATE OR REPLACE FUNCTION public.ficha_del_sekito(p_codigo text, p_sektario text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_yo  uuid := public.miembro_de(p_codigo);
  v_id  uuid;
  v_res jsonb;
begin
  select m.id into v_id
    from public.miembros m
   where m.nombre_sektario = btrim(coalesce(p_sektario, ''))
     and m.estado_codigo in ('activo', 'simbolico');

  if v_id is null then
    raise exception 'no_esta_en_el_padron';
  end if;

  with recursive rama as (
    select m.id, 1 as profundidad
      from public.miembros m
     where m.invitado_por = v_id
       and m.estado_codigo in ('activo', 'simbolico')

    union all

    select h.id, r.profundidad + 1
      from public.miembros h
      join rama r on h.invitado_por = r.id
     where r.profundidad < 20   -- red de seguridad; los ciclos los frena un trigger
       and h.estado_codigo in ('activo', 'simbolico')
  )
  select jsonb_build_object(
    'sektario',  m.nombre_sektario,
    'nombre',    public.como_le_dicen(m.apodo, m.nombre_real),
    'pantalla',  m.pantalla,
    'fundador',  m.es_fundador,
    'es_sekta',  (m.estado_codigo = 'simbolico'),
    'es_vos',    (m.id = v_yo),
    'desde',     least(
                   m.fecha_ingreso,
                   (select min(f.fecha)
                      from public.asistencias a
                      join public.fiestas f on f.id = a.fiesta_id
                     where a.miembro_id = m.id and a.estado = 'confirmada')
                 ),
    'guia',      (select jsonb_build_object(
                           'sektario', q.nombre_sektario,
                           'nombre',   public.como_le_dicen(q.apodo, q.nombre_real))
                    from public.miembros q where q.id = m.invitado_por),
    'directos',  (select count(*) from rama where profundidad = 1),
    'total',     (select count(*) from rama),
    'ritos',     coalesce((
                   select jsonb_agg(jsonb_build_object(
                            'nombre', f.nombre,
                            'fecha',  f.fecha
                          ) order by f.fecha desc)
                     from public.asistencias a
                     join public.fiestas f on f.id = a.fiesta_id
                    where a.miembro_id = m.id
                      and a.estado = 'confirmada'
                 ), '[]'::jsonb),
    'susurro',   case
                   when m.id = v_yo or m.estado_codigo = 'simbolico' then null
                   else coalesce(
                     (select jsonb_build_object(
                               'mio',   true,
                               'desde', s.creado_en,
                               'dias',  greatest(0, 7 - floor(extract(epoch from (now() - s.creado_en)) / 86400)::int))
                        from public.susurros s
                       where s.de = v_yo and s.para = m.id
                         and s.creado_en > now() - interval '7 days'
                       order by s.creado_en desc
                       limit 1),
                     jsonb_build_object('mio', false))
                 end
  ) into v_res
  from public.miembros m
 where m.id = v_id;

  return v_res;
end;
$function$;
