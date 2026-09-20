# Hemdiff

**Help, my disk is f\*cking full.**

Hemdiff is a macOS app that finds the build output eating your disk and deletes
it safely. It knows the folders that developer tools regenerate on the next
build, checks that each one really belongs to a project, and asks before it
removes anything. A `hemdiff` command line tool and an MCP server share the same
rules, so a coding agent can clean a remote Linux box with the same safety net.

## What it cleans

Hemdiff only offers a folder for cleanup when it sits at the tool's default
output path and the project marker next to it is a real file, not a symlink.

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
| `.build` (SwiftPM) | `Package.swift` |
| Xcode `DerivedData` child | The user's DerivedData container |

Terraform state, backend metadata and lockfiles are kept. Folders with custom
names such as `cache` or `dist` are never offered automatically.

Before a folder is deleted, Hemdiff checks it again: the folder must still be
the same folder, the marker must still be there, nothing inside may be tracked
by Git, and no nested repository or mount point may be inside it. Stop running
builds and dev servers first. Deletion is permanent, and a folder that fails a
check is skipped and reported.

## Finding projects

On first launch Hemdiff looks for likely workspaces in your home folder and lets
you tick the ones to scan. Nothing is scanned until you say so, and nothing is
ever deleted automatically. **Find Projects…** in Scan Locations repeats the
search later. Details on how the search picks folders are in
[docs/workspace-discovery.md](docs/workspace-discovery.md).

Git worktrees are followed from the repositories Hemdiff finds. Each checkout's
build output is listed on its own, and cleanup only ever touches the output
folder, never the checkout or the `.git` data.

Scans run at low priority, are cached between launches, and refresh on their own
after six hours while the app is open. Disk capacity refreshes without a scan.

## Files and Trash

The **Files** view sorts everything in your scan locations into categories:
video, audio, images, documents, archives, disk images, virtual machines, AI
models, databases, code, applications, logs and other. Filter by name, sort by
size or date, tick files across pages, and press Command-Y to preview one.
**Move to Trash** shows the exact list first. A file that fails to move is left
alone. It is never deleted permanently as a fallback.

**Trash** shows what emptying it would free. It can delete ticked items or empty
the reviewed contents after a separate confirmation. macOS may ask for Full Disk
Access before the app can read Trash.

## Menu bar

The menu bar item shows **Scan Now**, **Clean Build Output…** and the five
projects with the most build output. Each project has a cleanup action that
confirms its folders before deleting them. **View → Show Menu Bar Icon** brings
the item back if you hid it.

## Command line and MCP

The `hemdiff` executable runs on macOS and as a static Linux x86-64 binary with
no Swift runtime on the target. It lists build output under configured roots,
prepares an exact cleanup plan, executes it, and writes a receipt. Roots are
read-only until you grant cleanup for specific artifact kinds. The MCP server
exposes the same operations over stdio and cannot change roots or grants.

```sh
tools/build-agent.sh
build/agent/hemdiff roots add /absolute/path/to/Projects
build/agent/hemdiff inventory
```

Setup, SSH use, the tool list and the safety limits are in
[docs/agent-access.md](docs/agent-access.md).

## Build from source

Hemdiff needs macOS 14 or later, Xcode 16 or later, and
[xcodegen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
xcodebuild -project DiskSift.xcodeproj -scheme DiskSift -configuration Release build
```

The Xcode project, scheme and Swift module keep the app's original name,
DiskSift. The built product is `Hemdiff.app`. There is no signed download yet.
To install a local build over a previous one:

```sh
python3 tools/install-app.py PATH/TO/Hemdiff.app
```

## Tests

```sh
swift test --package-path Packages/HemdiffCore
swift test --package-path Packages/HemdiffAgent
xcodebuild -project DiskSift.xcodeproj -scheme DiskSift \
  -destination 'platform=macOS,arch=arm64' test CODE_SIGNING_ALLOWED=NO
```

CI runs the same suites on macOS and Linux, plus a protocol test that drives the
built `hemdiff` executable over MCP.

## Repository layout

- `DiskSift/` is the macOS app.
- `Packages/HemdiffCore/` holds the artifact rules and the cleanup engine shared
  by the app and the command line tool.
- `Packages/HemdiffAgent/` is the `hemdiff` command line tool and MCP server.
- `design/` holds the editable icon sources and their exports.
- `tools/` holds build and install scripts.

## License

MIT. See [LICENSE](LICENSE). The Linux `statx` header under
`Packages/HemdiffCore/Sources/HemdiffPOSIX/` is a kernel UAPI header carried
under the GPL-2.0 Linux syscall note, which permits its use here.
