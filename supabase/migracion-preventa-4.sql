-- ============================================================================
-- SÉKITO — los mails de la preventa, cuarta vuelta: sólo textos
-- ============================================================================
-- · Se dice SEKI 7, a secas. Nunca "la SEKI 7".
-- · El rechazo decía "entrá al portal y volvé a subirlo", y el portal no deja
--   volver a subir un comprobante rechazado. En vez de construir ese camino
--   para un caso que todavía no pasó nunca: somos una fiesta chica, de gente
--   conocida. Si pasa, la sekta le escribe a la persona.
--
-- Sacadas de la base con pg_get_functiondef y tocadas sólo en el texto, para
-- no reescribir lógica de memoria. Se puede correr más de una vez.
-- ============================================================================

create or replace function public.admin_confirmar_compra(p_codigo text, p_compra uuid)
 RETURNS TABLE(ok boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_admin uuid := public.admin_id_de(p_codigo);
  v_c     record;
  v_faltan integer;
begin
  update public.compras c
     set estado = 'confirmada', revisada_por = v_admin, revisada_en = now(), motivo = null
   where c.id = p_compra and c.estado = 'a_revisar'
  returning c.comprador, c.cantidad into v_c;

  if not found then raise exception 'compra_no_revisable'; end if;

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'confirmar_compra', v_c.comprador, jsonb_build_object('compra', p_compra));

  select count(*) into v_faltan
    from public.entradas e where e.compra_id = p_compra and e.duenio is null;

  -- a los que ya tenían nombre puesto antes de que la plata estuviera
  -- confirmada, el trigger no les avisó: se avisa acá
  perform public.avisar_asignacion_suelta(e.id)
     from public.entradas e
    where e.compra_id = p_compra and e.duenio is not null and e.duenio <> e.tenedor;

  perform public.mail_de_preventa(
    v_c.comprador,
    'seki 7',
    'tu lugar está',
    case when v_faltan = 0
         then 'La sekta vio tu transferencia. Ya está.'
         else 'La sekta vio tu transferencia. Te quedan <strong>' || v_faltan ||
              '</strong> sin asignar: entrá al portal y decidí de quién son.' end,
    'tu lugar en seki 7 está confirmado');

  return query select true;
end;
$function$
;
create or replace function public.admin_rechazar_compra(p_codigo text, p_compra uuid, p_motivo text)
 RETURNS TABLE(ok boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_admin  uuid := public.admin_id_de(p_codigo);
  v_c      record;
  v_motivo text := nullif(btrim(coalesce(p_motivo, '')), '');
begin
  if v_motivo is null then raise exception 'falta_motivo'; end if;

  update public.compras c
     set estado = 'rechazada', revisada_por = v_admin, revisada_en = now(), motivo = v_motivo
   where c.id = p_compra and c.estado = 'a_revisar'
  returning c.comprador into v_c;

  if not found then raise exception 'compra_no_revisable'; end if;

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'rechazar_compra', v_c.comprador,
          jsonb_build_object('compra', p_compra, 'motivo', v_motivo));

  perform public.mail_de_preventa(
    v_c.comprador, 'seki 7', 'algo no cierra',
    v_motivo || '<br><br>La sekta te va a escribir.',
    'tu compra de seki 7 necesita una vuelta más');

  return query select true;
end;
$function$
;
create or replace function public.avisar_asignacion_suelta(p_entrada uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_e record;
  v_de text;
begin
  select e.duenio, e.tenedor into v_e
    from public.entradas e where e.id = p_entrada;

  if v_e.duenio is null or v_e.duenio = v_e.tenedor then return; end if;

  select public.nombre_lindo(m.nombre_real) into v_de
    from public.miembros m where m.id = v_e.tenedor;

  perform public.mail_de_preventa(
    v_e.duenio, 'seki 7', 'tenés tu lugar',
    coalesce(v_de, 'Alguien') || ' te dio una entrada para SEKI 7.' ||
    '<br><br>Te va a llegar el QR por separado.',
    'tenés tu lugar en seki 7');
end;
$function$
;
