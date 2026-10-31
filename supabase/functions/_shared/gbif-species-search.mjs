const endpoint = "https://api.gbif.org/v1/species/search";

export function createGBIFSpeciesSearchClient({ request = fetch } = {}) {
  return {
    async search(query, { limit = 20 } = {}) {
      const normalized = String(query ?? "").trim();
      if (normalized.length < 2) return [];
      const url = new URL(endpoint);
      url.searchParams.set("q", normalized);
      url.searchParams.set("rank", "SPECIES");
      url.searchParams.set("limit", String(Math.min(Math.max(limit, 1), 20)));
      const response = await request(url, {
        headers: { "user-agent": "Grove iOS plant companion; https://grove.app" }
      });
      if (!response.ok) throw new Error(`Species catalogue search failed (${response.status}).`);
      const payload = await response.json();
      const seen = new Set();
      const candidates = [];
      for (const usage of payload.results ?? []) {
        const scientificName = usage.canonicalName || usage.scientificName;
        const acceptedKey = usage.acceptedKey || usage.key;
        if (!acceptedKey || !scientificName || seen.has(`gbif:${acceptedKey}`)) continue;
        if (usage.kingdom && !["Plantae", "Viridiplantae"].includes(usage.kingdom)) continue;
        seen.add(`gbif:${acceptedKey}`);
        const englishName = usage.vernacularNames?.find((name) => name.language === "eng")?.vernacularName
          || usage.vernacularNames?.[0]?.vernacularName;
        candidates.push({
          id: `gbif:${acceptedKey}`,
          commonName: englishName || scientificName,
          scientificName,
          confidence: 100,
          distinguishingTraits: [],
          regionalFit: "Taxonomy match from GBIF",
          canonicalTaxonID: `gbif:${acceptedKey}`
        });
      }
      return candidates;
    }
  };
}
