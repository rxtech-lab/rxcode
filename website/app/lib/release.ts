import "server-only";

const RELEASE_API =
  "https://api.github.com/repos/rxtech-lab/rxcode/releases/latest";
const FALLBACK_TAG = "v1.0.1";
const FALLBACK_DMG =
  "https://github.com/rxtech-lab/rxcode/releases/download/v1.0.1/RxCode.dmg";
const FALLBACK_PAGE =
  "https://github.com/rxtech-lab/rxcode/releases/tag/v1.0.1";

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
