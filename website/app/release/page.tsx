import type { Metadata } from "next";
import Link from "next/link";
import ReactMarkdown from "react-markdown";
import {
  getAppReleaseNotes,
  formatPubDate,
  formatSize,
  getLatestRelease,
  type AppReleaseNote,
} from "../lib/release";
import { TrackedLink } from "../tracked-link";

const GITHUB_REPO_URL = "https://github.com/rxtech-lab/rxcode";

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
      <TopNav />
      <main className="pt-24 pb-20">
        <Header releases={releases} />
        <ReleaseList releases={releases} latestDmg={latest.dmgUrl} />
      </main>
      <Footer />
    </>
  );
}

function TopNav() {
  return (
    <nav className="fixed top-0 inset-x-0 z-50 border-b border-surface-variant bg-background/80 backdrop-blur">
      <div className="max-w-[var(--container-max)] mx-auto px-6 h-16 flex items-center justify-between">
        <div className="flex items-center gap-10">
          <Link
            href="/"
            className="font-display text-2xl font-bold text-primary tracking-tight"
          >
            RxCode
          </Link>
          <div className="hidden md:flex gap-7 text-sm">
            <Link
              href="/#features"
              className="text-on-surface-variant hover:text-primary transition-colors"
            >
              Features
            </Link>
            <Link
              href="/#agents"
              className="text-on-surface-variant hover:text-primary transition-colors"
            >
              Supported Agents
            </Link>
            <Link
              href="/release"
              className="text-primary transition-colors"
              aria-current="page"
            >
              Release Notes
            </Link>
            <a
              href={GITHUB_REPO_URL}
              target="_blank"
              rel="noreferrer"
              className="text-on-surface-variant hover:text-primary transition-colors"
            >
              GitHub
            </a>
          </div>
        </div>
        <Link
          href="/"
          className="hidden sm:inline-flex items-center gap-2 border border-outline text-on-surface px-4 py-2 font-mono text-[11px] tracking-widest uppercase hover:border-primary hover:text-primary transition-colors"
        >
          ← Back home
        </Link>
      </div>
    </nav>
  );
}

function Header({ releases }: { releases: AppReleaseNote[] }) {
  return (
    <section className="relative overflow-hidden">
      <div className="absolute inset-0 bg-grid opacity-60 [mask-image:radial-gradient(ellipse_at_top,black_30%,transparent_70%)]" />
      <div className="relative max-w-[var(--container-max)] mx-auto px-6 pt-12 pb-12">
        <span className="inline-flex items-center gap-2 px-3 py-1.5 border border-primary text-primary font-mono text-[11px] tracking-widest uppercase bg-primary/10">
          <span className="inline-block w-1.5 h-1.5 bg-primary rounded-full" />
          Latest {releases.length}{" "}
          {releases.length === 1 ? "release" : "releases"}
        </span>
        <h1 className="mt-6 font-display text-4xl md:text-6xl font-bold tracking-tight leading-[1.05]">
          Release <span className="text-gradient-primary">Notes</span>
        </h1>
        <p className="mt-5 max-w-2xl text-lg text-on-surface-variant leading-relaxed">
          The latest updates for the RxCode macOS app, including new features,
          improvements, and fixes.
        </p>
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
      <section className="max-w-[var(--container-max)] mx-auto px-6 pt-4">
        <div className="bg-surface border border-surface-variant p-8 text-center text-on-surface-variant">
          <p>Release notes are temporarily unavailable.</p>
          <TrackedLink
            href={latestDmg}
            analyticsEventName="download_button_click"
            analyticsLabel="Download latest build"
            analyticsLocation="release_empty_state"
            className="mt-6 inline-flex items-center justify-center gap-2 border border-outline px-6 py-3 font-mono text-xs tracking-widest uppercase hover:border-primary hover:text-primary transition-colors"
          >
            Download latest build
          </TrackedLink>
        </div>
      </section>
    );
  }

  return (
    <section className="max-w-[var(--container-max)] mx-auto px-6 pt-4">
      <div className="flex flex-col gap-6">
        {releases.map((release, index) => (
          <ReleaseCard
            key={release.tag}
            release={release}
            isLatest={index === 0}
          />
        ))}
      </div>
    </section>
  );
}

function ReleaseCard({
  release,
  isLatest,
}: {
  release: AppReleaseNote;
  isLatest: boolean;
}) {
  const dateLabel = formatPubDate(release.pubDate);
  const sizeLabel = formatSize(release.enclosureSize);
  const tag = `v${release.shortVersionString}`;

  return (
    <article
      id={tag}
      className="scroll-mt-24 bg-surface border border-surface-variant hover:border-primary/60 transition-colors"
    >
      <header className="flex flex-col md:flex-row md:items-center md:justify-between gap-4 p-7 border-b border-surface-variant">
        <div className="flex flex-col gap-2">
          <div className="flex items-center gap-3">
            <h2 className="font-display text-3xl md:text-4xl font-semibold tracking-tight">
              {release.shortVersionString}
            </h2>
            {isLatest && (
              <span className="font-mono text-[10px] tracking-widest uppercase bg-primary text-on-primary px-2 py-1">
                Latest
              </span>
            )}
            {release.isPrerelease && (
              <span className="font-mono text-[10px] tracking-widest uppercase text-primary border border-primary px-2 py-1">
                Pre-release
              </span>
            )}
            {release.version && (
              <span className="font-mono text-[10px] tracking-widest uppercase text-on-surface-variant border border-surface-variant px-2 py-1">
                Build {release.version}
              </span>
            )}
          </div>
          <div className="flex flex-wrap items-center gap-x-4 gap-y-1 font-mono text-[11px] tracking-widest uppercase text-on-surface-variant/70">
            {dateLabel && <span>{dateLabel}</span>}
            {release.minimumSystemVersion && (
              <span>macOS {release.minimumSystemVersion}+</span>
            )}
            {sizeLabel && <span>{sizeLabel}</span>}
          </div>
        </div>
        <div className="flex flex-wrap gap-3">
          {release.enclosureUrl && (
            <TrackedLink
              href={release.enclosureUrl}
              analyticsEventName="download_button_click"
              analyticsLabel={`Download ${tag}`}
              analyticsLocation="release_card"
              className="inline-flex items-center justify-center gap-2 bg-primary text-on-primary px-5 py-2.5 font-mono text-[11px] tracking-widest uppercase border border-primary hover:bg-transparent hover:text-primary transition-colors active:scale-95"
            >
              Download .dmg
            </TrackedLink>
          )}
          {release.link && (
            <a
              href={release.link}
              target="_blank"
              rel="noreferrer"
              className="inline-flex items-center justify-center gap-2 border border-outline text-on-surface px-5 py-2.5 font-mono text-[11px] tracking-widest uppercase hover:border-primary hover:text-primary transition-colors active:scale-95"
            >
              GitHub
            </a>
          )}
        </div>
      </header>

      <div className="p-7">
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
              {release.releaseNotesMarkdown}
            </ReactMarkdown>
          </div>
        ) : (
          <p className="text-on-surface-variant">
            No release notes provided for this build.
          </p>
        )}
      </div>
    </article>
  );
}

function Footer() {
  const year = new Date().getFullYear();
  return (
    <footer className="w-full bg-surface border-t border-surface-variant">
      <div className="max-w-[var(--container-max)] mx-auto px-6 py-12 flex flex-col md:flex-row justify-between items-start md:items-center gap-6">
        <div className="flex flex-col gap-1">
          <Link
            href="/"
            className="font-display text-2xl font-bold text-primary tracking-tight"
          >
            RxCode
          </Link>
          <span className="text-sm text-on-surface-variant/70">
            © {year} RxCode. All rights reserved.
          </span>
        </div>
        <nav className="flex flex-wrap gap-6 text-sm">
          <Link
            href="/privacy"
            className="text-on-surface-variant hover:text-primary transition-colors"
          >
            Privacy
          </Link>
          <Link
            href="/user-agreement"
            className="text-on-surface-variant hover:text-primary transition-colors"
          >
            User Agreement
          </Link>
          <a
            href={GITHUB_REPO_URL}
            target="_blank"
            rel="noreferrer"
            className="text-on-surface-variant hover:text-primary transition-colors"
          >
            GitHub
          </a>
          <Link
            href="/release"
            className="text-on-surface-variant hover:text-primary transition-colors"
          >
            Release Notes
          </Link>
          <Link
            href="/#features"
            className="text-on-surface-variant hover:text-primary transition-colors"
          >
            Features
          </Link>
        </nav>
      </div>
    </footer>
  );
}
