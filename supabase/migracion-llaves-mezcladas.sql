-- ============================================================================
-- SÉKITO — las llaves dejan de parecerse a los nombres sektarios
-- ============================================================================
-- UXU499 y MAU·000 son primos visuales, y la gente los confunde. Mismo
-- alfabeto, misma cantidad, pero intercalados: U4X9U2.
--
-- No cambia nada de la seguridad —el mismo alfabeto en otro orden— solo deja
-- de leerse como un nombre.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================

create or replace function public.generar_codigo_acceso()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_codigo text;
  v_i      int;
begin
  for v_i in 1 .. 200 loop
    -- letra, número, letra, número, letra, número. Sin I ni O, que se
    -- confunden con 1 y 0 cuando alguien las lee de una captura de pantalla.
    v_codigo := public.azar_de('ABCDEFGHJKLMNPQRSTUVWXYZ', 1) || public.azar_de('0123456789', 1)
             || public.azar_de('ABCDEFGHJKLMNPQRSTUVWXYZ', 1) || public.azar_de('0123456789', 1)
             || public.azar_de('ABCDEFGHJKLMNPQRSTUVWXYZ', 1) || public.azar_de('0123456789', 1);

    if not exists (select 1 from public.miembros m where m.codigo_acceso = v_codigo) then
      return v_codigo;
    end if;
  end loop;

  raise exception 'No se pudo generar un código libre después de 200 intentos.';
end;
$$;

revoke all on function public.generar_codigo_acceso() from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- el mail de la llave nueva
-- ----------------------------------------------------------------------------
create or replace function public.mail_llave_nueva(p_codigo text, p_baja uuid)
returns text
language sql
immutable
set search_path = public
as $$
  select public.mail_sobre(
    '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
    || 'font-size:19px;letter-spacing:.1em;color:#F2F2F2;padding:0 0 18px">TU LLAVE CAMBIÓ</td></tr>'
    || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
    || 'font-size:13px;line-height:1.8;color:#93A8AC;padding:0 0 34px">'
    || 'La sekta rehízo todas las llaves.<br>La vieja ya no abre.</td></tr>'
    || '<tr><td align="center" style="padding:0 0 30px">'
    ||   '<table role="presentation" cellpadding="0" cellspacing="0" border="0" '
    ||   'style="border:1px solid #2A2A2A;background:#141414"><tr><td align="center" style="padding:22px 40px">'
    ||     '<div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:9px;'
    ||     'letter-spacing:.22em;color:#93A8AC;text-transform:uppercase">tu código de acceso</div>'
    ||     '<div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:30px;'
    ||     'letter-spacing:.2em;color:#F2F2F2;padding-top:12px">' || p_codigo || '</div>'
    ||   '</td></tr></table>'
    || '</td></tr>'
    || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
    || 'font-size:12px;line-height:1.9;color:#93A8AC;padding:0 0 32px">'
    || '<span style="color:#F2F2F2">Entrá una vez y el portal se acuerda de vos.</span><br>'
    || 'No vas a tener que volver a escribirla.<br><br>'
    || 'Guardala igual. No la compartas.<br>'
    || 'Si la perdés, la sekta decide qué hacer...</td></tr>',
    p_baja);
$$;

revoke all on function public.mail_llave_nueva(text, uuid) from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- la rotación
-- ----------------------------------------------------------------------------
-- Cambia la llave de todos los activos y se la manda por mail en el mismo
-- paso. Van juntos a propósito: una llave nueva sin el mail deja a la persona
-- afuera del portal sin manera de volver a entrar.
--
-- No lo dispara nada. Se corre a mano el día que MAU diga:
--
--   select * from public.rotar_todas_las_llaves();
--
-- Al que se dio de baja de los mails NO se le rota la llave: quedaría afuera
-- sin forma de enterarse. Esos se avisan por otro lado.
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
    select m.id, m.nombre_sektario, m.email, m.acepta_mails, m.baja_mails
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
  end loop;

  return query select v_ok, v_no;
end;
$$;

revoke all on function public.rotar_todas_las_llaves() from public, anon, authenticated;
