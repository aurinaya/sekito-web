-- ---------------------------------------------------------------------------
-- LA FILA DE MAILS SIN TOPE DIARIO (09/11/2026)
-- Resend Pro está pago: no hay límite por día. La fila sigue saliendo de a 10
-- por minuto (el cron es cada minuto) y con 0,6 s entre uno y otro, para no
-- pasar los 2 por segundo de Resend.
-- Para volver al plan gratis: aplicar de nuevo migracion-tope-98.sql.
-- ---------------------------------------------------------------------------

create or replace function public.despachar_mails()
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_m record;
  v_n int := 0;
begin
  for v_m in
    select * from public.mails_en_fila
     where enviado_en is null
     order by prioridad, creado_en
     limit 10
     for update skip locked
  loop
    update public.mails_en_fila
       set enviado_en = now(),
           pedido_id  = public.mandar_mail_ya(v_m.para, v_m.asunto, v_m.html)
     where id = v_m.id;
    v_n := v_n + 1;
    perform pg_sleep(0.6);              -- Resend: hasta 2 por segundo
  end loop;

  return v_n;
end;
$function$;
