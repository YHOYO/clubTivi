# Fixtures del protocolo Stremio

Cada archivo es un payload con su procedencia anotada; ninguno se ha inventado
desde cero.

| Archivo | Procedencia | Qué cubre |
| --- | --- | --- |
| `torrentio_manifest.json` | Capturado en vivo de `https://torrentio.strem.fun/manifest.json` | Manifest real con `id`, `name`, `version`, `resources`, `types`, `catalogs`, `idPrefixes` |
| `torrentio_streams.json` | Capturado en vivo de `https://torrentio.strem.fun/stream/movie/tt1254207.json` (los 6 streams completos) | `infoHash` + `fileIdx` + `sources` (26 trackers y nodos `dht:`), seeds, tamaño, idiomas y `behaviorHints` reales |
| `helloworld_streams.json` | Objetos que devuelve el addon oficial `Stremio/addon-helloworld` (`addon.js`, dataset `tt0032138`, `tt0063350`, `tt1254207`, `tt0031051`, `tt0137523`) | `url` directa, `infoHash` + `sources` construidos desde un magnet, `ytId` y `externalUrl` (los dos últimos no son reproducibles y deben descartarse) |
| `direct_url_proxy_headers.json` | Forma documentada en `stremio-addon-sdk/docs/api/responses/stream.md` (`behaviorHints.proxyHeaders`, `notWebReady`, `filename`, `subtitles`) | `url` directa con cabeceras de petición/respuesta, `notWebReady` y subtítulos referenciados |

El payload de `direct_url_proxy_headers.json` se compone a partir de la
especificación porque en el momento de escribir esto no había ningún addon
público alcanzable que devolviera `proxyHeaders`: los candidatos
(`webstreamr`, `mediafusion`, `nodebrid`) responden 000, 302 a una página de
deprecación o no resuelven.
