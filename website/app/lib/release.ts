import "server-only";

const RELEASE_API =
  "https://api.github.com/repos/rxtech-lab/rxcode/releases/latest";
const RELEASES_API =
  "https://api.github.com/repos/rxtech-lab/rxcode/releases?per_page=10";
const FALLBACK_TAG = "v1.0.1";
const FALLBACK_DMG =
  "https://github.com/rxtech-lab/rxcode/releases/download/v1.0.1/RxCode.dmg";
const FALLBACK_PAGE =
  "https://github.com/rxtech-lab/rxcode/releases/tag/v1.0.1";

export const SPARKLE_APPCAST_URL = "https://update.code.rxlab.app/appcast.xml";

export type ReleaseInfo = {
  tag: string;
  version: string;
  publishedAt: string | null;
  dmgUrl: string;
  releasePageUrl: string;
  sizeBytes: number | null;
};

type GitHubAsset = {
  name: string;
  browser_download_url: string;
  size: number;
};

type GitHubRelease = {
  tag_name: string;
  name: string;
  html_url: string;
  published_at: string;
  body: string | null;
  prerelease: boolean;
  assets: GitHubAsset[];
};

export async function getLatestRelease(): Promise<ReleaseInfo> {
  try {
    const res = await fetch(RELEASE_API, {
      headers: {
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
      },
      next: { revalidate: 600 },
    });

    if (!res.ok) throw new Error(`GitHub API ${res.status}`);

    const data = (await res.json()) as GitHubRelease;
    const dmg =
      data.assets.find((a) => a.name.toLowerCase().endsWith(".dmg")) ?? null;

    return {
      tag: data.tag_name,
      version: data.tag_name.replace(/^v/, ""),
      publishedAt: data.published_at ?? null,
      dmgUrl:
        dmg?.browser_download_url ??
        `https://github.com/rxtech-lab/rxcode/releases/download/${data.tag_name}/RxCode.dmg`,
      releasePageUrl: data.html_url,
      sizeBytes: dmg?.size ?? null,
    };
  } catch {
    return {
      tag: FALLBACK_TAG,
      version: FALLBACK_TAG.replace(/^v/, ""),
      publishedAt: null,
      dmgUrl: FALLBACK_DMG,
      releasePageUrl: FALLBACK_PAGE,
      sizeBytes: null,
    };
  }
}

export function formatSize(bytes: number | null): string | null {
  if (!bytes) return null;
  const mb = bytes / (1024 * 1024);
  return `${mb.toFixed(1)} MB`;
}

export type SparkleItem = {
  version: string;
  shortVersionString: string;
  pubDate: string | null;
  releaseNotesUrl: string | null;
  link: string | null;
  enclosureUrl: string | null;
  enclosureSize: number | null;
  minimumSystemVersion: string | null;
};

export type SparkleRelease = SparkleItem & {
  releaseNotesHtml: string | null;
};

export type AppReleaseNote = SparkleRelease & {
  tag: string;
  isPrerelease: boolean;
  releaseNotesMarkdown: string | null;
};

function pickTag<T extends string>(xml: string, tag: T): string | null {
  const match = xml.match(
    new RegExp(`<${tag}[^>]*>([\\s\\S]*?)<\\/${tag}>`, "i")
  );
  return match ? match[1].trim() : null;
}

function pickAttr(xml: string, tag: string, attr: string): string | null {
  const match = xml.match(
    new RegExp(`<${tag}\\b[^>]*\\b${attr}="([^"]*)"`, "i")
  );
  return match ? match[1] : null;
}

function parseSparkleItems(xml: string): SparkleItem[] {
  const items: SparkleItem[] = [];
  const itemRegex = /<item\b[^>]*>([\s\S]*?)<\/item>/gi;
  let m: RegExpExecArray | null;
  while ((m = itemRegex.exec(xml)) !== null) {
    const body = m[1];
    items.push({
      version: pickTag(body, "sparkle:version") ?? "",
      shortVersionString:
        pickTag(body, "sparkle:shortVersionString") ??
        pickTag(body, "title") ??
        "",
      pubDate: pickTag(body, "pubDate"),
      releaseNotesUrl: pickTag(body, "sparkle:releaseNotesLink"),
      link: pickTag(body, "link"),
      enclosureUrl: pickAttr(body, "enclosure", "url"),
      enclosureSize: (() => {
        const raw = pickAttr(body, "enclosure", "length");
        const n = raw ? Number(raw) : NaN;
        return Number.isFinite(n) ? n : null;
      })(),
      minimumSystemVersion: pickTag(body, "sparkle:minimumSystemVersion"),
    });
  }
  return items;
}

function extractHtmlBody(html: string): string {
  const bodyMatch = html.match(/<body\b[^>]*>([\s\S]*?)<\/body>/i);
  const inner = bodyMatch ? bodyMatch[1] : html;
  return inner
    .replace(/<script\b[\s\S]*?<\/script>/gi, "")
    .replace(/<style\b[\s\S]*?<\/style>/gi, "")
    .trim();
}

function resolveUrl(base: string, relative: string): string {
  try {
    return new URL(relative, base).toString();
  } catch {
    return relative;
  }
}

async function fetchReleaseNotes(url: string): Promise<string | null> {
  try {
    const res = await fetch(url, { next: { revalidate: 600 } });
    if (!res.ok) return null;
    const html = await res.text();
    return extractHtmlBody(html);
  } catch {
    return null;
  }
}

export async function getSparkleReleases(): Promise<SparkleRelease[]> {
  try {
    const res = await fetch(SPARKLE_APPCAST_URL, {
      next: { revalidate: 600 },
    });
    if (!res.ok) return [];
    const xml = await res.text();
    const items = parseSparkleItems(xml);

    const enriched = await Promise.all(
      items.map(async (item) => {
        const url = item.releaseNotesUrl
          ? resolveUrl(SPARKLE_APPCAST_URL, item.releaseNotesUrl)
          : null;
        const releaseNotesHtml = url ? await fetchReleaseNotes(url) : null;
        return { ...item, releaseNotesUrl: url, releaseNotesHtml };
      })
    );

    return enriched.sort((a, b) => {
      const ad = a.pubDate ? Date.parse(a.pubDate) : 0;
      const bd = b.pubDate ? Date.parse(b.pubDate) : 0;
      return bd - ad;
    });
  } catch {
    return [];
  }
}

export async function getAppReleaseNotes(): Promise<AppReleaseNote[]> {
  try {
    const res = await fetch(RELEASES_API, {
      headers: {
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
      },
      next: { revalidate: 600 },
    });

    if (!res.ok) throw new Error(`GitHub API ${res.status}`);

    const releases = (await res.json()) as GitHubRelease[];

    return releases
      .filter((release) => release.tag_name)
      .map((release) => {
        const tag = release.tag_name;
        const dmg =
          release.assets.find((asset) =>
            asset.name.toLowerCase().endsWith(".dmg")
          ) ?? null;
        return {
          tag,
          version: "",
          shortVersionString: tag.replace(/^v/i, ""),
          pubDate: release.published_at ?? null,
          releaseNotesUrl: null,
          link: release.html_url,
          enclosureUrl: dmg?.browser_download_url ?? null,
          enclosureSize: dmg?.size ?? null,
          minimumSystemVersion: null,
          releaseNotesHtml: null,
          releaseNotesMarkdown: release.body?.trim() || null,
          isPrerelease: release.prerelease,
        };
      });
  } catch {
    return [];
  }
}

export function formatPubDate(pubDate: string | null): string | null {
  if (!pubDate) return null;
  const ts = Date.parse(pubDate);
  if (!Number.isFinite(ts)) return null;
  return new Date(ts).toLocaleDateString("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
  });
}
