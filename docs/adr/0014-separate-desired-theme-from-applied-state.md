---
status: accepted
---

# Separate desired theme from applied target state

Selecting a theme updates and persists the Workspace's desired Theme Assignment and visual Theme Preview without mutating target instances. Pressing Apply prepares a fresh Apply Plan and continues automatically when no review condition exists. Each target's last outcome records whether it matches the assignment, and timestamped Workspace Theme Status summarizes applied, pending, and attention counts. Oh My Theme verifies status at startup, before Apply, when Apps opens, and after relevant permission or setup flows rather than continuously watching managed files. An Apply that finds every target unchanged performs no writes and does not replace the Last Apply Transaction used by Undo. This lets selection survive relaunch and represents partial results honestly instead of claiming that one theme is globally current after only some targets changed.
