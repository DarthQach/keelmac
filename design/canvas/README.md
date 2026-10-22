# KeelMac app references

The 23 app artboards now display native screenshots of the implementation using synthetic fixtures. They supersede the compact ledger mockups. Marketing (`Main` and `Landing-Phone`) is unchanged.

Run `bash scripts/revamp-shots.sh` from the repository root to rebuild the app, run isolated UI checks, and export captures. To reuse an existing result bundle, run `bash scripts/revamp-shots.sh build/revamp-final.xcresult`.

The generated images and complete review gallery live in `build/revamp-shots/` (untracked). Artboards link to those local images; regenerate them on a fresh checkout. The gallery includes English/Spanish, light/dark, compact/wide windows, Settings tabs, and presentation states. No screenshots from the real home folder are used.

Storage Map references use `bash scripts/storage-map-shots.sh`, which exercises both visualizations with richer two-level trees, dense/dominant branches and synthetic safety checks. Its dedicated gallery is `build/storage-map-shots/index.html`. Both maps now have their own artboard.
