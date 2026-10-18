# Lumina Native Module SDK — Contract V1

Lumina-native modules are JavaScript providers for Lumina Player. They are **not CloudStream Kotlin plugins** and are not automatically compatible with Synthetiq modules. This contract is intentionally small and versioned so provider authors can build modules specifically for Lumina.

## Package layout

A module ZIP must contain exactly one JSON manifest and its JavaScript entry file. The manifest and entry file may be at the ZIP root:

```text
example-provider.zip
├── module.json
└── index.js
```

Example `module.json`:

```json
{
  "id": "example-provider",
  "name": "Example Provider",
  "moduleSystem": "lumina",
  "contractVersion": 1,
  "moduleVersion": "1.0.0",
  "contentType": "video",
  "description": "Example Lumina video provider",
  "config": {
    "runtime": {
      "entry": "index.js"
    }
  }
}
```

## Required JavaScript export

The entry file must assign a global object named `LuminaModule`:

```js
globalThis.LuminaModule = {
  apiVersion: 1,
  contentType: "video",
  search(query) { return []; },
  details(href) { return {}; },
  episodes(href) { return []; },
  stream(episodeHref) { return { url: "https://example.com/video.mp4", headers: {} }; }
};
```

Required functions for video modules:

- `search(query)` returns an array of title cards.
- `details(href)` returns title metadata.
- `episodes(href)` returns an array of episode objects.
- `stream(episodeHref)` returns a direct playable URL, or a list/object containing one, optionally with request headers.

Title cards should use `title`, `href`, and optionally `image`, `year`, and `description`. Episode objects should use `title` and `href`; `season` is optional. Stream results should return `{ url, headers }` where headers is an object of strings.

An optional `home()` function may return a list of title cards or an object with an `items` array.

## Runtime and safety

Modules execute as JavaScript in Lumina's embedded runtime. They should return JSON-serializable values and avoid relying on browser DOM APIs, Node.js APIs, or native Android APIs. Network access depends on the runtime and platform. Only install modules from sources you trust: a module can run code in its JavaScript context and can make network requests allowed by the host.

The installer verifies repository package SHA-256 hashes when installing from a repository and rejects unsafe ZIP paths. A hash verifies package integrity against the catalogue; it does not prove that a provider is safe or that a stream is playable.

## Compatibility policy

- `moduleSystem: "lumina"` with `contractVersion: 1` uses this SDK.
- Modules without `moduleSystem: "lumina"` use the existing Synthetiq compatibility path, which requires Contract V3 or later.
- CloudStream Kotlin plugins are not directly executable by Lumina's Flutter/JavaScript runtime. They must be reimplemented against this API or adapted with permission and license compliance.
- Passing the manifest/handler checks does not guarantee that a provider's website is reachable or that its returned stream is supported by the device's media decoder.

## Reference module

See `examples/lumina-demo/module.json` and `examples/lumina-demo/index.js`. It returns a single public sample video for testing the complete module-to-player path. It is a playback diagnostic, not a content catalogue.
