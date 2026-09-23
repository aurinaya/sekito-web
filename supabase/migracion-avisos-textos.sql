-- ============================================================================
-- SÉKITO — los textos de los avisos, segunda pasada
-- ============================================================================
-- El susurro pierde el rótulo de arriba: era una etiqueta que no decía nada
-- y le robaba aire a lo único que importa.
--
-- El de la rama gana el nombre de pila: "NATALIA, AHORA ES NTL·418" cuenta
-- una historia que "AHORA ES NTL·418" no cuenta.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================

-- el rótulo pasa a ser opcional: si va vacío, no se dibuja
create or replace function public.mail_armado(
  p_rotulo text,
  p_titulo text,
  p_bajada text,
  p_baja   uuid
)
returns text
language sql
immutable
set search_path = public
as $$
  select
    '<div style="background:#0D0D0D;color:#F2F2F2;font-family:ui-monospace,Menlo,monospace;padding:52px 28px;text-align:center;line-height:1.8">'
    || case when coalesce(btrim(p_rotulo),'') = '' then ''
            else '<div style="font-size:10px;letter-spacing:.22em;color:#93A8AC;text-transform:uppercase">'
                 || p_rotulo || '</div>' end
    || '<div style="font-size:21px;letter-spacing:.12em;margin:'
    || case when coalesce(btrim(p_rotulo),'') = '' then '0' else '28px' end
    || ' 0 18px">' || p_titulo || '</div>'
    || '<div style="font-size:13px;color:#93A8AC">' || p_bajada || '</div>'
    || '<div style="margin:38px 0 8px"><a href="https://www.sekito.ar" '
    || 'style="display:inline-block;border:1px solid #F2F2F2;color:#F2F2F2;text-decoration:none;'
    || 'font-size:11px;letter-spacing:.16em;text-transform:uppercase;padding:12px 26px">entrar al portal</a></div>'
    || '<div style="font-size:10px;color:#93A8AC;opacity:.55;margin-top:40px;line-height:2">'
    ||   'sekito.ar<br>'
    ||   '<a href="https://www.sekito.ar/?baja=' || p_baja::text || '" style="color:#93A8AC">no quiero más estos mails</a>'
    || '</div>'
    || '</div>';
$$;


create or replace function public.avisar_susurro()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_quien record;
begin
  select * into v_quien from public.a_quien_escribirle(new.para);
  if v_quien.email is null then
    return new;
  end if;

  perform public.mandar_mail(
    v_quien.email,
    'te susurraron',
    public.mail_armado('', 'ALGUIEN TE SUSURRÓ',
                       'solo se escucha adentro', v_quien.baja));

  return new;
exception when others then
  return new;
end;
$$;


create or replace function public.avisar_ingreso()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_quien  record;
  v_nombre text := public.nombre_lindo(new.nombre_real);
begin
  if new.invitado_por is null or new.nombre_sektario is null then
    return new;
  end if;

  select * into v_quien from public.a_quien_escribirle(new.invitado_por);
  if v_quien.email is null then
    return new;
  end if;

  perform public.mandar_mail(
    v_quien.email,
    'entró alguien por tu mano',
    public.mail_armado(
      'tu rama creció',
      case when v_nombre is null
           then 'AHORA ES ' || new.nombre_sektario
           else upper(v_nombre) || ', AHORA ES ' || new.nombre_sektario end,
      'entró de tu mano<br>al árbol de la sekta',
      v_quien.baja));

  return new;
exception when others then
  return new;
end;
$$;

revoke all on function public.mail_armado(text, text, text, uuid) from public, anon, authenticated;
