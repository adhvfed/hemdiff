# Workspace discovery

The product goal is setup that fits most developers with little adjustment. “85%”
is a target, not a measured success rate. No representative population study was
found in this research.

## Evidence

- [ghq](https://github.com/x-motemen/ghq/blob/master/README.adoc) uses a configurable
  root (default ~/ghq), then host/owner/repository nesting. Immediate Git children
  alone cannot identify every workspace.
- [JetBrains support](https://intellij-support.jetbrains.com/hc/en-us/community/posts/115000628550-How-to-retrieve-the-IdeaProjects-path)
  documents ~/IdeaProjects as the default and remembers user-chosen alternatives.
  Folder names are useful clues, not a complete catalog.
- [VS Code multi-root workspaces](https://code.visualstudio.com/docs/editing/workspaces/multi-root-workspaces)
  explicitly support multiple folders. Discovery should retain separate workspaces,
  not collapse everything into the user's home.
- [Go's command documentation](https://go.dev/doc/articles/go_command) describes
  source organization under GOPATH/src and generated packages under pkg. Go module
  downloads under pkg/mod are excluded from workspace suggestions.

These sources describe supported conventions, not their relative popularity.

## Implemented theory

Find projects first, then infer the shallowest useful container. A readable,
eligible container with at least one discovered project qualifies when any of
these conditions holds:

1. Its name suggests a workspace (Projects, IdeaProjects, Work, ghq, Research, etc.).
2. It contains at least two independent Git repositories, including organization
   nesting. Nested modules in a single repository do not multiply this evidence.
3. At least half its immediate directory branches contain projects. One project
   can qualify a direct child of home; deeper containers need at least two.

Ordinary files do not veto a workspace. Notes, scripts, planning files and other
folders coexist with development work. A generic mixed folder with a single
incidental project and predominantly unrelated directory branches stays narrow.
An existing project root stays a project, including a monorepo.

Never infer the home directory itself. Existing privacy-folder, symlink, package,
hidden-directory and dependency-cache exclusions still apply. Discovery is read
only; selecting a scan root does not authorize deleting its contents. Deletion
continues to require the separate artifact rules and confirmation.

The breadth-first folder walk and independent Spotlight search remain cancellable,
stream results and stop walking below recognized projects. No count or time cap.
Nested duplicates are removed before scoring. Workspace choices remain expandable,
and explicit exclusions survive live regrouping. Users can select a parent manually.

## Validation

Fixtures cover one-repo containers, named and arbitrary multi-repo workspaces,
host/owner/repository nesting, monorepos, incidental projects among unrelated
folders, excluded locations, module caches, and stable selection during regrouping.
A read-only live probe checks the user's actual examples and latency. On the
development machine, 31 locations appeared within 0.35 seconds and the search
finished in 1.65 seconds (a single warm local run, not a general benchmark).
Grouping builds ancestor evidence once per snapshot rather than comparing every
folder against every project.

Future calibration should use opt-in examples of accepted/adjusted roots rather
than assume that the thresholds meet the target population coverage.
