-- ============================================================================
-- SÉKITO — los envíos en tanda van de a uno
-- ============================================================================
-- Lo que pasó al rotar las 20 llaves: el bucle encoló los 20 mails de golpe,
-- pg_net los disparó todos juntos, y Resend aceptó 10 y rechazó 10 con un
-- 429 —"vas muy rápido"—. Diez personas quedaron con llave nueva y sin mail,
-- o sea afuera del portal sin manera de volver a entrar.
--
-- Se arregló reenviando esos diez de a uno. Esto evita que vuelva a pasar:
-- todo envío en tanda pone una pausa entre uno y otro.
--
-- Importante para el día de los 350: con pausa de un segundo son seis
-- minutos de una sola transacción, y eso ya es demasiado. Esa tanda hay que
-- cortarla en pedazos y mandarla con el reloj, no en un solo bucle.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================

create or replace function public.rotar_todas_las_llaves()
returns table (rotadas int, salteadas int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fila   record;
  v_nueva  text;
  v_ok     int := 0;
  v_no     int := 0;
begin
  for v_fila in
    select m.id, m.email, m.acepta_mails, m.baja_mails
      from public.miembros m
     where m.estado_codigo = 'activo'
     order by m.fecha_ingreso
  loop
    if v_fila.email is null or v_fila.email not like '%@%' or not v_fila.acepta_mails then
      v_no := v_no + 1;
      continue;
    end if;

    v_nueva := public.generar_codigo_acceso();
    update public.miembros set codigo_acceso = v_nueva where id = v_fila.id;
    perform public.mandar_mail(v_fila.email, 'tu llave cambió',
                               public.mail_llave_nueva(v_nueva, v_fila.baja_mails));
    v_ok := v_ok + 1;
    perform pg_sleep(1.2);   -- de a uno: Resend rechaza las ráfagas
  end loop;

  return query select v_ok, v_no;
end;
$$;


create or replace function public.contarles_que_se_construye()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fila  record;
  v_n     int := 0;
begin
  for v_fila in
    select m.id from public.miembros m
     where m.estado_codigo = 'activo'
     order by m.fecha_ingreso
  loop
    declare v_quien record;
    begin
      select * into v_quien from public.a_quien_escribirle(v_fila.id);
      if v_quien.email is null then continue; end if;

      perform public.mandar_mail(
        v_quien.email,
        'la sekta se está construyendo',
        public.mail_sobre(
          '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
          || 'font-size:19px;line-height:1.5;letter-spacing:.1em;color:#F2F2F2;padding:0 0 34px">'
          || 'LA SEKTA SE ESTÁ<br>CONSTRUYENDO</td></tr>'
          || public.mail_item('tus ritos',  'decís a qué fiestas viniste. dos testigos dan fe.')
          || public.mail_item('tu rama',    'de quién venís, y quiénes vinieron por vos.')
          || public.mail_item('devotxs',    'donde el sékito se busca y se encuentra.')
          || public.mail_item('susurros',   'noventa caracteres a una persona. no se responde.')
          || public.mail_item('invitar',    'un link para traer a alguien, de tu mano.')
          || public.mail_item('la sekta',   'no es nadie, y somos todos. usala.')
          || '<tr><td style="padding:0 0 12px"></td></tr>',
          v_quien.baja));
      v_n := v_n + 1;
      perform pg_sleep(1.2);
    end;
  end loop;

  return v_n;
end;
$$;


-- el resumen diario de pedidos de fe manda un mail por persona: con siete
-- personas ya está en la zona de riesgo
create or replace function public.avisar_pedidos_del_dia()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fila    record;
  v_mandados int := 0;
begin
  for v_fila in
    select v.validado_por as a_quien,
           count(*)       as cuantos,
           array_agg(v.id) as ids
      from public.validaciones v
     where v.validado_en is null
       and v.avisado_en  is null
     group by v.validado_por
  loop
    declare v_quien record;
    begin
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

      update public.validaciones
         set avisado_en = now()
       where id = any(v_fila.ids);
    end;
  end loop;

  return v_mandados;
end;
$$;

revoke all on function public.rotar_todas_las_llaves()     from public, anon, authenticated;
revoke all on function public.contarles_que_se_construye() from public, anon, authenticated;
revoke all on function public.avisar_pedidos_del_dia()     from public, anon, authenticated;
