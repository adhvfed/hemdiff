# DiskSift

DiskSift is a native macOS disk monitor focused on low-overhead visibility and
safe cleanup of regenerable developer storage: Rust `target`, JavaScript
`node_modules`, Next.js `.next`, SwiftPM `.build`, and Xcode `DerivedData`
folders. `~/Projects` is scanned directly by default so the inventory does not
depend on Spotlight indexing being current.

Git discovery follows registered worktrees from repositories found in the index
or a scan location. Hidden and detached checkouts, nested packages, and worktrees
owned by bare repositories are supported. DiskSift validates Git's pointers in
both directions, so stale registrations and submodule pointer files do not become
worktree results. Each checkout's build artifacts are listed separately; cleanup
deletes only the confirmed artifact folder, never the checkout or Git metadata.

Registered checkouts elsewhere in your home folder receive a direct marker scan.
Privacy-managed folders, tool caches, and locations outside your home remain
excluded unless you add an appropriate scan location. Unindexed repositories
with no discovered connection still need an added folder.

The **Files** view classifies content in your scan locations: video, audio,
images, documents, archives, disk images and installers, virtual machines, AI
models, databases and datasets, code, applications, and other files. Add folders
such as Downloads or Movies in **Scan Locations** to include them.

Category totals include all measured items. Browse the largest 100 per type,
filter by name or path, sort by size, name, or modification date, and use **Show
in Finder** to move or remove personal files. App bundles, photo libraries, and
VM packages appear as single items. Build folders remain in **Cleanup**.

## Build

```sh
xcodegen generate
xcodebuild -project DiskSift.xcodeproj -scheme DiskSift -configuration Debug build
```

Scans run at utility priority, are cached between launches, and refresh while
DiskSift remains open once the inventory is six hours old. Disk capacity
refreshes independently without a filesystem walk. Individual or selected
folders can be cleaned through an explicit confirmation; every target is
revalidated before it is permanently deleted.

Scanning and cleanup are serialized. Cancellation waits for scan subprocesses
to exit, failed measurements are reported as skipped, and cleanup rejects paths
with symbolic links in their ancestry. Allocated sizes are estimates: shared APFS
blocks and snapshots can make the actual free-space increase smaller.

Run the tests with:

```sh
xcodebuild -project DiskSift.xcodeproj -scheme DiskSift \
  -destination 'platform=macOS,arch=arm64' test CODE_SIGNING_ALLOWED=NO
```
