# Stremio addons

clubTivi speaks the [Stremio addon protocol](https://github.com/Stremio/stremio-addon-sdk/tree/master/docs/protocol):
it reads `manifest.json`, browses `/catalog/...`, opens `/meta/...` and merges
`/stream/...` with Torrentio and the enabled debrid services.

## Installing

**Settings → Stremio Addons**. Paste the addon base URL (for example
`https://torrentio.strem.fun`) or use one of the recommended cards. The
manifest is downloaded and validated *before* anything is saved: an addon that
is down, answers with garbage or has no `stream`/`catalog` resources is rejected
with the reason on screen.

Addons are queried in list order (that is the priority) and can be disabled or
removed at any time. `stream`-only addons (Torrentio) feed the stream picker;
`catalog`-only addons (Kitsu) feed the discovery tab and are never asked for
streams.

## Catalog browsing

**Shows & Movies → From addons** paints one row per catalog. Catalogs that only
answer a `search` query, or that require an extra we cannot fill
(`calendarVideosIds`…), are not shown as rows. When a catalog declares genres,
the row has a genre menu; the first genre is used initially if the addon marks
it as required (as AnimES does).

Opening a poster shows the addon's `/meta`: poster, backdrop, synopsis, genres,
seasons and episodes. The stream search uses the addon's own id
(`kitsu:7442:1`, `animeav1:…:2`) and, when the addon exposes `imdb_id`, also
Torrentio with the season/episode. The result goes through the same picker,
debrid availability checks and language ranking as any other title.

## Recommended addons

The list is curated from URLs whose `manifest.json` was checked; addons that
require a personal link are installed by pasting that URL. Verified on
2026-10-17:

| Addon | URL | What it adds |
|---|---|---|
| AnimES (AnimeFLV) | `https://pigamer37.alwaysdata.net` | Anime catalogs and streams (AnimeAV1, Henaojara, TioAnime, JKAnime) |
| Anime Kitsu | `https://anime-kitsu.strem.fun` | Anime catalogs, metadata, episodes and subtitles (no streams) |
| Anime Catalogs | `https://1fe84bc728af-stremio-anime-catalogs.baby-beamup.club` | Anime catalogs; run `/configure` first |

Spanish/Latin movie addons (Mio Streams, Stremio-Latino, Megalodon, LAT-ADD,
Addon Latam…) were **not** curated because their install URL is a personal link
handed out by each community. "More addons" in the screen opens the community
list (stremio-addons.net); paste the addon URL there into the same field.

## Configuration

If a manifest sets `behaviorHints.configurable` (or `configurationRequired`),
the addon card shows a **Configure** button that opens `<url>/configure` in the
browser. After finishing there, press the **Refresh** icon: the manifest is read
again and the new catalogs appear without reinstalling. Anime Catalogs starts
with zero catalogs for exactly this reason.

## Limits

- Catalogs are read one page at a time (`skip`); the app paints the first page
  of each row and there is no infinite scroll yet.
- `search`-only catalogs are not queried from the app search; search still goes
  through Trakt/TMDB.
- An addon that changes its catalogs without a version bump needs a manual
  refresh (the Refresh button) — the list is persisted with the install.
- Only `url`, `infoHash`/`fileIdx`/`sources` streams are playable; `ytId` and
  `externalUrl` entries are skipped.
