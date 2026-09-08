---
status: accepted
---

# Journal selected-target setup as one transaction

One Configure Selected Apps action will create one durable Setup Transaction from an approved Setup Plan containing the reviewed Connection Plan or preparation failure for every selected Target Instance. The transaction keeps a separate outcome and recovery record for each instance and permits partial success because configuration changes across macOS and third-party apps cannot be atomic. Closing the window does not cancel setup. Cancel Remaining finishes the current target boundary and skips targets not yet started. The progress interface explains each macOS-owned permission prompt immediately before the transaction reaches that target. Permission denial fails only the affected target, preserves its Target Opt-in, and does not stop unrelated targets. Retry Remaining creates a new linked Setup Transaction from freshly prepared plans. If configuration changes after aggregate review, Oh My Theme invalidates the stale plans, highlights the changes, and requires one new aggregate confirmation. Implementing setup as an unrecorded UI loop over independent connection operations would make interruption recovery, progress, and retry behavior disagree with the single action the user initiated.
