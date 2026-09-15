# SÉKITO — acceso

## Probar en local

**No abras `index.html` con doble clic.** El sitio usa `<canvas>` para generar la imagen de "compartir código" y una máscara CSS (`mask-image`) para el abanico animado. Ambas cosas dependen de que las imágenes en `images/` se carguen desde el mismo origen que la página — algo que los navegadores garantizan por `http(s)://`, pero no por `file://` (ahí cada archivo local se trata como un origen distinto, y el navegador bloquea el canvas y la máscara por seguridad).

Por eso, para probarlo local hay que servirlo con un servidor simple:

```bash
python3 -m http.server 8000
```

y abrir `http://localhost:8000/index.html`.

Una vez desplegado en un hosting real (GitHub Pages, etc.) esto no es un problema — el sitio se sirve por `https://` y todo funciona normal.

## El panel de administración

Está en `/admin/` (`https://www.sekito.ar/admin/`). No está enlazado desde
ninguna parte del sitio y lleva `noindex`, así que no aparece en Google: hay
que escribir la dirección.

Se entra con un **código de administración** de 16 caracteres, uno por
persona, distinto del código de miembro. El código queda guardado sólo
mientras la pestaña esté abierta; al cerrarla hay que volver a ponerlo.

Desde ahí se puede: ver a todos los miembros con su contacto, generar códigos
para gente nueva, suspender y reactivar, corregir datos, ver el linaje y
exportar todo a CSV.

**A un miembro no se lo borra nunca.** Se lo suspende (baja temporal) o se lo
revoca (definitiva). La base lo impide directamente, no es una decisión de esta
pantalla: borrarlo dejaría huérfanos a todos los que esa persona invitó.

## La base de datos

Vive en Supabase. Las seis tablas están cerradas con RLS y sin políticas: con
la clave pública del sitio no se lee ni se escribe nada directamente. El único
camino son las funciones `SECURITY DEFINER`, que devuelven lo mínimo necesario.

Los archivos `supabase/*.sql` son la fuente de verdad de la estructura. Todos
se pueden correr más de una vez sin romper nada. **Ninguno contiene códigos
reales** — este repositorio es público.
