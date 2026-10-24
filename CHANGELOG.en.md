# Changes

The full history in Russian: [CHANGELOG.md](CHANGELOG.md).

## 3.1.0

- **Signed updates.** Every release is signed with a key that is neither on GitHub nor in the repository.
  Updates and automatic updates check the signature with `ssh-keygen` built into macOS and install nothing
  without it: even access to the GitHub account can't push code to the Macs running zapret
- **Switching strategies without a drop.** The engine reads a new strategy on the fly: the network setup,
  the tunnel and the firewall rules stay, the internet drops for a fraction of a second instead of a couple
- **Finding a strategy in seconds.** The current strategy and the ones that worked last time go first, and
  the search stops at the first good one: everything opens, Discord voice works, YouTube is faster than
  1 MB/s. "Check all 37" checks every strategy and takes the fastest
- Checking all of them is faster too: strategies switch without restarting the engine, and the check
  "without zapret" runs in parallel and takes seconds instead of half a minute
- **In English.** The app, zapret's messages and the Terminal menu speak the language of macOS: English
  or Russian. The project description is in [README.en.md](README.en.md) too

From 3.1 you can only go back to signed versions, that is, 3.1 and later.
