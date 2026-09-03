---
status: accepted
---

# Bind the companion socket with POSIX APIs instead of Network.framework

`docs/architecture/technical-stack.md` names Network.framework as the
library to use for "the Unix-domain socket". The first companion proof
(#8) instead binds the socket with `Darwin.socket`, `bind`, `listen`,
`accept`, and `DispatchSourceRead`, and this ADR records why the
platform library choice differs in `PlatformClients`.

Network.framework exposes Unix-domain endpoints through
`NWEndpoint.unix(path:)` and can be composed into `NWParameters`, but
its server side does not expose the underlying accepted file
descriptor. The companion's ADR-0009 acceptance rule is that "each
extension instance registers its identity" and, per the technical
stack, the app must "reject another user's peer when peer credentials
are available". On macOS, the only reliable way to read the peer's
effective UID is `getsockopt(fd, SOL_LOCAL, LOCAL_PEEREUID, …)`, which
requires access to the accepted fd itself. Network.framework does not
publish it, so authenticating the peer requires a raw fd path either
way.

The proof also needs `SO_NOSIGPIPE` on both the listening and
accepted descriptors so that a crashed extension cannot terminate the
app with a signal on the next write, and it needs `chmod(2)` on the
socket path immediately after `bind` to enforce the `0600` mode the
technical stack requires. Both are trivial with POSIX and awkward
through Network.framework's higher-level `NWListener` API.

macOS limits a Unix-domain socket path to 103 UTF-8 bytes. The socket
therefore lives at `/tmp/omt-<uid>/<launch-id>/companion.sock` under
private `0700` directories. Before binding, the app rejects a socket
root that is a symbolic link, is not a directory, or belongs to another
user. The rendezvous file remains under the user's Application Support
directory with mode `0600` and publishes the short socket path. Peer
UID verification remains mandatory.

The scope of the affected code is narrow: `CompanionSocketServer` and
`CompanionConnection` are the only new files that touch sockets. They
route every read and write through the codec and session types in the
same target, and the session state machine is fully testable without
any I/O. Nothing else in `PlatformClients` uses Network.framework
either, so the choice does not compete with an existing pattern.

If a future stage introduces a listener that does not need peer
credential inspection or fine-grained socket-mode enforcement, that
listener may use Network.framework and the technical stack does not
need to change. The companion listener stays on POSIX.

The trade-off: the companion server carries a small amount of
platform C surface (four constants, four `Darwin` calls, and a
`DispatchSource` read loop). The tests exercise it end-to-end against
a real Unix-domain socket, so any regression in that surface fails
loudly in CI rather than silently at runtime.
