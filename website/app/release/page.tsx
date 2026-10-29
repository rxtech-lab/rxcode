import type { Metadata } from "next";
import ReactMarkdown from "react-markdown";
import { AppleIcon, ArrowRightIcon, Eyebrow, GITHUB_REPO_URL, GitHubIcon } from "../home/ui";
import {
  getAppReleaseNotes,
  formatPubDate,
  formatSize,
  getLatestRelease,
  type AppReleaseNote,
} from "../lib/release";
import { SiteFooter } from "../site-footer";
import { SiteNav } from "../site-nav";
import { TrackedLink } from "../tracked-link";

export const metadata: Metadata = {
  title: "RxCode — Release Notes",
  description:
    "The latest updates for the RxCode macOS app, including new features, improvements, and fixes.",
  alternates: { canonical: "/release" },
};

export default async function ReleasePage() {
  const [latest, releases] = await Promise.all([
    getLatestRelease(),
    getAppReleaseNotes(),
  ]);

  return (
    <>
      <SiteNav dmgUrl={latest.dmgUrl} />
      <main className="flex-1 pb-28">
        <Header latest={releases[0]} dmgUrl={latest.dmgUrl} />
        <ReleaseList releases={releases} latestDmg={latest.dmgUrl} />
      </main>
      <SiteFooter />
    </>
  );
}

function versionAnchor(release: AppReleaseNote) {
  return `v${release.shortVersionString}`;
}

/** Drop the generated "## [1.2.3](…) (date)" heading — the entry already shows it. */
function stripVersionHeading(markdown: string, version: string) {
  const escaped = version.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return markdown
    .replace(new RegExp(`^\\s*#{1,3}\\s*\\[?v?${escaped}\\b.*(\\r?\\n)+`), "")
    .trim();
}

function Header({
  latest,
  dmgUrl,
}: {
  latest: AppReleaseNote | undefined;
  dmgUrl: string;
}) {
  const meta = latest
    ? [
        formatPubDate(latest.pubDate),
        formatSize(latest.enclosureSize),
      ].filter(Boolean)
    : [];

  return (
    <section className="relative overflow-hidden pt-36 pb-16 md:pt-44">
      <div className="aurora pointer-events-none absolute inset-x-0 -top-48 h-[700px] opacity-60" />
      <div className="pointer-events-none absolute inset-0 bg-dots opacity-25 [mask-image:radial-gradient(ellipse_at_top,black_20%,transparent_65%)]" />
      <div className="relative mx-auto max-w-[var(--container-max)] px-6">
        <Eyebrow>Changelog</Eyebrow>
        <h1 className="mt-6 max-w-3xl font-display text-5xl font-semibold leading-[1.02] tracking-[-0.04em] md:text-7xl">
          What&apos;s new in <span className="text-gradient-primary">RxCode</span>
        </h1>
        <p className="mt-6 max-w-2xl text-lg leading-relaxed text-on-surface-variant">
          New features, improvements and fixes for the RxCode macOS app. The
          app updates itself — this is where you see what changed.
        </p>

        <div className="mt-10 flex flex-col gap-3 sm:flex-row sm:items-center">
          <TrackedLink
            href={latest?.enclosureUrl ?? dmgUrl}
            analyticsEventName="download_button_click"
            analyticsLabel={latest ? `Download ${versionAnchor(latest)}` : "Download latest build"}
            analyticsLocation="release_header"
            className="btn-primary"
          >
            <AppleIcon className="h-4 w-4" />
            Download {latest ? versionAnchor(latest) : "latest"}
          </TrackedLink>
          <a
            href={`${GITHUB_REPO_URL}/releases`}
            target="_blank"
            rel="noreferrer"
            className="btn-secondary"
          >
            <GitHubIcon className="h-4 w-4" />
            All releases on GitHub
          </a>
          {meta.length > 0 && (
            <span className="font-mono text-[11px] uppercase tracking-[0.2em] text-on-surface-variant/70 sm:ml-3">
              {meta.join(" · ")}
            </span>
          )}
        </div>
      </div>
    </section>
  );
}

function ReleaseList({
  releases,
  latestDmg,
}: {
  releases: AppReleaseNote[];
  latestDmg: string;
}) {
  if (releases.length === 0) {
    return (
      <section className="mx-auto w-full max-w-[var(--container-max)] px-6">
        <div className="glass-panel flex min-h-[360px] w-full flex-col items-center justify-center gap-4 rounded-[28px] p-10 text-center">
          <h2 className="font-display text-2xl font-semibold tracking-tight">
            Release notes are temporarily unavailable
          </h2>
          <p className="max-w-md text-on-surface-variant">
            We couldn&apos;t reach GitHub just now. You can still grab the latest
            build, or check back in a few minutes.
          </p>
          <TrackedLink
            href={latestDmg}
            analyticsEventName="download_button_click"
            analyticsLabel="Download latest build"
            analyticsLocation="release_empty_state"
            className="btn-secondary mt-2"
          >
            <AppleIcon className="h-4 w-4" />
            Download latest build
          </TrackedLink>
        </div>
      </section>
    );
  }

  return (
    <section className="mx-auto grid max-w-[var(--container-max)] gap-10 px-6 lg:grid-cols-[200px_minmax(0,1fr)] lg:gap-16">
      <VersionRail releases={releases} />
      <ol className="relative flex flex-col gap-14">
        {/* Timeline spine */}
        <span
          className="pointer-events-none absolute bottom-0 left-[7px] top-3 w-px bg-gradient-to-b from-primary/60 via-white/10 to-transparent"
          aria-hidden="true"
        />
        {releases.map((release, index) => (
          <ReleaseEntry key={release.tag} release={release} isLatest={index === 0} />
        ))}
      </ol>
    </section>
  );
}

function VersionRail({ releases }: { releases: AppReleaseNote[] }) {
  return (
    <aside className="hidden lg:block">
      <nav className="sticky top-28" aria-label="Versions">
        <p className="mb-4 font-mono text-[11px] uppercase tracking-[0.2em] text-on-surface-variant/60">
          Versions
        </p>
        <ul className="flex flex-col gap-0.5 border-l border-white/8">
          {releases.map((release, index) => (
            <li key={release.tag}>
              <a
                href={`#${versionAnchor(release)}`}
                className="-ml-px flex items-baseline justify-between gap-3 border-l border-transparent py-1.5 pl-4 text-sm text-on-surface-variant transition-colors hover:border-primary hover:text-on-surface"
              >
                <span className="font-medium">{versionAnchor(release)}</span>
                {index === 0 && (
                  <span className="font-mono text-[10px] uppercase tracking-widest text-primary">
                    Latest
                  </span>
                )}
              </a>
            </li>
          ))}
        </ul>
      </nav>
    </aside>
  );
}

function ReleaseEntry({
  release,
  isLatest,
}: {
  release: AppReleaseNote;
  isLatest: boolean;
}) {
  const dateLabel = formatPubDate(release.pubDate);
  const sizeLabel = formatSize(release.enclosureSize);
  const tag = versionAnchor(release);

  return (
    <li id={tag} className="relative scroll-mt-28 pl-8 md:pl-10">
      <span
        className={`absolute left-0 top-2.5 h-[15px] w-[15px] rounded-full border-2 ${
          isLatest
            ? "border-primary bg-primary shadow-[0_0_0_5px_rgba(77,245,199,0.15)]"
            : "border-white/25 bg-background"
        }`}
        aria-hidden="true"
      />

      <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <div className="flex flex-wrap items-center gap-2.5">
            <h2 className="font-display text-3xl font-semibold tracking-[-0.03em] md:text-4xl">
              <a href={`#${tag}`} className="hover:text-primary">
                {release.shortVersionString}
              </a>
            </h2>
            {isLatest && <Badge tone="primary">Latest</Badge>}
            {release.isPrerelease && <Badge tone="outline">Pre-release</Badge>}
            {release.version && <Badge tone="muted">Build {release.version}</Badge>}
          </div>
          <div className="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-on-surface-variant/80">
            {[
              dateLabel,
              release.minimumSystemVersion && `macOS ${release.minimumSystemVersion}+`,
              sizeLabel,
            ]
              .filter(Boolean)
              .map((item, i) => (
                <span key={i} className="flex items-center gap-3">
                  {i > 0 && <span className="h-1 w-1 rounded-full bg-white/20" aria-hidden="true" />}
                  {item}
                </span>
              ))}
          </div>
        </div>

        <div className="flex flex-wrap gap-2">
          {release.enclosureUrl && (
            <TrackedLink
              href={release.enclosureUrl}
              analyticsEventName="download_button_click"
              analyticsLabel={`Download ${tag}`}
              analyticsLocation="release_card"
              className="inline-flex items-center gap-2 rounded-full bg-on-surface px-4 py-2 text-sm font-semibold text-background transition-transform hover:scale-[1.03] active:scale-95"
            >
              <AppleIcon className="h-3.5 w-3.5" />
              Download
            </TrackedLink>
          )}
          {release.link && (
            <a
              href={release.link}
              target="_blank"
              rel="noreferrer"
              className="group inline-flex items-center gap-2 rounded-full border border-white/12 bg-white/[0.04] px-4 py-2 text-sm font-medium text-on-surface transition-colors hover:border-white/25 hover:bg-white/8"
            >
              View on GitHub
              <ArrowRightIcon className="h-3.5 w-3.5 transition-transform group-hover:translate-x-0.5" />
            </a>
          )}
        </div>
      </div>

      <div className="glass-panel mt-6 rounded-[24px] p-5 md:rounded-[28px] md:p-8">
        {release.releaseNotesMarkdown ? (
          <div className="release-notes max-w-none">
            <ReactMarkdown
              components={{
                a: ({ href, children }) => (
                  <a href={href} target="_blank" rel="noreferrer">
                    {children}
                  </a>
                ),
              }}
            >
              {stripVersionHeading(
                release.releaseNotesMarkdown,
                release.shortVersionString
              )}
            </ReactMarkdown>
          </div>
        ) : (
          <p className="text-on-surface-variant">
            No release notes provided for this build.
          </p>
        )}
      </div>
    </li>
  );
}

function Badge({
  tone,
  children,
}: {
  tone: "primary" | "outline" | "muted";
  children: React.ReactNode;
}) {
  const tones = {
    primary: "bg-primary text-on-primary",
    outline: "border border-primary/50 text-primary",
    muted: "border border-white/12 text-on-surface-variant",
  };
  return (
    <span
      className={`rounded-full px-2.5 py-0.5 font-mono text-[10px] font-semibold uppercase tracking-widest ${tones[tone]}`}
    >
      {children}
    </span>
  );
}
