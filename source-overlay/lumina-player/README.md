# Lumina-Player

## Synthetiq module support

Lumina can browse the public Synthetiq module catalogue, verify repository ZIP downloads against the catalogue SHA-256 value, import local ZIPs, and execute compatible local module JavaScript using the embedded FJS runtime.

The installer accepts the documented single-JSON-manifest package layout (for example, `example-module/example-module.json`) and normalizes its manifest to `module.json` in Lumina's private module storage. The runtime currently checks for the required handler exports for the module's content type and supports Contract V3 or later at the manifest gate.

**Important:** compiling the APK and seeing handler exports does not prove that a provider works end to end. Network fetch compatibility, real search results, detail/episode parsing, media URL resolution, headers/subtitles, and actual playback must be tested with a known authorised module. Report playback as unverified until that full test passes.
