# References

## Protocol specification

| Reference | Use |
|---|---|
| [SLSKPROTOCOL.md](SLSKPROTOCOL.md) | Local copy of the Nicotine+ protocol documentation. This is the main specification for libslsk. The header gives the source commit. |
| [Nicotine+ protocol documentation (online)](https://nicotine-plus.org/doc/SLSKPROTOCOL.html) | The current version. Compare it with the local copy to find changes. |
| [aioslsk message reference](https://aioslsk.readthedocs.io/en/stable/MESSAGES.html) | A second message description. Use it when the main specification is unclear. |
| [aioslsk connection and transfer flows](https://aioslsk.readthedocs.io/en/stable/SOULSEEK.html) | Sequence descriptions for peer connections and transfers (M3, M5). |

## Reference implementations

| Reference | License | Use |
|---|---|---|
| [Nicotine+ `slskmessages.py`](https://github.com/nicotine-plus/nicotine-plus/blob/master/pynicotine/slskmessages.py) | GPL-3.0-or-later | Pack and unpack code for each message. |
| [Nicotine+ `test_slskmessages.py`](https://github.com/nicotine-plus/nicotine-plus/blob/master/pynicotine/tests/unit/protocol/test_slskmessages.py) | GPL-3.0-or-later | Golden byte vectors for client-to-server messages (D1.2). It has no peer or distributed vectors. |
| [Soulseek.NET](https://github.com/jpdillingham/Soulseek.NET) | GPL-3.0 | A mature client library. Use it to check connection and transfer logic (M3, M5). |
| [aioslsk](https://github.com/JurgenR/aioslsk) | GPL-3.0 | A client library with a mock server for end-to-end tests. Use it for ideas for `tests/fake_server.zig` (M7). |
| [Soulfind](https://github.com/soulfind-dev/soulfind) | GPL-3.0-or-later | The local test server. [`src/server/messages.d`](https://github.com/soulfind-dev/soulfind/blob/master/src/server/messages.d) gives the exact server messages that integration tests see. |

All these licenses are compatible with the libslsk license (AGPL-3.0). If you port code from them, keep the copyright notices and record the source in a comment.

## Design and style

| Reference | Use |
|---|---|
| [Sans-I/O](https://sans-io.readthedocs.io/how-to-sans-io.html) | The design pattern for `slsk.core`. |
| [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md) | The source document for the `zig-tiger-style` skill. |

## Network rules

- The official server identifies clients by the version in `Login`. Each application that uses libslsk must send its own minor version. Do not use one fixed value for all applications.
- The Nicotine+ documentation asks that implementations do not extend the protocol without approval from the Soulseek administrators. libslsk implements only messages that the specification documents.
