---
status: accepted
---

# Derive onboarding progress from domain state

Oh My Theme will persist whether onboarding is in progress, deferred, or completed, but it will not persist a wizard page number as the source of truth. On launch it derives the next useful step from the desired Theme Assignment, Target Opt-ins, connection states, permissions, and interrupted operations. This keeps resumption valid when applications or configuration change while the app is closed.
