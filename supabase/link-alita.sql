-- sekito.ar/alita (11/11). Como /lapochi, pero con los tres precios (30/40/50)
-- y además 2x1 y 3x2: dos entradas por $40.000 o tres por $60.000
-- ($20.000 cada una, ver migracion-packs.sql). Alita ya es del portal (LJN·467):
-- la gente que compra cuelga de su rama.
-- Se corre con el sitio ya publicado (los textos viven en PROPIO.alita).
insert into public.anfitriones (palabra, anfitrion, frase, tanda_cumple, tanda_bancar, cupo, hasta,
                                es_cumple, quien_dice, foto, instagram, precio_remil, packs, precio_pack)
select 'alita', m.id, 'Alita te está llamando...',
       (select t.id from public.tandas t where t.nombre = 'hermética'),
       (select t.id from public.tandas t where t.nombre = 'abierta'),
       500, '2026-11-14 20:00:00-03'::timestamptz,
       false, 'Alita', 'alita', 'alitadelaire', 50000, '{2,3}', 20000
  from public.miembros m where m.nombre_sektario = 'LJN·467';
