# DiskSift

DiskSift is a native macOS disk monitor focused on low-overhead visibility and
safe cleanup of Rust `target` and JavaScript `node_modules` folders.

## Build

```sh
xcodegen generate
xcodebuild -project DiskSift.xcodeproj -scheme DiskSift -configuration Debug build
```

Scans run at utility priority, are cached between launches, and are considered
fresh for six hours. Disk capacity refreshes independently without a filesystem
walk. Reclaimed folders are moved to the macOS Trash.
