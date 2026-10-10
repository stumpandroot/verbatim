# Verbatim

Paste a video link or add a recording, get a searchable transcript. Runs on a Mac as a native app, or as a local web app you can open from an iPhone.

- App code and server: [`link-transcriber/`](link-transcriber/) (see its README for running from source, settings, and the API)
- Mac app packaging: [`link-transcriber/macapp/`](link-transcriber/macapp/)
- Builds: the **Build Mac app** workflow under Actions produces signed, notarized `Verbatim-arm64.dmg` and `Verbatim-x86_64.dmg`. Push a tag like `v1.0.0` to publish them as a GitHub Release.

## Releasing

```bash
git tag v1.0.0
git push origin v1.0.0
```

About 20 minutes later the release page has both DMGs. Link to them from the download page.
