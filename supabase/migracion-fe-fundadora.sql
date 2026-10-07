-- ============================================================================
-- SÉKITO — la fe fundadora (temporal)
-- ============================================================================
-- Decidido con Mau el 06/10/2026, para agilizar la etapa inicial: si uno de
-- los dos testigos es un fundador (MAU, NAYA, FLOR) o LA SEKTA, con su fe
-- alcanza. El rito queda atestiguado en el momento, sin esperar al otro.
--
-- Se sigue nombrando a dos: el juego no cambia. Al otro testigo el pedido se
-- le va solo (de su lista, del resumen diario y, si era LA SEKTA, del panel),
-- sin aviso: como con "no recuerdo", nadie le dice que ya no hacía falta. La
-- fila queda en la base tal cual, por si la regla se saca.
--
-- Vale también para atrás: los ritos que ya tenían la fe de uno de ellos
-- quedan atestiguados al aplicar esto.
--
-- Es temporal: a partir de SEKI 7 la entrada valida de verdad. Para sacarla,
-- da_fe_sola() devuelve false y listo (los pedidos que quedaron en pausa
-- vuelven a aparecer solos, porque las filas nunca se tocaron; los ritos ya
-- atestiguados quedan atestiguados).
-- ============================================================================

-- quién da fe sin necesitar a nadie más
create or replace function public.da_fe_sola(p_miembro uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1 from public.miembros m
     where m.id = p_miembro
       and (m.es_fundador or m.id = public.id_la_sekta())
  );
$$;
revoke execute on function public.da_fe_sola(uuid) from public, anon, authenticated;


-- dar fe: con la de un fundador alcanza
create or replace function public.dar_fe(p_codigo text, p_validacion uuid)
returns table(rito_completo boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_yo         uuid := public.miembro_de(p_codigo);
  v_asistencia uuid;
  v_fiesta     uuid;
  v_faltan     int;
  v_completo   boolean;
begin
  select v.asistencia_id, a.fiesta_id into v_asistencia, v_fiesta
    from public.validaciones v
    join public.asistencias a on a.id = v.asistencia_id
   where v.id = p_validacion
     and v.validado_por = v_yo
     and v.validado_en is null;

  if v_asistencia is null then
    raise exception 'no_te_toca';
  end if;

  if not public.esta_atestiguado(v_yo, v_fiesta) then
    raise exception 'todavia_no_podes';
  end if;

  update public.validaciones v set validado_en = now() where v.id = p_validacion;

  -- si ya no falta ninguno, o si el que dio fe es fundador, el rito queda atestiguado
  select count(*) into v_faltan
    from public.validaciones v
   where v.asistencia_id = v_asistencia and v.validado_en is null;
  v_completo := v_faltan = 0 or public.da_fe_sola(v_yo);

  if v_completo then
    update public.asistencias a set estado = 'confirmada' where a.id = v_asistencia;
  end if;

  return query select v_completo;
end;
$function$;


-- LA SEKTA, desde el panel: también alcanza sola
create or replace function public.admin_dar_fe_sekta(p_codigo text, p_validacion uuid)
returns table(rito_completo boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_admin      uuid := public.admin_id_de(p_codigo);
  v_asistencia uuid;
  v_sekta      uuid;
  v_faltan     int;
  v_completo   boolean;
begin
  select v.asistencia_id, v.validado_por into v_asistencia, v_sekta
    from public.validaciones v
    join public.miembros s on s.id = v.validado_por and s.estado_codigo = 'simbolico'
   where v.id = p_validacion
     and v.validado_en is null;

  if v_asistencia is null then
    raise exception 'ese_pedido_no_es_de_la_sekta';
  end if;

  update public.validaciones v
     set validado_en = now(), confirmado_por_admin = v_admin
   where v.id = p_validacion;

  select count(*) into v_faltan
    from public.validaciones v
   where v.asistencia_id = v_asistencia and v.validado_en is null;
  v_completo := v_faltan = 0 or public.da_fe_sola(v_sekta);

  if v_completo then
    update public.asistencias a set estado = 'confirmada' where a.id = v_asistencia;
  end if;

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  select v_admin, 'dar_fe_sekta', a.miembro_id,
         jsonb_build_object('fiesta', f.nombre)
    from public.asistencias a join public.fiestas f on f.id = a.fiesta_id
   where a.id = v_asistencia;

  return query select v_completo;
end;
$function$;


-- los pedidos de un rito ya atestiguado no se muestran: ni en tu lista...
create or replace function public.mis_pedidos(p_codigo text)
returns table(validacion_id uuid, quien text, quien_nombre text, fiesta text, fecha timestamp with time zone, puedo_ya boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  return query
    select v.id, m.nombre_sektario, public.como_le_dicen(m.apodo, m.nombre_real),
           f.nombre, f.fecha,
           public.esta_atestiguado(v_yo, f.id)
      from public.validaciones v
      join public.asistencias a on a.id = v.asistencia_id
      join public.miembros    m on m.id = a.miembro_id
      join public.fiestas     f on f.id = a.fiesta_id
     where v.validado_por = v_yo
       and v.validado_en    is null
       and v.no_recuerda_en is null
       and a.estado <> 'confirmada'
     order by f.fecha desc;
end;
$function$;


-- ...ni en el panel de LA SEKTA...
create or replace function public.admin_pedidos_sekta(p_codigo text)
returns table(validacion_id uuid, quien text, quien_real text, fiesta text, fecha timestamp with time zone, pedido_en timestamp with time zone)
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  perform public.admin_id_de(p_codigo);

  return query
    select v.id, m.nombre_sektario, m.nombre_real, f.nombre, f.fecha, a.creado_en
      from public.validaciones v
      join public.miembros    s on s.id = v.validado_por and s.estado_codigo = 'simbolico'
      join public.asistencias a on a.id = v.asistencia_id
      join public.miembros    m on m.id = a.miembro_id
      join public.fiestas     f on f.id = a.fiesta_id
     where v.validado_en is null
       and a.estado <> 'confirmada'
     order by a.creado_en;
end;
$function$;


-- ...ni en el resumen diario
create or replace function public.avisar_pedidos_del_dia()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_fila     record;
  v_mandados int := 0;
  v_sekta    uuid := public.id_la_sekta();
  v_cuantos  int;
  v_ids      uuid[];
  v_quien    record;
begin
  for v_fila in
    select v.validado_por as a_quien,
           count(*)       as cuantos,
           array_agg(v.id) as ids
      from public.validaciones v
      join public.asistencias a on a.id = v.asistencia_id
     where v.validado_en    is null
       and v.avisado_en     is null
       and v.no_recuerda_en is null
       and a.estado <> 'confirmada'
       and v.validado_por <> v_sekta
     group by v.validado_por
  loop
    select * into v_quien from public.a_quien_escribirle(v_fila.a_quien);

    if v_quien.email is not null then
      perform public.mandar_mail(
        v_quien.email,
        case when v_fila.cuantos = 1
             then 'te piden que des fe'
             else 'te piden que des fe de ' || v_fila.cuantos || ' ritos' end,
        public.mail_armado(
          'los ritos',
          case when v_fila.cuantos = 1
               then 'ALGUIEN TE NOMBRÓ TESTIGO'
               else v_fila.cuantos || ' TE NOMBRARON TESTIGO' end,
          case when v_fila.cuantos = 1
               then 'Dice que estuviste ahí.<br>Solo vos podés confirmarlo.'
               else 'Dicen que estuviste ahí.<br>Solo vos podés confirmarlo.' end,
          v_quien.baja));
      v_mandados := v_mandados + 1;
      perform pg_sleep(1.2);
    end if;

    update public.validaciones set avisado_en = now() where id = any(v_fila.ids);
  end loop;

  select count(*), array_agg(v.id) into v_cuantos, v_ids
    from public.validaciones v
    join public.asistencias a on a.id = v.asistencia_id
   where v.validado_en is null
     and v.avisado_en  is null
     and a.estado <> 'confirmada'
     and v.validado_por = v_sekta;

  if coalesce(v_cuantos, 0) > 0 then
    select * into v_quien
      from public.a_quien_escribirle((select id from public.miembros where nombre_sektario = 'MAU·000'));

    if v_quien.email is not null then
      perform public.mandar_mail(
        v_quien.email,
        case when v_cuantos = 1 then 'un rito espera a la sekta'
             else v_cuantos || ' ritos esperan a la sekta' end,
        public.mail_sobre(
          '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
          || 'font-size:10px;letter-spacing:.22em;color:#93A8AC;text-transform:uppercase;padding:0 0 14px">la sekta</td></tr>'
          || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
          || 'font-size:19px;line-height:1.5;letter-spacing:.1em;color:#F2F2F2;padding:0 0 14px">'
          || case when v_cuantos = 1 then 'TE NOMBRARON A LA SEKTA'
                  else v_cuantos || ' RITOS LA NOMBRARON' end || '</td></tr>'
          || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
          || 'font-size:13px;line-height:1.7;color:#93A8AC;padding:0 0 30px">'
          || 'La sekta no contesta sola.<br>Se confirma desde el panel.</td></tr>',
          v_quien.baja,
          'https://www.sekito.ar/admin/',
          'ir al panel'));
      v_mandados := v_mandados + 1;
    end if;

    update public.validaciones set avisado_en = now() where id = any(v_ids);
  end if;

  return v_mandados;
end;
$function$;


-- para atrás: los ritos que ya tenían la fe de un fundador o de LA SEKTA
update public.asistencias a
   set estado = 'confirmada'
 where a.estado <> 'confirmada'
   and exists (select 1 from public.validaciones v
                where v.asistencia_id = a.id
                  and v.validado_en is not null
                  and public.da_fe_sola(v.validado_por));
