# DiskSift

DiskSift is a native macOS disk monitor focused on low-overhead visibility and
safe cleanup of regenerable developer storage: Rust `target`, JavaScript
`node_modules`, Next.js `.next`, Turbo, Terraform/OpenTofu providers, Python
tool caches, Maven/Gradle, SwiftPM `.build`, and Xcode `DerivedData` folders. `~/Projects` is scanned directly by default so the inventory does not
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

Select several categories, filter by name or path, and sort by size, name,
modification date, or location. The complete file index is paged in groups of
250; checked files stay checked across categories and pages. Use arrow keys to
navigate, Space to check, and Command-Y to preview. App bundles, photo libraries,
and VM packages appear as single items. Logs have their own category.

**Move to Trash** shows the exact checked list for confirmation. Files are
revalidated before moving, and a failed move never falls back to permanent
deletion. **Trash** measures accessible items and shows the estimated recovery
from emptying it. Delete checked items or empty the reviewed contents after a
separate permanent-deletion confirmation. New arrivals are left alone. macOS may
require Full Disk Access to read Trash; inaccessible contents are reported.

**Cleanup** groups rebuildable output by project or tool. These folders are
permanently deleted after confirmation. Stop builds and development servers first.
Rules require the exact default output path plus real, non-symlink marker files:

| Output | Required project marker |
| --- | --- |
| `target` (Rust) | `Cargo.toml` |
| `node_modules`, `.next` | `package.json` |
| `.turbo/cache` | `turbo.json` or `turbo.jsonc` |
| `.terraform/providers` | `.terraform.lock.hcl` plus a `.tf` or `.tofu` file |
| `.pytest_cache` | `pyproject.toml`, `pytest.ini`, or `setup.cfg` |
| `.ruff_cache` | `pyproject.toml`, `ruff.toml`, or `.ruff.toml` |
| `.mypy_cache` | `pyproject.toml`, `mypy.ini`, `.mypy.ini`, or `setup.cfg` |
| `target` (Maven) | `pom.xml` |
| `build` (Gradle) | `build.gradle` or `build.gradle.kts` |
| `.build` | `Package.swift` |
| Xcode DerivedData child | Known user DerivedData container |

Terraform state, backend metadata, and lockfiles are preserved. Custom output
paths and generic folders named `cache` or `dist` are not automatically offered.
These are practical project conventions, not a guarantee about custom user data.

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
