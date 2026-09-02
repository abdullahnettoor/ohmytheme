---
status: accepted
---

# Use a native Swift macOS stack

Oh My Theme will use Swift 6 and SwiftUI, with focused AppKit bridges, and target macOS 14 Sonoma or later. A cross-platform shell would add a runtime and IPC layer while providing little benefit to a macOS-specific utility that depends on Apple Events, AppKit, ServiceManagement, Launch Services, and direct filesystem integration. The engine and adapters remain plain Swift modules rather than depending on SwiftUI.
