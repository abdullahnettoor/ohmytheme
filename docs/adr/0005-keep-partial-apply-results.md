---
status: accepted
---

# Keep safe results from a partial apply

A target-specific apply failure will not automatically roll back unrelated targets because partial success is an explicit product outcome and cross-target rollback can itself destroy later external changes. The failing adapter attempts local rollback when activation fails after mutation and rollback remains provably safe. Oh My Theme reports every target result and lets the user undo the complete Last Apply Transaction afterward.
