"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { Brand } from "./brand";
import { AppleIcon, ArrowRightIcon, GITHUB_REPO_URL, GitHubIcon } from "./home/ui";
import { TrackedLink } from "./tracked-link";

/** Homepage sections, in scroll order. */
const SECTIONS = [
  { id: "sprint", label: "Sprint board" },
  { id: "routing", label: "Routing" },
  { id: "team", label: "Agent team" },
  { id: "mobile", label: "Mobile" },
  { id: "flowcy", label: "Flowcy" },
  { id: "agents", label: "Agents" },
];

const PAGES = [{ href: "/release", label: "Releases" }];

/**
 * Floating pill navbar shared by every page. On the homepage the section
 * links scroll in place and the current section is highlighted; elsewhere
 * they jump back to the homepage.
 */
export function SiteNav({ dmgUrl }: { dmgUrl?: string }) {
  const pathname = usePathname();
  const isHome = pathname === "/";
  const scrolled = useScrolled(24);
  const activeSection = useActiveSection(isHome);
  const [menuOpen, setMenuOpen] = useState(false);

  const sectionHref = (id: string) => (isHome ? `#${id}` : `/#${id}`);
  const isActive = (key: string) =>
    isHome ? activeSection === key : pathname.startsWith(key);

  return (
    <>
      <nav className="fixed inset-x-0 top-0 z-50 flex justify-center px-3 pt-3 sm:px-4">
        <div
          className={`flex h-14 w-full items-center justify-between gap-4 rounded-full pl-4 pr-2 transition-all duration-500 ${
            scrolled || !isHome
              ? "max-w-5xl border border-white/10 bg-background/75 shadow-[0_10px_40px_-10px_rgba(0,0,0,0.6)] backdrop-blur-xl"
              : "max-w-[var(--container-max)] border border-transparent"
          }`}
        >
          <Link
            href="/"
            aria-label="RxCode home"
            className="shrink-0 font-display text-lg font-semibold tracking-tight text-on-surface [&_img]:h-7 [&_img]:w-7"
          >
            <Brand />
          </Link>

          <div className="hidden items-center gap-0.5 rounded-full border border-white/8 bg-white/[0.03] p-1 text-sm lg:flex">
            {SECTIONS.map((section) => (
              <NavPill
                key={section.id}
                href={sectionHref(section.id)}
                active={isActive(section.id)}
              >
                {section.label}
              </NavPill>
            ))}
            <span className="mx-1 h-4 w-px bg-white/10" aria-hidden="true" />
            {PAGES.map((page) => (
              <NavPill key={page.href} href={page.href} active={isActive(page.href)}>
                {page.label}
              </NavPill>
            ))}
          </div>

          <div className="flex items-center gap-1.5">
            <a
              href={GITHUB_REPO_URL}
              target="_blank"
              rel="noreferrer"
              aria-label="RxCode on GitHub"
              className="hidden h-9 w-9 items-center justify-center rounded-full text-on-surface-variant transition-colors hover:bg-white/8 hover:text-on-surface sm:inline-flex"
            >
              <GitHubIcon className="h-[18px] w-[18px]" />
            </a>
            <DownloadButton dmgUrl={dmgUrl} location="top_nav" />
            <button
              type="button"
              onClick={() => setMenuOpen(true)}
              aria-label="Open menu"
              aria-expanded={menuOpen}
              className="inline-flex h-9 w-9 items-center justify-center rounded-full text-on-surface transition-colors hover:bg-white/8 lg:hidden"
            >
              <MenuIcon className="h-5 w-5" />
            </button>
          </div>
        </div>
      </nav>

      <MobileMenu
        open={menuOpen}
        onClose={() => setMenuOpen(false)}
        dmgUrl={dmgUrl}
        items={[
          ...SECTIONS.map((s) => ({
            href: sectionHref(s.id),
            label: s.label,
            active: isActive(s.id),
          })),
          ...PAGES.map((p) => ({ ...p, active: isActive(p.href) })),
        ]}
      />
    </>
  );
}

function NavPill({
  href,
  active,
  children,
}: {
  href: string;
  active: boolean;
  children: React.ReactNode;
}) {
  return (
    <Link
      href={href}
      aria-current={active ? "page" : undefined}
      className={`rounded-full px-3 py-1.5 transition-colors duration-300 ${
        active
          ? "bg-white/10 text-on-surface shadow-[inset_0_1px_0_rgba(255,255,255,0.08)]"
          : "text-on-surface-variant hover:bg-white/5 hover:text-on-surface"
      }`}
    >
      {children}
    </Link>
  );
}

function DownloadButton({
  dmgUrl,
  location,
  className = "",
}: {
  dmgUrl?: string;
  location: string;
  className?: string;
}) {
  const classes = `inline-flex items-center justify-center gap-2 rounded-full bg-on-surface px-4 py-2 text-sm font-semibold text-background transition-transform hover:scale-[1.03] active:scale-95 ${className}`;

  // Pages without release info send visitors to the release list instead.
  if (!dmgUrl) {
    return (
      <Link href="/release" className={classes}>
        <AppleIcon className="h-3.5 w-3.5" />
        Download
      </Link>
    );
  }

  return (
    <TrackedLink
      href={dmgUrl}
      analyticsEventName="download_button_click"
      analyticsLabel="Download for macOS"
      analyticsLocation={location}
      className={classes}
    >
      <AppleIcon className="h-3.5 w-3.5" />
      Download
    </TrackedLink>
  );
}

/** Full-screen dialog menu for small screens. */
function MobileMenu({
  open,
  onClose,
  dmgUrl,
  items,
}: {
  open: boolean;
  onClose: () => void;
  dmgUrl?: string;
  items: { href: string; label: string; active: boolean }[];
}) {
  const dialogRef = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (open && !dialog.open) dialog.showModal();
    if (!open && dialog.open) dialog.close();
  }, [open]);

  return (
    <dialog
      ref={dialogRef}
      onClose={onClose}
      onClick={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
      className="fixed inset-0 m-0 h-full max-h-none w-full max-w-none bg-transparent p-3 backdrop:bg-background/70 backdrop:backdrop-blur-md lg:hidden"
    >
      <div className="fade-in glass-panel flex flex-col rounded-[28px] bg-surface/90 p-3">
        <div className="flex h-12 items-center justify-between pl-2">
          <Link
            href="/"
            onClick={onClose}
            className="font-display text-lg font-semibold tracking-tight text-on-surface [&_img]:h-7 [&_img]:w-7"
          >
            <Brand />
          </Link>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close menu"
            className="inline-flex h-10 w-10 items-center justify-center rounded-full text-on-surface transition-colors hover:bg-white/8"
          >
            <CloseIcon className="h-5 w-5" />
          </button>
        </div>
        <ul className="mt-2 flex flex-col gap-0.5">
          {items.map((item) => (
            <li key={item.href}>
              <Link
                href={item.href}
                onClick={onClose}
                aria-current={item.active ? "page" : undefined}
                className={`flex items-center justify-between rounded-2xl px-4 py-3 text-base transition-colors ${
                  item.active
                    ? "bg-white/10 text-on-surface"
                    : "text-on-surface-variant hover:bg-white/5 hover:text-on-surface"
                }`}
              >
                {item.label}
                <ArrowRightIcon className="h-4 w-4 opacity-50" />
              </Link>
            </li>
          ))}
        </ul>
        <div className="mt-3 flex gap-2 border-t border-white/8 pt-3">
          <a
            href={GITHUB_REPO_URL}
            target="_blank"
            rel="noreferrer"
            className="inline-flex flex-1 items-center justify-center gap-2 rounded-full border border-white/12 bg-white/5 px-4 py-2.5 text-sm font-medium text-on-surface"
          >
            <GitHubIcon className="h-4 w-4" />
            GitHub
          </a>
          <DownloadButton dmgUrl={dmgUrl} location="mobile_menu" className="flex-1 py-2.5" />
        </div>
      </div>
    </dialog>
  );
}

function useScrolled(threshold: number) {
  const [scrolled, setScrolled] = useState(false);
  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > threshold);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, [threshold]);
  return scrolled;
}

/** The homepage section that spans the middle of the viewport. */
function useActiveSection(enabled: boolean) {
  const [active, setActive] = useState<string | null>(null);

  useEffect(() => {
    if (!enabled) return;
    let frame = 0;
    const measure = () => {
      frame = 0;
      const mid = window.innerHeight / 2;
      let current: string | null = null;
      for (const { id } of SECTIONS) {
        const rect = document.getElementById(id)?.getBoundingClientRect();
        if (rect && rect.top <= mid && rect.bottom > mid) current = id;
      }
      setActive(current);
    };
    const onScroll = () => {
      if (!frame) frame = requestAnimationFrame(measure);
    };
    measure();
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onScroll);
    return () => {
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", onScroll);
      if (frame) cancelAnimationFrame(frame);
    };
  }, [enabled]);

  return enabled ? active : null;
}

type IconProps = { className?: string };

function MenuIcon({ className = "" }: IconProps) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" aria-hidden="true">
      <path d="M4 8h16M4 16h16" />
    </svg>
  );
}

function CloseIcon({ className = "" }: IconProps) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" aria-hidden="true">
      <path d="M6 6l12 12M18 6 6 18" />
    </svg>
  );
}
