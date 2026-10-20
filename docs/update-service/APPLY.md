# Apply transactions (P2a)

The live skill path stays a directory. Replacements require an atomic directory
exchange: `renameat2(RENAME_EXCHANGE)` on Linux or `renamex_np(RENAME_SWAP)` on
macOS. If the OS or filesystem does not support exchange, the update fails closed
with an explicit atomic-exchange error and restores any earlier swaps in that
transaction. There is no three-rename fallback and no migration to symlinks. A
transaction that an earlier engine's three-rename fallback left half done is
cleaned up with plain renames, since that fallback only ran where exchange is
unavailable.
First installs and deliberate removals use a single rename. Existing open files
remain usable across an exchange.

`previous/` contains only the skills changed by the most recently committed
transaction, including absence markers for new installs. Older backups and
markers are pruned during commit rotation. Rotation is repeatable after a crash;
revert therefore changes only that transaction's skills. A second revert redoes
those changes.

The committed journal includes the transaction's versions, outcome and
`reload_pending` flag. Recovery finishes rotation and saves the profile record
before deleting the journal. The reload flag remains set until explicitly cleared
by the caller that reloads the gateway. Older committed journals without the flag
conservatively request a reload when they changed `swarmhub-messages`.

An error writing the commit journal, rotating backups, or saving the state record
returns `recovery_pending`: new trees are live and the transaction is retained.
The next apply or revert first recovers it. An open journal rolls back; a committed
journal finishes recording the update. A `reload_pending` in that result is reported
only once it is saved in the profile record. The open journal also carries the flag,
so rolling back a plugin change keeps asking for a reload: the new plugin may have
been loaded while it was live. This also covers a journal rename that
succeeded before its directory fsync failed. The state file can still describe
the preceding completed transaction until recovery succeeds. No reload or service
restart is performed by the engine.
