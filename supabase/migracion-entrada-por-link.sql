-- ---------------------------------------------------------------------------
-- UNA ENTRADA POR LINK, DESDE EL PANEL (24/10)
--
-- Para quien compra por fuera (por instagram, transferencia directa) y
-- todavía no está en el portal: el panel crea la entrada guardada para una
-- invitación de LA SEKTA y da el link. Cuando la persona entra con ese link y
-- completa sus datos, la entrada pasa a su nombre sola (lo mismo que cuando un
-- miembro manda una entrada: migracion-entrada-con-invitacion.sql). El link
-- vale 14 días; si vence, la entrada vuelve a LA SEKTA sin asignar.
-- ---------------------------------------------------------------------------

create or replace function public.admin_entrada_con_link(p_codigo text, p_para text, p_tipo text,
                                                         p_precio integer, p_nota text default null)
returns table(entrada_id uuid, codigo text, vence_en timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  v_admin uuid := public.admin_id_de(p_codigo);
  v_para  text := nullif(btrim(coalesce(p_para, '')), '');
  v_sekta uuid := public.id_la_sekta();
  v_inv   uuid;
  v_cod   text;
  v_vence timestamptz;
  v_ent   uuid;
  v_i     int;
begin
  if v_para is null then raise exception 'falta_el_nombre'; end if;
  if p_tipo not in ('sekreta', 'hermética', 'abierta', 'staff', 'free') then raise exception 'tipo_invalido'; end if;
  if p_precio is null or p_precio < 0 then raise exception 'precio_invalido'; end if;

  -- la invitación, de LA SEKTA (el índice único evita repetir el código)
  for v_i in 1 .. 200 loop
    begin
      v_cod := public.azar_de('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 12);
      insert into public.invitaciones (generada_por, codigo, vence_en, para)
      values (v_sekta, v_cod, now() + interval '14 days', left(v_para, 60))
      returning id, invitaciones.vence_en into v_inv, v_vence;
      exit;
    exception when unique_violation then
      v_inv := null;
    end;
  end loop;
  if v_inv is null then raise exception 'no_se_pudo_generar'; end if;

  insert into public.entradas (compra_id, tenedor, tipo, precio, nota, generada_por, para_invitacion)
  values (null, v_sekta, p_tipo, p_precio,
          coalesce(nullif(btrim(coalesce(p_nota, '')), ''), 'por link'), v_admin, v_inv)
  returning id into v_ent;

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'entrada_por_link', null,
          jsonb_build_object('para', v_para, 'tipo', p_tipo, 'precio', p_precio, 'nota', p_nota));

  return query select v_ent, v_cod, v_vence;
end;
$$;

-- en la lista del panel: "guardada" es un estado propio, con su link a mano
drop function if exists public.admin_entradas_s7(text);
create function public.admin_entradas_s7(p_codigo text)
returns table(entrada_id uuid, codigo text, tipo text, precio integer, nombre text, apodo text, sektario text,
              email text, contacto text, de_afuera boolean, tenedor text, compro text, estado text, nota text,
              adentro_en timestamp with time zone, creada_en timestamp with time zone,
              guardada_para text, guardada_codigo text, guardada_vence timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_id_de(p_codigo);

  return query
    select e.id, e.codigo, e.tipo, e.precio,
           coalesce(nullif(trim(coalesce(public.nombre_lindo(d.nombre_real), '') || ' ' ||
                                coalesce(public.nombre_lindo(d.apellido), '')), ''),
                    nullif(trim(coalesce(e.externo_nombre, '') || ' ' || coalesce(e.externo_apellido, '')), '')),
           coalesce(d.apodo, e.externo_apodo),
           d.nombre_sektario,
           d.email,
           coalesce(d.telefono, e.externo_contacto),
           e.externo_nombre is not null,
           coalesce(public.como_le_dicen(te.apodo, te.nombre_real), te.nombre_sektario),
           public.como_le_dicen(cm.apodo, cm.nombre_real),
           case when e.anulada_en is not null then 'anulada'
                when e.adentro_en is not null then 'adentro'
                when e.duenio is null and e.externo_nombre is null and inv.id is not null then 'guardada'
                when e.duenio is null and e.externo_nombre is null then 'sin_asignar'
                else 'asignada' end,
           coalesce(e.anulada_motivo, e.nota),
           e.adentro_en, e.creada_en,
           case when e.duenio is null then inv.para end,
           case when e.duenio is null then inv.codigo end,
           case when e.duenio is null then inv.vence_en end
      from public.entradas e
      left join public.compras  c  on c.id  = e.compra_id
      left join public.miembros d  on d.id  = e.duenio
      left join public.miembros te on te.id = e.tenedor
      left join public.miembros cm on cm.id = c.comprador
      left join public.invitaciones inv on inv.id = e.para_invitacion
                                       and not inv.usada and not inv.revocada and inv.vence_en > now()
     order by (e.anulada_en is not null), e.creada_en;
end;
$$;
