-- ---------------------------------------------------------------------------
-- EL TOPE DE LA FILA SUBE DE 90 A 98 POR DÍA (15/10)
-- Resend gratis manda 100 por día, y todo sale por esta fila (mandar_mail_ya
-- solo lo llama despachar_mails): el margen de 10 era de más. Quedan 2.
-- Con Resend Pro, subirlo de nuevo acá.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.despachar_mails()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tope_dia constant int := 98;
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
$function$

;
