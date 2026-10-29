"use client";

import { Brand } from "../brand";

import Link from "next/link";
import { useEffect, useState } from "react";
import { TrackedLink } from "../tracked-link";
import { GITHUB_REPO_URL } from "./ui";

const LINKS = [
  { href: "#sprint", label: "Sprint board" },
  { href: "#routing", label: "Routing" },
  { href: "#team", label: "Agent team" },
  { href: "#mobile", label: "Mobile" },
  { href: "#flowcy", label: "Flowcy" },
  { href: "#agents", label: "Agents" },
];

export function TopNav({ dmgUrl }: { dmgUrl: string }) {
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 24);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <nav className="fixed inset-x-0 top-0 z-50 flex justify-center px-4 pt-3">
      <div
        className={`flex h-14 w-full items-center justify-between gap-6 rounded-full px-5 transition-all duration-500 ${
          scrolled
            ? "max-w-5xl border border-white/10 bg-background/70 shadow-[0_10px_40px_-10px_rgba(0,0,0,0.6)] backdrop-blur-xl"
            : "max-w-[var(--container-max)] border border-transparent"
        }`}
      >
        <Link href="/" className="font-display text-lg font-semibold tracking-tight text-on-surface">
          <Brand />
        </Link>
        <div className="hidden items-center gap-6 text-sm lg:flex">
          {LINKS.map((link) => (
            <a key={link.href} href={link.href} className="text-on-surface-variant transition-colors hover:text-on-surface">
              {link.label}
            </a>
          ))}
          <Link href="/release" className="text-on-surface-variant transition-colors hover:text-on-surface">
            Releases
          </Link>
          <a href={GITHUB_REPO_URL} target="_blank" rel="noreferrer" className="text-on-surface-variant transition-colors hover:text-on-surface">
            GitHub
          </a>
        </div>
        <TrackedLink
          href={dmgUrl}
          analyticsEventName="download_button_click"
          analyticsLabel="Download for macOS"
          analyticsLocation="top_nav"
          className="rounded-full bg-on-surface px-4 py-1.5 text-sm font-medium text-background transition-transform hover:scale-[1.03] active:scale-95"
        >
          Download
        </TrackedLink>
      </div>
    </nav>
  );
}
