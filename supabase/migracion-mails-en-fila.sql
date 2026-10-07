-- ============================================================================
-- SÉKITO — todos los mails pasan por la fila (se aplica al lanzar SEKI 7)
-- ============================================================================
-- Hasta acá solo los mails de la preventa pasaban por mails_en_fila. Con la
-- venta abierta, un día movido (bienvenidas + avisos + compras) puede pasar
-- los 100 del plan gratis de Resend. Desde ahora mandar_mail no manda:
-- encola. La fila manda 90 por día, primero los que llevan código.
--
-- El envío de verdad queda en mandar_mail_ya, que solo usa la fila.
-- Ninguna función usaba lo que devolvía mandar_mail, así que nada cambia
-- para ellas.
--
-- OJO con los mails masivos (contarles_que_se_construye, ~350): tienen que
-- ir con prioridad 3, detrás de bienvenidas y entradas, o una bienvenida
-- podría esperar días.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.mandar_mail_ya(p_para text, p_asunto text, p_html text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_clave text;
  v_envio bigint;
begin
  select decrypted_secret into v_clave
    from vault.decrypted_secrets
   where name = 'resend_api_key';

  if v_clave is null then
    raise exception 'falta_la_clave';
  end if;

  -- pg_net no espera la respuesta: encola el pedido y sigue. Un mail que
  -- tarda no puede dejar colgado a quien apretó un botón en el portal.
  select net.http_post(
           url     := 'https://api.resend.com/emails',
           headers := jsonb_build_object(
                        'Authorization', 'Bearer ' || v_clave,
                        'Content-Type',  'application/json'),
           body    := jsonb_build_object(
                        'from',    'SÉKITO <portal@sekito.ar>',
                        'to',      jsonb_build_array(p_para),
                        'subject', p_asunto,
                        'html',    p_html)
         )
    into v_envio;

  return v_envio;
end;
$function$

;

revoke execute on function public.mandar_mail_ya(text, text, text) from public, anon, authenticated;

-- mandar_mail ya no manda: encola
create or replace function public.mandar_mail(p_para text, p_asunto text, p_html text)
returns bigint
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  perform public.encolar_mail(p_para, p_asunto, p_html, 2::smallint);
  return null;
end;
$$;

-- y la fila usa el envío de verdad
create or replace function public.despachar_mails()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tope_dia constant int := 90;
  v_hoy      int;
  v_m        record;
  v_n        int := 0;
begin
  select count(*) into v_hoy from public.mails_en_fila
   where enviado_en >= date_trunc('day', now() at time zone 'utc') at time zone 'utc';

  for v_m in
    select * from public.mails_en_fila
     where enviado_en is null
     order by prioridad, creado_en
     limit least(10, greatest(v_tope_dia - v_hoy, 0))
     for update skip locked
  loop
    update public.mails_en_fila
       set enviado_en = now(),
           pedido_id  = public.mandar_mail_ya(v_m.para, v_m.asunto, v_m.html)
     where id = v_m.id;
    v_n := v_n + 1;
    perform pg_sleep(0.6);              -- Resend gratis: hasta 2 por segundo
  end loop;

  return v_n;
end;
$$;
