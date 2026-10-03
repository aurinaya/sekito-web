/* ===========================================================================
   LAS FOTOS DE LOS PERFILES

   Cada persona con fotos tiene una carpeta acá, con su código sektario en
   minúscula y un guion en lugar del punto:

       GSN·019  →  images/perfiles/gsn-019/

   Adentro, 1.jpg, 2.jpg, 3.jpg… en el orden del carrusel. La 1 es la
   principal: la que sale en la ficha de devotxs y en la tarjeta de
   invitación.

   Se usa el código y no el nombre porque los nombres se repiten (hay dos
   Florencias, tres Juanes) y los apodos cambian. El código no.

   SUMAR UNA FOTO: dejar el archivo en la carpeta con el número que sigue,
   y subir `fotos` acá.
   SUMAR A ALGUIEN: crear su carpeta y agregar una línea.
   CAMBIAR EL ORDEN: renombrar los archivos.

   Las fotos entran ya achicadas: el lado corto en 1080 px. El carrusel
   recorta todo a 4:5, así que lo que se ve es justamente ese lado. Los
   originales viven afuera del repo, en SEKITO-fotos/originales.

   `apodo` es opcional. Si está, es el título del perfil; si no, el título
   es el nombre de la persona.
   =========================================================================== */
window.PERFILES = {
  'MAU·000': { fotos: 3, apodo: 'MAU'   },
  'LCN·105': { fotos: 3, apodo: 'LUCHI' },
  'NYA·000': { fotos: 2, apodo: 'NAYA'  },
  'MDL·842': { fotos: 2, apodo: 'MAIA'  },
  'FLR·000': { fotos: 2, apodo: 'FLOR'  },
  'VLR·173': { fotos: 1, apodo: 'VALE'  },
  'GSN·019': { fotos: 1 },
  'NTL·797': { fotos: 2 },
};
