# SÉKITO — acceso

## Probar en local

**No abras `index.html` con doble clic.** El sitio usa `<canvas>` para generar la imagen de "compartir código" y una máscara CSS (`mask-image`) para el abanico animado. Ambas cosas dependen de que las imágenes en `images/` se carguen desde el mismo origen que la página — algo que los navegadores garantizan por `http(s)://`, pero no por `file://` (ahí cada archivo local se trata como un origen distinto, y el navegador bloquea el canvas y la máscara por seguridad).

Por eso, para probarlo local hay que servirlo con un servidor simple:

```bash
python3 -m http.server 8000
```

y abrir `http://localhost:8000/index.html`.

Una vez desplegado en un hosting real (GitHub Pages, etc.) esto no es un problema — el sitio se sirve por `https://` y todo funciona normal.
