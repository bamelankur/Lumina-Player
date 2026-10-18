# Lumina-Player

## Module manager (initial implementation)

Lumina includes a Modules tab with local ZIP import and a read-only browser for the Synthetiq public module catalogue. Imported packages must contain `module.json` and their declared entry file. Repository downloads are checked against the catalogue's SHA-256 value before installation. ZIP entries are checked for unsafe paths and size limits.

**Compatibility note:** this version stores and manages module packages; it does not yet execute module JavaScript or implement the Synthetiq contract-v4 API. An installed module will therefore not automatically appear as a working content provider or become playable until a compatible sandboxed JS runtime and the matching provider/playback API are implemented.
