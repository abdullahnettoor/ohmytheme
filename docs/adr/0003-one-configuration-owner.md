---
status: accepted
---

# Give each managed artifact one configuration owner

Oh My Theme will not write a target artifact that Nix, Home Manager, another manager, or the target application already owns. Direct adapters stop on Nix-managed paths and require review before changing ordinary linked dotfiles. Nix is not the MVP apply engine; a later export can generate a module for the user's existing configuration without editing or activating it.
