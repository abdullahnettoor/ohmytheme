---
status: accepted
---

# Keep a connection baseline and the last apply transaction

Oh My Theme will preserve two recovery references: the state before each Target Instance first connects and the per-instance receipts from the most recent completed apply that changed at least one target. This supports both Undo Last Theme Change and Restore and Disconnect without keeping arbitrary historical restoration. Recovery changes only state the app can still prove it owns and stops on external edits instead of offering force overwrite.
