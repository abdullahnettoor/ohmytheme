---
status: accepted
---

# Connect the VS Code companion over a Unix-domain socket

The macOS app will communicate with its local VS Code companion through a per-user Unix-domain socket using a versioned request and acknowledgement protocol. Custom VS Code URIs lack a reliable response channel and become ambiguous across profiles and windows, while external settings-file edits bypass VS Code's supported configuration handling. The socket avoids a network listener and lets each extension instance register its identity, apply through `WorkspaceConfiguration.update`, verify the result, and return a receipt-worthy acknowledgement.
