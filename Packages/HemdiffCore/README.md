# HemdiffCore

Portable artifact domain, ownership rules, path validation, and the existing
reclaimer. The macOS app imports this local Swift package; it is the source of
truth for artifact types and classification rules.

- `Artifact` and `ArtifactFileIdentity` preserve the app's existing Codable schema.
- `ArtifactRules` evaluates ownership markers without executing project code.
- `PathSafety` rejects symbolic-link ancestors. Standard macOS system aliases are
  accepted only on macOS and only with their expected destinations.
- `ArtifactContainers` provides canonical known-container paths without a
  dependency on app discovery services.
- `ArtifactReclaimer` preserves the GUI's existing validation/reclamation API.
  Its directory identity check does **not** detect changes inside the directory;
  it must not be treated as sufficient authorization or concurrency protection
  for unattended agent cleanup.

UI, project discovery, content indexing, and application preferences remain in
the macOS target. Additional host services should depend on this package instead
of importing application sources.

Run `swift test --package-path Packages/HemdiffCore` to test the shared rules.

## Headless artifact service

`AgentArtifactService` is the single authority for the upcoming CLI/MCP adapters.
Its synchronous APIs are intended to run on a worker rather than the UI thread:

- `status()` returns the random public host ID and configured roots.
- `configureRoot(URL)` grants read scope only; `grant(rootID:kinds:)`,
  `revoke(rootID:kinds:)`, and `removeRoot` are explicit local administration.
- `inventory(cancelled:)` discovers only recognized artifacts in configured
  roots. It returns candidate IDs, evidence, allocation estimates, counts, skipped
  errors and cancellation state. It does not expose the app's full file index.
- `prepare(candidateIDs:cancelled:)` checks permission, ownership, Git tracking,
  activity and recursive metadata; it persists an expiring exact plan.
- `execute(planID:expectedHostID:cancelled:)` accepts an existing plan, revalidates
  each candidate immediately before deletion, and writes a durable receipt.
- `receipt(planID:)` retrieves the previous outcome. Completed/partial retries
  return that outcome. A started journal without a receipt becomes an interrupted
  outcome without attempting deletion again.

Root grants are bound to directory identity. State is owned by the current UID,
mode 0700, with regular mode-0600 records and a nonblocking cross-process lock.
The public random host ID is separately bound to a digest of the machine ID and
UID. Copied state on another machine fails closed. `defaultStateDirectory` uses
Application Support on macOS and `~/.local/state/hemdiff` on Linux. A caller can
supply a separate directory for isolated tests, not as an agent-controlled tool
parameter.

`CleanupPlan` is a small public DTO. `StoredCleanupPlan` keeps descendant manifests
private. Primary marker files are bounded to 64 KiB and hashed with official
swift-crypto SHA256; raw contents are not persisted. Terraform source ownership
uses source names/metadata, never source bodies. No repository script is run.
Git runs with literal pathspecs, disabled fsmonitor/hooks, sanitized Git environment,
a deadline and cancellation. Helper processes have a separate process group.

The POSIX adapter walks ancestors without following links, opens directories by
file descriptor, snapshots nanosecond timestamps and identity, and unlinks entries
relative to verified parents. Descendant symlinks are counted/unlinked as entries;
targets are never traversed. Root/ancestor links, special files, nested version
control metadata and mount boundaries are refused (including Linux same-device bind mounts via statx). Hardlinks within an artifact
are handled by verifying the post-unlink inode stamp and updating remaining aliases;
external hardlink names survive.

Default activity checks inspect open artifact paths and recognized build processes
with project working directories. They do not read unrelated file contents. A
30-second quiet interval complements this observation. Unknown activity results
refuse cleanup. The `ArtifactActivityChecking` protocol is injectable for tests.
Cancellation propagates through walks, Git/activity helpers and deletion boundaries.
A partial/interrupted receipt sets `accountingComplete` false: its byte estimate
covers completed artifact removals only, not an assertion that no other files changed.

### Current limits

- This is artifact inventory, not a portable version of the full SQLite file index.
  Xcode's known-container cleanup is not yet exposed through the agent service.
- Recursive manifests remain in memory. Private binary plans are capped at 128 MB
  each and 32 pending plans / 256 MB aggregate. Oversized plans fail before mutation.
  Completed manifests are discarded after durable receipts; expired unused plans
  are discarded when preparing another plan. Receipts remain available.
- Planning resolves only selected IDs through configured-root, shared-rule, mount,
  and ancestor-exclusion checks. It does not rescan unrelated workspaces.
- Separate artifacts sharing hardlinked files must be planned and cleaned one at a
  time. The combined plan is refused before mutation; internal hardlinks work.
- Linux requires statx mount IDs (kernel 5.8 or newer); missing support fails closed.
- Activity observations and quiet periods cannot prevent a build from starting
  afterwards. Descriptor-relative operations narrow replacement races but do not
  promise atomic compare-and-unlink against hostile same-user processes or root.
- Allocation is an estimate; hardlinks, shared blocks and open files mean it is not
  a guarantee of newly available disk space.

Service tests exercise grants/revocation, stale contents/markers/directories/links,
tracked/nested version control, private state, machine binding, concurrent locks,
interruption/cancellation, subprocess deadlines, real busy-process detection,
hardlinks, special files, partial preservation and durable receipts.
