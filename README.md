# ks-GIP

GIP builds moved from `kartensammlung-gip-build` and `kartensammlung-overlay-builds`. Original build scripts are copied unchanged.

## Outputs

- `link.pmtiles`, `link-speed.pmtiles`, `link-einbahn.pmtiles`, `linear-use.pmtiles`, `rfa.pmtiles`
- `GipLookups.json`
- `source-fingerprint.txt` and `asset-versions.json`

GitHub Pages: `https://peter-alexander.github.io/ks-GIP/`

Manual and daily midnight Vienna builds; network/reference builds run only when the source fingerprint changes. The publishing job checks the entire site is at most 1 GB before attempting a Pages deployment. Old FTP workflows are preserved under `legacy-workflows/` and do not run.

Set **Settings → Pages → Source: GitHub Actions**. Repository secret **HOST** contains only the server hostname for the post-deploy refresh notification. The old repositories remain unchanged.

Historical legacy PBF tile directories are not published by this PMTiles-only Pages workflow.
