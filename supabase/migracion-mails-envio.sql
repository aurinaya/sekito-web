-- ============================================================================
-- SÉKITO — la función que manda
-- ============================================================================
-- Una sola puerta de salida para todo lo que el portal mande por mail. Todo
-- lo demás (avisos de susurros, de dar fe, lo que venga) pasa por acá.
--
-- La clave de Resend vive cifrada en la bóveda de Supabase. Esta función es
-- la única que la lee, y la lee recién en el momento de mandar: no queda en
-- ninguna tabla, ni en el repo, ni en ningún log.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================

create or replace function public.mandar_mail(
  p_para   text,
  p_asunto text,
  p_html   text
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
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
$$;

-- Nadie la llama desde afuera: la usan los avisos del portal, desde adentro
-- de la base. Si algún día se pudiera invocar con la clave pública, cualquiera
-- podría mandar mails firmados como sekito.ar.
revoke all on function public.mandar_mail(text, text, text)
  from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- ver cómo salió
-- ----------------------------------------------------------------------------
-- pg_net guarda la respuesta aparte. Esto la busca por el número que devolvió
-- mandar_mail, para poder revisar un envío sin andar mirando tablas internas.
create or replace function public.como_salio_el_mail(p_envio bigint)
returns table (estado int, cuerpo text, error text)
language sql
security definer
set search_path = public
as $$
  select r.status_code, r.content, r.error_msg
    from net._http_response r
   where r.id = p_envio;
$$;

revoke all on function public.como_salio_el_mail(bigint)
  from public, anon, authenticated;
