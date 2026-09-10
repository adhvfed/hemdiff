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
