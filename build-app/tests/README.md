# Metro runner contract tests

Run the native platform contract:

```sh
./build-app/tests/run-metro-contract.sh
```

On a machine with Docker, reproduce the production Linux failure directly:

```sh
./build-app/tests/run-metro-contract-in-linux.sh
```

The suite executes the real `run-metro.sh` and the real host OS detection. It
fakes only process boundaries that must not mutate the developer machine:
`tuft`, the supervisor, port inspection, and HTTP. The assertions intentionally
cover the whole transaction, not just the missing `launchctl` command:

- native supervisor selection and persistent environment;
- fail-fast behavior before a public binding exists;
- rollback ownership for new versus pre-existing bindings;
- process cleanup after failed end-to-end verification;
- explicit-port collision handling;
- safe host/service identifiers and project-path quoting.

These are contract tests, so they should remain valid if the implementation is
split into a portable supervisor adapter. The Linux expectation is a Tuft-owned
persistent process interface because production cloud VMs intentionally have no
ambient launchd or systemd user service manager.
