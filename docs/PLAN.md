# Implementation plan for libslsk

## Progress

Check a deliverable when its PR merges, and add the PR number, for example `- [x] D0.1: Project skeleton (#3)`. Check a milestone when all its deliverables are checked.

- [x] M0: Project setup
  - [x] D0.1: Project skeleton (#1)
  - [x] D0.2: Soulfind test harness (#2)
- [ ] M1: `slsk.proto` wire codecs
  - [x] D1.1: Wire primitives and frame decoder (#3)
  - [x] D1.2: Server messages (#4)
  - [ ] D1.3: Peer messages
  - [ ] D1.4: File-connection and distributed messages
- [ ] M2: Core skeleton, server session, first end-to-end test
  - [ ] D2.1: Core skeleton
  - [ ] D2.2: Server login and session
  - [ ] D2.3: Zig `Client` driver v0 on `std.Io`
  - [ ] D2.4: C ABI v0
- [ ] M3: Peer connections
  - [ ] D3.1: Outgoing direct connections
  - [ ] D3.2: Incoming connections
  - [ ] D3.3: Indirect connections
- [ ] M4: Search
  - [ ] D4.1: Outgoing search
  - [ ] D4.2: Answers to searches
- [ ] M5: Transfers
  - [ ] D5.1: Download negotiation
  - [ ] D5.2: Upload side
  - [ ] D5.3: Data path in the driver
- [ ] M6: Browse, user info, chat, rooms, status
  - [ ] D6.1: Browse and user info
  - [ ] D6.2: Server social features
- [ ] M7: Distributed network
  - [ ] D7.1: Fake server and parent selection
  - [ ] D7.2: Branch information
  - [ ] D7.3: Search relay
- [ ] M8: C library release
  - [ ] D8.1: ABI versioning and install
  - [ ] D8.2: C API documentation and second-language test

## Architecture

```
slsk.proto    wire codecs: pure encode/decode, no state
slsk.core     sans-IO state machine: no Io, no clock, no sockets
slsk.Client   Zig driver: takes `io: std.Io`, runs the core
libslsk (C)   exports the core through a C ABI
```

- The core decides what to do. The host does all I/O.
- The host gives the core bytes, connection events, timer events, and the current time (`now_ms`).
- The core returns actions (`open_conn`, `send`, `close`, `set_timer`, `listen`, `transfer_ready`) and application events.
- The Zig `Client` is one host. It uses `std.Io`.
- C users drive the core from their own event loop.
- A managed C client (with an internal `Io`) is out of scope for now.

## Ground rules

- Each deliverable is one branch and one PR. Each PR is small enough for one review session.
- A deliverable is done when its tests pass in `zig build test`, and in `zig build itest` if it has integration tests.
- Unit tests use `std.testing.allocator`, so each test also checks for memory leaks.
- The C ABI starts early (D2.4) and grows with each milestone. Then ABI design problems show up early.

## Facts about Soulfind that affect the plan

We use [Soulfind](https://github.com/soulfind-dev/soulfind) as the local test server. These facts change how we test:

- **Users register automatically.** With `private_mode` off (the default), the first `Login` for a new name creates the user. Tests do not need `soulsetup`.
- **Usernames must be printable ASCII.** Tests use names such as `itest-<random>`. A random suffix prevents `Relogged` conflicts between test runs.
- **Search is a direct broadcast.** The server sends `FileSearch` to every connected user. The searcher also gets its own search back, so the core must ignore it.
- **Searches arrive in batches.** Expect a short delay. Integration tests must wait with a timeout, not a fixed sleep.
- **Soulfind has no distributed network.** It ignores `HaveNoParent`, `BranchLevel`, and related messages. It never sends `PossibleParents` or `EmbeddedMessage`. M7 uses a fake server instead.
- **The Docker image is `ghcr.io/soulfind-dev/soulfind`.** The default port is 2242.
- **Soulfind is GPL-3.0.** We only run it as an external test tool. We do not link it.

---

## M0: Project setup

### D0.1: Project skeleton

- `build.zig` and `build.zig.zon` for Zig 0.17.1. Set `minimum_zig_version` to `0.17.1`.
- Modules: `slsk` (Zig API), a static C library, and a shared C library.
- `include/slsk.h` with one function: `slsk_version()`.
- CI on GitHub Actions for Linux and macOS.

**Validation:**

- `zig build` makes both libraries.
- `zig build test` runs one trivial test.
- A C smoke program in `tests/c/` links the library and calls `slsk_version()`. `build.zig` builds and runs it.

### D0.2: Soulfind test harness

- `scripts/soulfind.sh up|down` starts the Docker container with a new temporary volume and stops it.
- `zig build itest` runs integration tests. The step reads `SLSK_SOULFIND=host:port`. If the variable is not set, the step skips with a message.
- CI runs integration tests on Linux only. GitHub macOS runners do not have Docker.

**Validation:**

- A test opens a TCP connection to Soulfind and closes it.
- `itest` skips cleanly when Soulfind is not running.

---

## M1: `slsk.proto` (wire codecs)

### D1.1: Wire primitives and frame decoder

- Little-endian integers, `bool`, length-prefixed strings, and the reversed IPv4 byte order.
- Frame formats:
  - Server and peer messages: `u32 length` and `u32 code`.
  - Peer init and distributed messages: `u8 code`.
- An incremental frame decoder. It accepts partial reads and returns complete frames.

**Validation:**

- Unit tests for each primitive, with round trips.
- Decoder tests that split input at every byte position.
- A fuzz test with `std.testing.fuzz`. The decoder must not crash on random input, and it must return errors for oversize frames.

### D1.2: Server messages

- The messages that M2 to M4 need:
  - `Login`, `SetWaitPort`, `GetPeerAddress`
  - `ConnectToPeer`, `CantConnectToPeer`
  - `FileSearch`, `WatchUser`, `GetUserStatus`
  - `MessageUser`, `MessageAcked`, `Relogged`, `ServerPing`
- One `union(enum)` for each direction. The same code has a different layout in each direction.
- An unknown code decodes to `.unknown` with the raw bytes. It is not an error.

**Validation:**

- Golden byte vectors from the protocol documentation and from the Nicotine+ test suite.
- Round-trip tests for each message.
- A test that an unknown code gives `.unknown`.

### D1.3: Peer messages

- `PeerInit` and `PierceFirewall`.
- Peer messages:
  - `SharedFileListRequest` and `SharedFileListResponse`
  - `FileSearchResponse`, `UserInfoRequest`, and `UserInfoResponse`
  - `FolderContentsRequest` and `FolderContentsResponse`
  - `TransferRequest` and `TransferResponse`
  - `QueueUpload`, `PlaceInQueueRequest`, and `PlaceInQueueResponse`
  - `UploadFailed` and `UploadDenied`
- zlib compression with `std.compress.flate` for the compressed messages.

**Validation:**

- Golden vectors and round trips, the same as D1.2.
- A test that bad zlib data gives an error and does not crash.

### D1.4: File-connection and distributed messages

- The `F` connection handshake: a `u32` token, then a `u64` offset.
- Distributed messages: `Ping`, `Search`, `BranchLevel`, `BranchRoot`, `ChildDepth`, and `EmbeddedMessage`.

**Validation:**

- The same method as D1.2.

**Optional check at the end of M1:** Capture traffic between Nicotine+ and Soulfind. Run the decoder on each frame in the capture. Each frame must decode with no `.unknown` for the codes that we implement.

---

## M2: Core skeleton, server session, first end-to-end test

### D2.1: Core skeleton

- `Core` struct with an allocator, an action queue, an event queue, and a connection handle table.
- Time is an input (`now_ms`). The core exposes one "next deadline" value.
- The connection lifecycle API: `connOpened`, `connFailed`, `connData`, `connClosed`, `timerFired`.
- A `TestHost` helper for unit tests. It feeds scripted inputs and records the actions.

**Validation:**

- Unit tests for handle allocation, queue order, and timer deadlines.
- All tests are deterministic. They use no sockets and no real clock.

### D2.2: Server login and session

- On start, the core emits `open_conn` to the server.
- Then it sends `Login` and `SetWaitPort`, and emits `logged_in` or `login_failed`.
- A `ServerPing` timer.
- `Relogged` handling.
- The application sets the client version in `Login`. The official server identifies clients by the minor version, so libslsk has no fixed default for it.
- Reconnect after a disconnect, with backoff.

**Validation:**

- Scripted unit tests for these cases:
  - login success
  - each rejection reason
  - `Relogged`
  - server disconnect and reconnect with the correct backoff times

### D2.3: Zig `Client` driver v0 on `std.Io`

- `slsk.Client` takes `io: std.Io`. It does the connect, read, write, and timer work for the server connection only.
- `examples/slsk-cli login <user> <pass>`.

**Validation (first Soulfind integration test):**

- A new user logs in.
- The same user logs in again with a wrong password and gets `INVALIDPASS`.
- A second login with the same user makes the first client get `Relogged`.

### D2.4: C ABI v0

- `slsk_core_create`, `slsk_core_destroy`, the connection input functions, `slsk_core_next_action`, and `slsk_core_next_event` for login only.
- `include/slsk.h` is written by hand.
- Layout checks: Zig `comptime` asserts on `@sizeOf` and `@offsetOf`. The C test has `_Static_assert` checks with the same values.

**Validation:**

- A C test host with a `poll()` loop in `tests/c/login.c` logs in to Soulfind.
- This also proves that the ABI works without Zig.

---

## M3: Peer connections

### D3.1: Outgoing direct connections

- `GetPeerAddress`, then `open_conn`, then `PeerInit`.
- One `P` connection per user, used again for later messages.
- Dispatch of messages by connection type (`P`, `F`, `D`).

### D3.2: Incoming connections

- A `listen` action and `connAccepted`.
- The core reads the first message (`PeerInit` or `PierceFirewall`) and binds the connection to a user and a type.

### D3.3: Indirect connections

- If the direct connection fails or times out, the core sends `ConnectToPeer` through the server. Then it waits for `PierceFirewall` with the same token.
- If that also times out, the core sends `CantConnectToPeer`.
- When the server sends `ConnectToPeer` to us, the core opens a connection and sends `PierceFirewall`.

**Validation for M3:**

- Unit tests for each path, including each timeout and a race between the direct and indirect paths.
- Integration tests with two clients in one test process against Soulfind:
  - Client A connects directly to client B.
  - Client B advertises a wrong port with `SetWaitPort`. Then A cannot connect directly, so the test checks the indirect path.
  - Client B is offline. Then A gets `CantConnectToPeer`.

---

## M4: Search

### D4.1: Outgoing search

- `FileSearch`, `UserSearch`, `RoomSearch`, and `WishlistSearch`.
- The core matches each `FileSearchResponse` to its search token and emits `search_result` events.
- A search ends after a timeout, or when the host cancels it.

### D4.2: Answers to searches

- The host gives the core a share index: paths, sizes, and attributes. The core does not read the disk.
- Soulseek match rules: all terms must match, and `-term` excludes.
- The core answers `FileSearch` from the server. It ignores its own searches.
- The same share index serves browse requests in M6.

**Validation for M4:**

- Unit tests for the matcher: case, exclusions, and path separators.
- Integration test: client A shares fixture files, and client B searches. B gets the expected results, and A ignores its own searches.
- A C test for search through the ABI.

---

## M5: Transfers

### D5.1: Download negotiation

- `QueueUpload`, then the uploader's `TransferRequest`, then `TransferResponse`.
- Then an `F` connection with the token and offset, then the `transfer_ready` handoff.
- `PlaceInQueue`, `UploadFailed`, and `UploadDenied`.

### D5.2: Upload side

- An upload queue and slot limits.
- The core sends `TransferRequest` when a slot is free. Then it opens the `F` connection and does the handoff.

### D5.3: Data path in the driver

- The driver moves file bytes with `std.Io` file APIs. It resumes from the offset and reports progress.
- Cancel for a transfer that is in progress.

**Validation for M5:**

- Unit tests for both state machines, including deny, fail, and cancel.
- Integration tests:
  - Client B downloads a random 10 MiB file from client A. The test compares SHA-256 hashes.
  - Resume: stop a download halfway, start it again, and compare the hashes.
  - The same download through an indirect connection.
  - A request for a file that is not shared gives `UploadDenied`.

---

## M6: Browse, user info, chat, rooms, status

### D6.1: Browse and user info

- `SharedFileList`, `FolderContents`, and `UserInfo`, from the D4.2 share index.

### D6.2: Server social features

- Private messages, rooms, `WatchUser`, user status, and basic privileges.

**Validation for M6:**

- Integration tests against Soulfind. Soulfind supports all of these features.
- Client B browses client A, and the test compares the result with the fixture tree.
- A private message from A to B, sent while B is offline, arrives when B logs in.

---

## M7: Distributed network

Soulfind does not support this network, so we test it with a fake server.

### D7.1: Fake server and parent selection

- A fake server in Zig in `tests/fake_server.zig`. It runs in-process and sends `PossibleParents` and `EmbeddedMessage`.
- Parent selection from `PossibleParents`, and `HaveNoParent`.

### D7.2: Branch information

- `BranchLevel`, `BranchRoot`, and `ChildDepth`, sent to the server and to children.

### D7.3: Search relay

- Search relay to children, and `EmbeddedMessage`.

**Validation for M7:**

- Unit tests for parent selection, branch updates, and relay, with `TestHost`.
- Tests with three clients in a chain and the fake server. A search from the fake server must reach the child at the end of the chain, and the child must answer.
- Optional manual test against the official server with a test account.

This milestone is important for real use. On the official server, most searches arrive through the distributed network. If real-world use becomes a priority, move M7 before M6.

---

## M8: C library release

### D8.1: ABI versioning and install

- `slsk_abi_version()` and ABI versioning rules.
- Install rules for the header, the static library, the shared library, and a `pkg-config` file.

**Validation:**

- `zig build install` puts all files in the correct directories.
- A C program outside the repository builds with `pkg-config --cflags --libs slsk`.

### D8.2: C API documentation and second-language test

- API documentation: buffer lifetime, thread rules (one thread per `slsk_core`), and error codes.
- A Python `ctypes` smoke test. It proves that the ABI works from a second language.

**Validation:**

- The Python test logs in to Soulfind through the shared library.

---

## Work that continues in all milestones

- The fuzz tests from D1.1 grow with each new message.
- Each milestone updates the C test host in `tests/c/`.
- `examples/slsk-cli` gets one new command for each milestone, for manual checks.

## Open decisions

1. **M7 before M6?** This depends on how soon the library must work on the official network.
2. **Share index in the core (D4.2), or an event that the host answers?** The current plan uses an index. It keeps the C API simpler and makes browse work with no extra host code. An event-based design gives hosts more control.
