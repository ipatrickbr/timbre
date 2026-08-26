# Icon

`AppIcon.icns` is generated from `icon.swift`, which draws the artwork with
CoreGraphics — no image editor involved.

```bash
swiftc -O -o drawicon icon.swift -framework AppKit -framework CoreGraphics
./drawicon fb_1024.png --fullbleed        # detailed art, large sizes
./drawicon fb_small.png --small --fullbleed  # simplified art, 16–32 px
```

Two variants exist because eight waveform bars turn to mush below 32 px, so
small sizes use a five-bar version — the same trick Apple uses in system icons.

The art bleeds to the edges on purpose: macOS 26 applies its own rounded mask
and finish, and artwork carrying its own frame ends up as a squircle inside a
squircle.

Assemble with:

```bash
mkdir Timbre.iconset   # fill with sips at each required size
iconutil -c icns Timbre.iconset -o AppIcon.icns
```
