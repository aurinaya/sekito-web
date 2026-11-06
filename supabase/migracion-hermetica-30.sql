-- 06/11: la hermética vuelve, a $30.000, y en todos los links se elige 30/40/50.
-- La sekreta queda en la base (sus compras y entradas no se tocan) pero no se
-- muestra más: el portal ya no lista las tandas, y la tarjeta de la entrada y
-- la puerta dicen "tanda hermética" (entrada.js, puerta/index.html).
-- Lo cobrado no cambia: compras.precio_unitario y entradas.precio guardan lo
-- que se pagó (las 24 de la hermética a $35.000 siguen a $35.000).
--
-- Para volver atrás: hermética a 35000; flor, lapochi, s7 y ritoss7q a cupo 0.

update public.tandas set precio = 30000 where nombre = 'hermética';

-- los links que solo tenían 40 y 50: cupo 0 escondía el precio barato
update public.anfitriones set cupo = 500 where palabra in ('flor', 'lapochi', 's7', 'ritoss7q');
