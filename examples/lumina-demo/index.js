// Lumina Native Module SDK v1 reference provider.
// This module exists only to verify the runtime-to-player pipeline.
const sample = {
  title: "Big Buck Bunny — Playback Test",
  href: "lumina-demo-big-buck-bunny",
  image: "https://peach.blender.org/wp-content/uploads/title_anouncement.jpg?x11217",
  year: "2008",
  description: "Public sample video used to test playback. Not a catalogue provider."
};

globalThis.LuminaModule = {
  apiVersion: 1,
  contentType: "video",

  search(query) {
    const q = String(query || "").trim().toLowerCase();
    if (!q || sample.title.toLowerCase().includes(q) || "big buck bunny playback test".includes(q)) {
      return [sample];
    }
    return [];
  },

  details(href) {
    if (href !== sample.href) return null;
    return { ...sample, description: "Lumina module diagnostic item. Select the episode to test playback." };
  },

  episodes(href) {
    if (href !== sample.href) return [];
    return [{
      title: "Sample video",
      href: "lumina-demo-big-buck-bunny-episode-1",
      season: "1"
    }];
  },

  stream(episodeHref) {
    if (episodeHref !== "lumina-demo-big-buck-bunny-episode-1") return null;
    return {
      url: "https://storage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4",
      headers: {}
    };
  },

  home() {
    return [sample];
  }
};
