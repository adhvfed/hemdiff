# Hemdiff

Hemdiff (formerly DiskSift) is a native macOS disk monitor focused on low-overhead visibility and
safe cleanup of regenerable developer storage: Rust `target`, JavaScript
`node_modules`, Next.js `.next`, Turbo, Terraform/OpenTofu providers, Python
tool caches, Maven/Gradle, SwiftPM `.build`, and Xcode `DerivedData` folders. `~/Projects` is scanned directly by default so the inventory does not
depend on Spotlight indexing being current.

Git discovery follows registered worktrees from repositories found in the index
or a scan location. Hidden and detached checkouts, nested packages, and worktrees
owned by bare repositories are supported. Hemdiff validates Git's pointers in
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

## Setup

First launch automatically finds and preselects likely workspaces on a single
setup screen. Review the folders or add your own, then start the first scan with
one action. Discovery can be stopped while retaining results. Choosing Set Up Later
does not start a scan immediately. Trash access is explained when you visit Trash,
rather than blocking setup. Nothing is deleted automatically.

Use **Hemdiff → Run Setup Wizard…** to repeat setup without resetting scan folders.

## Build

```sh
xcodegen generate
xcodebuild -project DiskSift.xcodeproj -scheme DiskSift -configuration Debug build
```

Scans run at utility priority, are cached between launches, and refresh while
Hemdiff remains open once the inventory is six hours old. Disk capacity
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

## Hemdiff identity and review workflow

The Fold mark is used in the app icon, menu bar, sidebar, and setup. Source assets
live in `design/hemdif/`; the app builds as `Hemdiff.app`. The Xcode project,
scheme, Swift module, bundle identifier, and Application Support location retain
their original names so existing installations keep their settings and inventory.

File selections and category filters survive sidebar navigation. Click a content
category in Storage to review it directly. Command-F focuses search; Escape
clears it. Cleanup groups can be collapsed and grouped by Project or Tool. Trash
supports search, sorting, and checking the visible results. Empty Trash still
confirms the complete reviewed Trash snapshot, regardless of the search filter.

### Find projects automatically

Setup finds workspaces automatically. Use **Find Projects…** in Scan Locations
to discover more later. Review and check the suggested folders before adding them.
Already-included locations are marked and are not removed by this dialog.

Discovery searches eligible home folders breadth first and queries Spotlight in
parallel. Git repositories count even without a project manifest. It skips hidden
folders, generated/dependency directories, symlinks, app bundles, and privacy-managed
home folders; protected locations can still be added manually. Once a project is
found, its contents are left for the actual scan. Registered Git worktrees are also
suggested. There is no entry cap or timeout: results appear during discovery, and
Stop Search keeps what has been found. You can use selected folders immediately.
Workspace suggestions favor the shallowest eligible container: a recognizable
workspace name, multiple independent Git repositories (including nested organization
layouts), or project-bearing folders in at least half its directory branches.
Ordinary notes and supporting files do not disqualify a workspace. Home itself,
protected personal folders and dependency caches stay excluded. Expand a workspace
to select individual projects; explicit choices survive live regrouping.
See [the research and heuristic rationale](docs/workspace-discovery.md).


The menu bar panel offers **Scan Now** and **Clean Build Output…**. Cleanup opens
a fixed list of detected build folders for confirmation before deleting anything.
Use **View → Show Menu Bar Icon** to restore the menu bar item if it is hidden.
