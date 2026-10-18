# Remote Pi artwork

[Project index](../README.md#project-map)

This directory owns Remote Pi source artwork, not Cockpit's separate identity. The [website](../site/README.md#integrations), [mobile client](../app/README.md) and [extension package metadata](../pi-extension/package.json) contain consumer copies/references; editing a source SVG does not automatically regenerate those copies.

## Sources

| Asset | Dimensions | Role |
|---|---|---|
| [Full logo](logo-full.svg) | 1024×1024 | Combined logo/background |
| [Foreground](logo-foreground.svg) | 1024×1024 | Transparent adaptive-icon layer |
| [Background](logo-background.svg) | 1024×1024 | Adaptive-icon background |
| [Monochrome](logo-monochrome.svg) | 1024×1024 | Themed icon silhouette |
| [Banner source](banner.svg), [rendered banner](banner.png) | 1280×640 | Package/social card |

The logo palette is black `#000000`, white `#FFFFFF` and blue `#4FC3F7`. Square logo content uses an approximately central 66% adaptive-icon safe zone; the banner is not square.

## Export and update

Edit the relevant SVG, then regenerate only required consumer resources. For example, with librsvg installed, run from this directory:

```sh
rsvg-convert -w 1024 -h 1024 logo-full.svg -o logo-full.png
```

Use platform-required dimensions/transparency for final icons. Review copies in [site/public](../site/public/) and the mobile platform resource directories before distributing a changed identity.

[Cockpit artwork](../cockpit/assets/branding/) is independent. Its mobile icon generation uses the macOS icon configured in [cockpit/pubspec.yaml](../cockpit/pubspec.yaml), not these Remote Pi SVGs.
