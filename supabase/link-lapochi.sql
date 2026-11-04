-- sekito.ar/lapochi (04/11). Como /mau, pero sin el precio de $35.000: en un
-- link sin cumple, cupo 0 esconde ese precio (como /flor).
-- La Pochi todavía no está en el portal: el link cuelga de LA SEKTA. Si se
-- registra, se cambia `anfitrion` a ella.
-- Se corre con el sitio ya publicado (los textos viven en PROPIO.lapochi).
insert into public.anfitriones (palabra, anfitrion, frase, tanda_cumple, tanda_bancar, cupo, hasta,
                                es_cumple, quien_dice, foto, instagram, precio_remil)
select 'lapochi', m.id, 'La Pochi te llama...',
       (select t.id from public.tandas t where t.nombre = 'hermética'),
       (select t.id from public.tandas t where t.nombre = 'abierta'),
       0, '2026-11-14 20:00:00-03'::timestamptz,
       false, 'la Pochi', 'lapochi', 'lapochaaa', 50000
  from public.miembros m where m.nombre_sektario = 'LA SEKTA';
