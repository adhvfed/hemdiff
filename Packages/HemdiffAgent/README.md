# HemdiffAgent

The standalone `hemdiff` CLI and MCP stdio server. Depends on the local
`HemdiffCore` package and exactly MCP Swift SDK 0.11.0. The GUI does not depend on
this package or inherit the protocol SDK.

- `Command` validates local CLI administration and read/cleanup commands.
- `Application` prints JSON and maps failures/partial outcomes to exit status.
- `MCPAdapter` exposes the five scoped tools; it cannot modify roots or grants.
- `ServiceWorker` offloads synchronous core calls, admits one operation, and
  propagates request/session cancellation before draining active work.
- `InventoryPages` retains one size-bounded, expiring snapshot for stable pagination.
- `BoundedStdio` bounds frame size, queued frames and outstanding requests. The
  official SDK owns JSON-RPC/MCP negotiation, routing and cancellation semantics.

See [agent access](../../docs/agent-access.md) for setup, SSH, authorization,
behavioral limits and executable contract tests. No executable safety bypass is
provided for tests; fixture cleanup observes the production quiet interval.
