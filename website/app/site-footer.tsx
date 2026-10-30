import Link from "next/link";
import { Brand } from "./brand";
import { FLOWCY_URL, GITHUB_REPO_URL, GitHubIcon } from "./home/ui";

const SUPPORT_EMAIL = "support@rxlab.app";

const LINKS = [
  { href: "/release", label: "Release Notes" },
  { href: "/privacy", label: "Privacy" },
  { href: "/user-agreement", label: "User Agreement" },
];

export function SiteFooter() {
  const year = new Date().getFullYear();
  return (
    <footer className="mt-auto border-t border-white/8">
      <div className="mx-auto flex max-w-[var(--container-max)] flex-col items-start justify-between gap-6 px-6 py-12 md:flex-row md:items-center">
        <div className="flex flex-col gap-1.5">
          <Link href="/" className="font-display text-lg font-semibold text-on-surface [&_img]:h-7 [&_img]:w-7">
            <Brand />
          </Link>
          <span className="text-xs text-on-surface-variant/60">
            © {year} RxCode. All rights reserved.
          </span>
          <a
            href={`mailto:${SUPPORT_EMAIL}`}
            className="text-xs text-on-surface-variant transition-colors hover:text-primary"
          >
            {SUPPORT_EMAIL}
          </a>
        </div>
        <nav className="flex flex-wrap items-center gap-6 text-sm">
          {LINKS.map((link) => (
            <Link key={link.href} href={link.href} className="text-on-surface-variant transition-colors hover:text-on-surface">
              {link.label}
            </Link>
          ))}
          <a href={`mailto:${SUPPORT_EMAIL}`} className="text-on-surface-variant transition-colors hover:text-on-surface">
            Support
          </a>
          <a href={FLOWCY_URL} target="_blank" rel="noreferrer" className="text-on-surface-variant transition-colors hover:text-on-surface">
            Flowcy
          </a>
          <a href={GITHUB_REPO_URL} target="_blank" rel="noreferrer" aria-label="GitHub" className="text-on-surface-variant transition-colors hover:text-on-surface">
            <GitHubIcon className="h-4 w-4" />
          </a>
        </nav>
      </div>
    </footer>
  );
}
