# App icon

- `fullbleed-1024.png`: the chosen artwork (stacked pages and bookmark), square and full-bleed, no tile shape.
  Use it as-is for iOS/iPadOS (the system applies the mask).
- `glyph-transparent-1024.png`: the glyph alone, for a layered Icon Composer `.icon` later (background colour + glyph layer).
- `make-mac-icon.swift`: masks the artwork to the macOS squircle on Apple's grid (824 px tile in 1024, soft shadow,
  faint edge highlight), which is what `Apps/Deepwell/Assets.xcassets/AppIcon.appiconset` holds:

```sh
swift Design/AppIcon/make-mac-icon.swift Design/AppIcon/fullbleed-1024.png /tmp/mac_1024.png
for n in 16 32 64 128 256 512 1024; do sips -z $n $n /tmp/mac_1024.png --out Apps/Deepwell/Assets.xcassets/AppIcon.appiconset/icon_$n.png; done
```
