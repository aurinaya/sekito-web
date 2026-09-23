-- ============================================================================
-- SÉKITO — los tres avisos
-- ============================================================================
--   1. te susurraron            -> al toque
--   2. entró alguien por tu mano -> al toque
--   3. te piden que des fe       -> un resumen por día, a la tarde
--
-- Por qué el tercero es distinto: los pedidos de fe llegan en ráfaga. Juan
-- Pablo declaró sus ritos de una sentada y generó 16 pedidos repartidos entre
-- 7 personas; con un mail por pedido, Naya habría recibido seis en un minuto.
-- Eso no es avisar, es lo que uno marca como spam sin leer.
--
-- Y el resumen avisa UNA sola vez por pedido, no todos los días lo que sigue
-- pendiente. En los ritos no existe rechazar: el que no quiere contestar
-- simplemente no contesta, y un mail que te persigue contradice eso.
--
-- Ningún mail lleva adentro lo que pasó: el susurro no viaja por correo, el
-- pedido no dice quién más te nombró. El mail avisa, el portal cuenta.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. la marca de "ya avisé"
-- ----------------------------------------------------------------------------
alter table public.validaciones
  add column if not exists avisado_en timestamptz;

-- lo que ya existe no se avisa: son pedidos viejos que la gente ya vio en el
-- portal, y mandar dieciséis mails de golpe el primer día sería el peor
-- estreno posible
update public.validaciones
   set avisado_en = now()
 where avisado_en is null;


-- ----------------------------------------------------------------------------
-- 2. el sobre
-- ----------------------------------------------------------------------------
-- Todos los mails salen con la misma cara y con el pie de baja. El link de
-- baja no es cortesía: es lo que hace que quien no quiere esto pueda irse sin
-- pedirle permiso a nadie.
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
    || '<div style="font-size:10px;letter-spacing:.22em;color:#93A8AC;text-transform:uppercase">' || p_rotulo || '</div>'
    || '<div style="font-size:21px;letter-spacing:.12em;margin:28px 0 18px">' || p_titulo || '</div>'
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


-- ----------------------------------------------------------------------------
-- 3. a quién se le puede escribir
-- ----------------------------------------------------------------------------
-- Un solo lugar que decide. LA SEKTA no tiene casilla, los dados de baja no
-- reciben nada, y el que dijo que no, no.
create or replace function public.a_quien_escribirle(p_miembro uuid)
returns table (email text, baja uuid)
language sql
stable
security definer
set search_path = public
as $$
  select m.email, m.baja_mails
    from public.miembros m
   where m.id = p_miembro
     and m.estado_codigo = 'activo'
     and m.acepta_mails
     and m.email is not null
     and m.email like '%@%';
$$;


-- ----------------------------------------------------------------------------
-- 4. te susurraron
-- ----------------------------------------------------------------------------
-- El texto del susurro NO va en el mail. Si viajara por correo, el susurro
-- dejaría de vivir en el portal y pasaría a vivir en Gmail: se pierde lo
-- privado, lo que no se responde, y el tener que entrar.
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
    public.mail_armado(
      'sékito',
      'ALGUIEN TE SUSURRÓ',
      'No dice quién, no dice qué.<br>Eso se escucha adentro.',
      v_quien.baja));

  return new;
exception when others then
  -- que un mail que no salió nunca impida dejar un susurro
  return new;
end;
$$;

drop trigger if exists susurros_avisan on public.susurros;
create trigger susurros_avisan
  after insert on public.susurros
  for each row execute function public.avisar_susurro();


-- ----------------------------------------------------------------------------
-- 5. entró alguien por tu mano
-- ----------------------------------------------------------------------------
-- El único de los tres que trae una buena noticia en vez de pedir algo.
create or replace function public.avisar_ingreso()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_quien record;
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
      'AHORA ES ' || new.nombre_sektario,
      'Entró por tu mano.<br>Tu rama del árbol tiene una persona más.',
      v_quien.baja));

  return new;
exception when others then
  return new;
end;
$$;

-- en update y no en insert: el nombre sektario se escribe un instante después
-- de crear la fila, y sin él el mail no tendría qué decir
drop trigger if exists ingresos_avisan on public.miembros;
create trigger ingresos_avisan
  after update of nombre_sektario on public.miembros
  for each row
  when (old.nombre_sektario is null and new.nombre_sektario is not null)
  execute function public.avisar_ingreso();


-- ----------------------------------------------------------------------------
-- 6. te piden que des fe — el resumen del día
-- ----------------------------------------------------------------------------
-- Junta lo que todavía no se avisó, manda un mail por persona, y lo marca.
-- Lo que quedó pendiente de ayer no vuelve a salir.
create or replace function public.avisar_pedidos_del_dia()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fila    record;
  v_mandados int := 0;
begin
  for v_fila in
    select v.validado_por as a_quien,
           count(*)       as cuantos,
           array_agg(v.id) as ids
      from public.validaciones v
     where v.validado_en is null
       and v.avisado_en  is null
     group by v.validado_por
  loop
    declare v_quien record;
    begin
      select * into v_quien from public.a_quien_escribirle(v_fila.a_quien);

      if v_quien.email is not null then
        perform public.mandar_mail(
          v_quien.email,
          case when v_fila.cuantos = 1
               then 'te piden que des fe'
               else 'te piden que des fe de ' || v_fila.cuantos || ' ritos' end,
          public.mail_armado(
            'los ritos',
            case when v_fila.cuantos = 1
                 then 'ALGUIEN TE NOMBRÓ TESTIGO'
                 else v_fila.cuantos || ' TE NOMBRARON TESTIGO' end,
            case when v_fila.cuantos = 1
                 then 'Dice que estuviste ahí.<br>Solo vos podés confirmarlo.'
                 else 'Dicen que estuviste ahí.<br>Solo vos podés confirmarlo.' end,
            v_quien.baja));
        v_mandados := v_mandados + 1;
      end if;

      -- se marca aunque no se haya podido mandar: si alguien no tiene mail o
      -- se dio de baja, el pedido igual quedó avisado en el portal, y no hay
      -- que volver a intentarlo todos los días
      update public.validaciones
         set avisado_en = now()
       where id = any(v_fila.ids);
    end;
  end loop;

  return v_mandados;
end;
$$;

revoke all on function public.mail_armado(text, text, text, uuid)  from public, anon, authenticated;
revoke all on function public.a_quien_escribirle(uuid)             from public, anon, authenticated;
revoke all on function public.avisar_pedidos_del_dia()             from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 7. el reloj
-- ----------------------------------------------------------------------------
-- 21:00 UTC son las 18:00 en Buenos Aires. A la tarde y no a la mañana: esto
-- es un portal de fiestas, no una oficina.
select cron.unschedule('pedidos-de-fe')
 where exists (select 1 from cron.job where jobname = 'pedidos-de-fe');

select cron.schedule('pedidos-de-fe', '0 21 * * *',
                     'select public.avisar_pedidos_del_dia();');


-- ============================================================================
-- Verificación
-- ============================================================================
-- select jobname, schedule, active from cron.job;
-- select public.avisar_pedidos_del_dia();   -> cuántos mails salieron
