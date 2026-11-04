-- sekito.ar/s7 (04/11): ya no es la intro con el botón al portal, es la compra
-- directa de LA SEKTA, como /mau o /lapochi, pero con llave: el link se sube a
-- instagram y la sekta sigue sabiendo a quién le vende. Sin llave: "no tengo
-- mi llave" lleva al pedido de siempre (/?pedir).
-- tanda abierta $40.000 y remil $50.000; cupo 0 esconde el de $35.000.
-- Los textos viven en PROPIO.s7 (index.html): se corre con el sitio publicado.

alter table public.anfitriones add column if not exists pide_llave boolean not null default false;
-- "s7" tiene dos letras: la palabra pasa a aceptar de 2 a 30
alter table public.anfitriones drop constraint anfitriones_palabra_check;
alter table public.anfitriones add constraint anfitriones_palabra_check check (palabra ~ '^[a-z0-9]{2,30}$');

CREATE OR REPLACE FUNCTION public.anfitrion_comprar(p_palabra text, p_codigo text, p_nombre text, p_email text, p_cantidad integer, p_banca boolean, p_base64 text, p_tipo text, p_remil boolean DEFAULT false, p_aporte integer DEFAULT NULL::integer)
 RETURNS TABLE(ok boolean, email text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_a      record;
  v_yo     uuid;
  v_ya     boolean := false;
  v_reg    boolean;
  v_mail   text := lower(btrim(coalesce(p_email, '')));
  v_nombre text := btrim(coalesce(p_nombre, ''));
  v_tanda  record;
  v_precio integer;
  v_bytes  bytea;
  v_cod    text;
  v_quien  text;
begin
  select * into v_a from public.anfitriones a
   where a.palabra = lower(btrim(coalesce(p_palabra, ''))) for update;
  if v_a.id is null then raise exception 'no_existe'; end if;
  if not v_a.activo or now() >= v_a.hasta then raise exception 'cerrado'; end if;

  if p_cantidad is null or p_cantidad < 1 or p_cantidad > 7 then raise exception 'cantidad_invalida'; end if;

  -- sekito.ar/s7 se sube a instagram: ahí se compra solo con llave
  if v_a.pide_llave and nullif(btrim(coalesce(p_codigo, '')), '') is null then raise exception 'falta_llave'; end if;

  if coalesce(btrim(p_base64), '') = '' then raise exception 'sin_comprobante'; end if;
  v_bytes := decode(p_base64, 'base64');
  if octet_length(v_bytes) > 3000000 then raise exception 'comprobante_pesado'; end if;

  -- el precio: el del cumple mientras quede cupo
  if p_aporte is not null then
    -- lo que cada uno puede (sekito.ar/tano): uno por persona, mientras quede cupo
    if v_a.aportes is null or not (p_aporte = any(v_a.aportes)) then raise exception 'precio_invalido'; end if;
    if p_cantidad <> 1 then raise exception 'cantidad_invalida'; end if;
    if public.aportes_usados(v_a.id) >= v_a.cupo_aporte then raise exception 'sin_aportes'; end if;
    select * into v_tanda from public.tandas t where t.id = v_a.tanda_bancar;
    v_precio := p_aporte;
  elsif coalesce(p_remil, false) then
    if v_a.precio_remil is null then raise exception 'precio_invalido'; end if;
    select * into v_tanda from public.tandas t where t.id = v_a.tanda_bancar;
    v_precio := v_a.precio_remil;
  elsif p_banca then
    select * into v_tanda from public.tandas t where t.id = v_a.tanda_bancar;
    v_precio := v_tanda.precio;
  else
    if public.cupo_usado(v_a.id) + p_cantidad > v_a.cupo then raise exception 'sin_cupo'; end if;
    select * into v_tanda from public.tandas t where t.id = v_a.tanda_cumple;
    v_precio := v_tanda.precio;
  end if;

  -- quién compra: su llave, su mail, o alguien nuevo
  if nullif(btrim(coalesce(p_codigo, '')), '') is not null then
    v_yo := public.miembro_de(p_codigo);
  else
    if v_nombre = '' then raise exception 'falta_nombre'; end if;
    if char_length(v_nombre) > 60 then raise exception 'nombre_largo'; end if;
    if v_mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'mail_invalido'; end if;

    select m.id, m.nombre_real is not null into v_yo, v_reg
      from public.miembros m
     where m.estado_codigo in ('activo', 'simbolico') and lower(btrim(m.email)) = v_mail
     limit 1;

    if v_yo is not null then
      v_ya := v_reg;     -- solo se marca si ya era de la sekta de verdad
    else
      -- un freno para que nadie llene la base desde afuera
      if (select count(*) from public.miembros m where m.por_anfitrion = v_a.id) >= (case when v_a.es_cumple then 120 else 2000 end) then
        raise exception 'muchos_pedidos';
      end if;
      select coalesce(v_a.quien_dice, public.como_le_dicen(m.apodo, m.nombre_real)) into v_quien
        from public.miembros m where m.id = v_a.anfitrion;
      v_cod := public.generar_codigo_acceso();
      insert into public.miembros (codigo_acceso, nota_admin, invitado_por, estado_codigo, email,
                                   como_llegaste, por_anfitrion)
      values (v_cod, v_a.palabra || ' · ' || v_nombre, v_a.anfitrion, 'activo', v_mail,
              case when v_a.es_cumple then 'por el cumple de ' else 'por ' end || v_quien,
              v_a.id)
      returning miembros.id into v_yo;
    end if;
  end if;

  if p_aporte is not null and exists (
       select 1 from public.compras c
        where c.comprador = v_yo and c.anfitrion_id = v_a.id and c.estado in ('a_revisar', 'confirmada')
          and c.precio_unitario = any(v_a.aportes)) then
    raise exception 'ya_aportaste';
  end if;

  -- dos compras en revisión por persona alcanzan
  if (select count(*) from public.compras c where c.comprador = v_yo and c.estado = 'a_revisar') >= 2 then
    raise exception 'ya_hay_compras';
  end if;

  insert into public.compras (comprador, tanda_id, cantidad, precio_unitario, total,
                              comprobante, comprobante_tipo, estado, anfitrion_id, mail_ya_estaba)
  values (v_yo, v_tanda.id, p_cantidad, v_precio, v_precio * p_cantidad,
          v_bytes, coalesce(nullif(btrim(p_tipo), ''), 'image/jpeg'), 'a_revisar', v_a.id, v_ya);

  -- el mail de "llegó" solo a quien ya está en el portal; al nuevo le llega
  -- su link cuando se confirme
  if exists (select 1 from public.miembros m where m.id = v_yo and m.nombre_real is not null) then
    perform public.mail_de_preventa(
      v_yo, 'seki 7', 'TU COMPROBANTE LLEGÓ',
      'La sekta lo va a mirar.<br>Cuando esté confirmado, te escribimos de nuevo.',
      'la sekta tiene tu comprobante');
  end if;

  return query select true,
    case when nullif(btrim(coalesce(p_codigo, '')), '') is null then v_mail end;
end;
$function$
;

insert into public.anfitriones (palabra, anfitrion, frase, tanda_cumple, tanda_bancar, cupo, hasta,
                                es_cumple, quien_dice, foto, instagram, precio_remil, pide_llave)
select 's7', m.id, 'El sékito te llama...',
       (select t.id from public.tandas t where t.nombre = 'hermética'),
       (select t.id from public.tandas t where t.nombre = 'abierta'),
       0, '2026-11-14 20:00:00-03'::timestamptz,
       false, 'la sekta', null, null, 50000, true
  from public.miembros m where m.nombre_sektario = 'LA SEKTA';
