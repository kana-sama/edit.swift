# Untitled draft recovery

While an untitled buffer has unsaved text, Edit periodically writes a private recovery copy. Continuous typing is checkpointed about twice per second. The draft's recovery copy is separate from the normal session and does not change the edited indicator or Undo history.

On launch, restore the latest complete checkpoint for each interrupted draft. If the saved session already contains a newer version of that draft, use the session version. Show a recovered draft as an unsaved untitled buffer in its previous folder context. Recover independent drafts even if the normal session cannot be read. An unreadable checkpoint is reported separately from other recovered drafts.

Saving, discarding, or undoing a draft back to an empty buffer retires its checkpoint. After a successful Quit, the normal saved session owns its drafts. A checkpoint can recover the last written text after interruption. Edits that arrive after that write can be lost.

## Acceptance

- Edit two untitled buffers in an isolated profile. Stop the process after their checkpoints are written and start it again. Both drafts reopen with their latest recorded text.
- Save or discard a previously checkpointed draft and check that restarting does not reopen it. When a session and a checkpoint refer to the same draft, verify that the most recent recorded version opens once.
