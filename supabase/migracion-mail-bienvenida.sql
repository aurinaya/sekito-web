-- ============================================================================
-- SÉKITO — la bienvenida, automática
-- ============================================================================
-- A partir de ahora, quien se registra recibe su llave por mail. El código se
-- sigue mostrando una sola vez en pantalla; el mail es el respaldo.
--
-- Dispara en el mismo momento que el aviso al que invitó: cuando se escribe
-- el nombre sektario, un instante después de crear la fila. Antes de eso la
-- persona todavía no tiene nombre y el mail no tendría qué decir.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================

create or replace function public.avisar_bienvenida()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_quien record;
begin
  select * into v_quien from public.a_quien_escribirle(new.id);
  if v_quien.email is null then
    return new;
  end if;

  perform public.mandar_mail(
    v_quien.email,
    'ya sos del sékito, acá está tu llave',
    public.mail_sobre(
      '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
      || 'font-size:19px;letter-spacing:.1em;color:#F2F2F2;padding:0 0 18px">YA SOS DEL SÉKITO</td></tr>'
      || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
      || 'font-size:13px;line-height:1.8;color:#93A8AC;padding:0 0 34px">'
      || 'Acá se crean nuestros ritos.<br>Pensados por amigxs, para amigxs.</td></tr>'
      || '<tr><td align="center" style="padding:0 0 30px">'
      ||   '<table role="presentation" cellpadding="0" cellspacing="0" border="0" '
      ||   'style="border:1px solid #2A2A2A;background:#141414"><tr><td align="center" style="padding:22px 40px">'
      ||     '<div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:9px;'
      ||     'letter-spacing:.22em;color:#93A8AC;text-transform:uppercase">tu código de acceso</div>'
      ||     '<div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:30px;'
      ||     'letter-spacing:.2em;color:#F2F2F2;padding-top:12px">' || new.codigo_acceso || '</div>'
      ||   '</td></tr></table>'
      || '</td></tr>'
      || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
      || 'font-size:12px;line-height:1.9;color:#93A8AC;padding:0 0 32px">'
      || 'Esta es tu llave para entrar al portal de la sekta.<br>'
      || 'Nadie tiene una igual.<br><br>'
      || 'Guardala. No la compartas.<br>'
      || '<span style="color:#F2F2F2">Si la perdés, la sekta decide...</span></td></tr>',
      v_quien.baja));

  return new;
exception when others then
  -- que un mail que no salió nunca impida que alguien entre al sékito
  return new;
end;
$$;

drop trigger if exists bienvenida_avisa on public.miembros;
create trigger bienvenida_avisa
  after update of nombre_sektario on public.miembros
  for each row
  when (old.nombre_sektario is null and new.nombre_sektario is not null)
  execute function public.avisar_bienvenida();


-- ----------------------------------------------------------------------------
-- listo para mandar, pero no mandado
-- ----------------------------------------------------------------------------
-- "la sekta se está construyendo", para los que ya están adentro. No lo
-- dispara nada: se corre a mano el día que MAU diga.
--
--   select public.contarles_que_se_construye();
--
-- Respeta a quien se dio de baja y saltea a LA SEKTA, porque pasa por
-- a_quien_escribirle igual que todo lo demás.
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
    end;
  end loop;

  return v_n;
end;
$$;

revoke all on function public.contarles_que_se_construye() from public, anon, authenticated;
