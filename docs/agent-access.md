# Hemdiff for agents and remote machines

Hemdiff exposes developer build-artifact inventory and cleanup through a command
line executable and an MCP server. Each executable operates on its own machine's
files. The macOS app remains the interface for general files and Trash; neither
is exposed for agent deletion.

## Configure a machine

Install the `hemdiff` executable built by `tools/build-agent.sh`. Use absolute
paths when configuring roots or MCP clients. No global agent configuration is
changed by the installer or by starting the server.

```sh
hemdiff --help
hemdiff roots add /absolute/path/to/Projects
hemdiff roots list
hemdiff inventory
```

Adding a root grants **read scope only**. Inventory includes the host ID, root IDs,
candidate IDs, evidence, allocation estimates and whether each candidate is
currently authorized for cleanup. The inventory covers recognized artifacts, not
all files on the disk. Xcode DerivedData is not exposed by the headless service.

To authorize cleanup, use the root ID returned above and list the permitted kinds:

```sh
hemdiff permissions grant ROOT_ID nextBuild swiftBuild rustTarget
hemdiff plan CANDIDATE_ID
hemdiff execute PLAN_ID --host HOST_ID
hemdiff receipt PLAN_ID
hemdiff permissions revoke ROOT_ID
```

`--help` lists all supported kinds. Revocation without kinds revokes all cleanup
permissions for that root. `roots remove ROOT_ID` removes its read scope and
grants. Pending plans are subject to current permissions when executed; knowing
a plan ID or setting an agent argument cannot grant authority.

Root grants are standing authorization to remove matching build output in that
workspace. Grant only the kinds the operator intends agents to clean. A client's
per-tool approval dialog is an additional choice, not Hemdiff's permission store.
MCP annotations describe effects; clients may ignore them. Hemdiff enforces its
own grants regardless of client behavior.

## Local MCP

Use the client's stdio MCP configuration format with the equivalent of:

```json
{
  "mcpServers": {
    "hemdiff": {
      "command": "/absolute/path/to/hemdiff",
      "args": ["mcp"]
    }
  }
}
```

MCP tools:

| Tool | Purpose | Changes |
| --- | --- | --- |
| `status` | Host identity, scopes and grants | None |
| `inventory` | Artifact candidates with stable snapshot pagination | Session cache only |
| `prepare_cleanup` | Validate and persist an exact expiring plan | Local plan record |
| `execute_cleanup` | Revalidate and execute the plan on the expected host | Permanent removal of authorized artifacts; receipt |
| `cleanup_receipt` | Retrieve an outcome after success, interruption or reconnect | May finalize an interrupted journal; no deletion |

There are no MCP tools for root administration, grants, arbitrary paths, shell
execution or Trash emptying. Tool argument objects reject unknown keys and wrong
types. Plans accept at most 256 candidate IDs per request.

Inventory defaults to 100 candidates per page (maximum 200). Pass its `nextCursor`
to get the next page from the same snapshot. A snapshot lives for five minutes;
starting a new inventory replaces it. Expired or foreign cursors fail explicitly.
A session retains at most one snapshot, capped at 32 MiB of encoded data. For larger
inventories, configure smaller scopes rather than accepting silent truncation.
Planning and execution revalidate against current filesystem state; a snapshot
is never deletion authority.

Clients can supply `_meta.progressToken` to receive start/completion progress.
Cancellation notifications stop the worker through the core's cancellation checks.
EOF, SIGINT and SIGTERM cancel and drain active work before the process exits.
During deletion a cancellation may have already removed entries: retrieve the
receipt and inspect its `outcome`, `failures` and `accountingComplete`. SIGKILL or
a crash is recovered through the durable started journal. Do not interpret a lost
connection as “nothing happened.” Retrying a completed plan returns its receipt;
interrupted or partial work is never silently resumed.

Only one filesystem operation runs in a server session at once. Concurrent calls
enter a bounded, cancellable FIFO queue. Cross-process
serialization is independently enforced by the core state lock. Input frames are
limited to 1 MiB with a 16-frame queue and at most 16 outstanding requests;
overflow closes the session. The official
MCP Swift SDK handles negotiation, method routing and cancellation. Stdout carries
protocol data only.

## Remote machines over SSH

Install and configure Hemdiff on the target machine first. Its roots, permissions,
host identity, state and receipts remain there. Do not copy state between machines.
An existing authenticated SSH route needs no new public service or listening port.

```sh
ssh -T -o RemoteCommand=none -o RequestTTY=no example-host \
  /home/you/.local/bin/hemdiff mcp
```

Since the stdio protocol needs a clean channel, `-T` disables terminal allocation
and `RemoteCommand=none` skips a login command such as a `tmux` attach. The remote
shell and login scripts must not write banners to stdout. Any existing transport,
including an SSH `ProxyCommand`, keeps working.

A client configuration can launch SSH directly:

```json
{
  "mcpServers": {
    "hemdiff-linux": {
      "command": "/usr/bin/ssh",
      "args": ["-T", "-o", "RemoteCommand=none", "-o", "RequestTTY=no", "example-host", "/home/you/.local/bin/hemdiff", "mcp"]
    }
  }
}
```

When an agent runs on the remote machine itself, configure Hemdiff there as a
local stdio server instead. Client configuration formats and approval dialogs
differ; Hemdiff changes no client configuration and injects no credentials.

## Boundaries and practical limits

The CLI and macOS app share the artifact rules and domain types. Portable inventory
and cleanup run on macOS and Linux; the GUI, Trash, Spotlight and full file index
remain macOS-specific. A static Linux build does not require Swift on the target.
Root configuration and grants are machine-local, restricted to the current user.

Cleanup refuses changed plans, tracked output, nested version-control metadata,
unsafe ancestors, mounts and unsupported special entries. Reviewed descendant
symlinks are unlinked as entries; their targets are never traversed. Root identities,
marker evidence, recursive metadata, current grants and activity are rechecked.
Repository scripts are not executed. Detected active use or an unknown activity
assessment refuses cleanup. The 30-second quiet interval is deliberately retained.

Those checks cannot prove a build will not start afterwards, make the filesystem
transactional, or prevent a hostile process with the same user privileges from
changing files. Keep active builds out of cleanup scope. Estimates describe removed
allocation, not guaranteed new free space: shared blocks, hardlinks and open files
can change the result. Partial receipts explicitly identify incomplete accounting.

macOS Full Disk Access is per executable identity; granting it to the GUI does not
automatically grant it to the CLI or an SSH process. Configure accessible project
roots first. Stable Developer ID signing/notarization remains necessary for a
polished distributed macOS release; do not disable OS protections to work around it.

## Reproducible validation

```sh
swift test --package-path Packages/HemdiffAgent
swift build --package-path Packages/HemdiffAgent
python3 -B Packages/HemdiffAgent/Tests/Protocol/contract.py \
  Packages/HemdiffAgent/.build/debug/hemdiff
```

The executable contract suite uses disposable Git fixtures, including an actual
cleanup after the production quiet interval. It checks default read-only behavior,
revocation, stable pagination, receipts across reconnects, strict arguments and
bounded input. Use `--state-directory /absolute/disposable/path` for isolated local
experiments; this option is intentionally unavailable as an MCP argument. Help and
version do not initialize state. JSON command errors go to stderr with a nonzero
exit status; operations emit JSON on stdout. An `execute` partial/interrupted
receipt is still emitted on stdout, with exit status 2; cancelled inventory uses
exit status 130. A receipt lookup succeeds even when the recorded outcome was partial.

Inventory cursors page candidates first, then skipped-path diagnostics. Continue
until `nextCursor` is absent, even if a page has no candidates. `totalCandidates`
and `totalErrors` describe the complete snapshot. Diagnostic lists are bounded
per response just like candidates.

GUI and CLI execution share a private per-user mutation lease, independent of the
agent state directory. Concurrent cleanup is refused; inventory and plan preparation
can still run independently. After a crash, `cleanup_receipt` resolves a started
journal as interrupted without retrying deletion.

On Linux, process inspection ignores zombies (which hold no open file descriptors)
and protected authentication supervisors named `(sd-pam)`, `sshd`, or `sshd-session`
when their descriptor lists are inaccessible. Inaccessible build processes or other
unknown processes still refuse cleanup. This is best-effort activity observation,
combined with a quiet interval and recursive revalidation, not a claim that a new
build cannot start.

Within one MCP session, operations run sequentially through a FIFO queue with at
most eight waiting requests and a 30-second queue wait limit. Parallel status and
inventory requests work normally. Queued requests are cancellable; shutdown
cancels and drains active work before exiting.
