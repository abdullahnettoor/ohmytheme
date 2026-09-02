---
status: accepted
---

# Distribute directly without App Sandbox

Oh My Theme will ship outside the Mac App Store with App Sandbox disabled because its core job requires discovering developer tools, resolving symlinks, running documented commands, and changing user-approved configuration files in locations that are impractical to manage through repeated file pickers and security-scoped bookmarks. The app remains unprivileged, uses no daemon or installer helper, and will adopt Hardened Runtime, Developer ID signing, and notarization before external distribution.
