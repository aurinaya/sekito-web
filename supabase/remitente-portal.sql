-- 17/11/2026 · los mails llegan de "El Portal del SÉKITO" (antes decía SÉKITO)

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
                        'from',    'El Portal del SÉKITO <portal@sekito.ar>',
                        'to',      jsonb_build_array(p_para),
                        'subject', p_asunto,
                        'html',    p_html)
         )
    into v_envio;

  return v_envio;
end;
$function$

;
