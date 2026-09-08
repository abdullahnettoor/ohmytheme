---
status: accepted
---

# Pause apply on known preflight problems

If preparation finds a conflict, new or changed ownership, a new permission requirement, or an ambiguous target before mutation begins, Oh My Theme will not silently apply the theme to the remaining targets. It will show the problem and offer an explicit Apply to Ready Targets action. A previously acknowledged unavailable target or documented reload or restart requirement does not repeatedly block Apply. Failures discovered after mutation begins still produce partial results under ADR 0005, because those failures cannot always be predicted or rolled back safely.
