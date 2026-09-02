---
status: accepted
---

# Persist recovery state in SQLite through GRDB

Oh My Theme will store its Workspace, connection metadata, immutable plans, transaction journal, and receipts in SQLite through GRDB. Crash recovery needs explicit transactions, constraints, migrations, and inspectable state transitions; SwiftData hides too much of that control, while coordinating several JSON files would create a fragile transaction mechanism. Exact restoration bytes and generated artifacts remain in a content-addressed file store referenced by digest from SQLite.
