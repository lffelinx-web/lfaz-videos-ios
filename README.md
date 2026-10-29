# LF’AZ Videos

Centro de entretenimiento para iPhone que reproduce películas y series guardadas en un NAS Synology mediante WebDAV.

## Objetivos

- Conexión al NAS por HTTPS (dominio DDNS de Synology) con ruta automática: IP local en casa y Tailscale fuera de casa, validando siempre el certificado del dominio. Basada en la conexión de LF’AZ Música.
- Reproducción de MP4 con el reproductor nativo de iOS (AirPlay y Picture in Picture) y de MKV con un reproductor basado en VLC.
- Servidor local dentro de la app que entrega el video al reproductor por fragmentos, usando la conexión segura al NAS.
- Carátulas, sinopsis, reparto y temporadas automáticas desde TMDB, a partir de nombres como `Película (2014).mkv` y `Serie/Temporada 1/Serie S01E01.mkv`.

## Compilación

El proyecto se genera con XcodeGen y se compila en GitHub Actions sobre macOS, sin necesidad de una Mac propia.

## Estado

Etapa 1 (0.1.0): conexión al NAS, escaneo de `Películas`, `Series` y `Videos`, y pantallas provisionales para comprobar la biblioteca.

Estructura esperada en la carpeta compartida:

```
Películas/Interstellar (2014).mkv
Series/The Last of Us/Temporada 1/The Last of Us S01E01.mkv
Videos/Pop/Dua Lipa - Levitating.mp4   (miniatura opcional: Dua Lipa - Levitating.jpg)
```
