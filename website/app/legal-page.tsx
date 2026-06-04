import Link from "next/link";
import type { ReactNode } from "react";

const GITHUB_REPO_URL = "https://github.com/rxtech-lab/rxcode";

type LegalPageProps = {
  eyebrow: string;
  title: string;
  description: string;
  children: ReactNode;
};

export function LegalPage({
  eyebrow,
  title,
  description,
  children,
}: LegalPageProps) {
  return (
    <>
      <TopNav />
      <main className="pt-24 pb-20">
        <section className="relative overflow-hidden">
          <div className="absolute inset-0 bg-grid opacity-60 [mask-image:radial-gradient(ellipse_at_top,black_30%,transparent_70%)]" />
          <div className="relative max-w-[var(--container-max)] mx-auto px-6 pt-12 pb-12">
            <span className="inline-flex items-center gap-2 px-3 py-1.5 border border-primary text-primary font-mono text-[11px] tracking-widest uppercase bg-primary/10">
              <span className="inline-block w-1.5 h-1.5 bg-primary rounded-full" />
              {eyebrow}
            </span>
            <h1 className="mt-6 font-display text-4xl md:text-6xl font-bold tracking-tight leading-[1.05]">
              {title}
            </h1>
            <p className="mt-5 max-w-2xl text-lg text-on-surface-variant leading-relaxed">
              {description}
            </p>
          </div>
        </section>
        <section className="max-w-[var(--container-max)] mx-auto px-6 pt-4">
          <article className="legal-content bg-surface border border-surface-variant p-7 md:p-9">
            {children}
          </article>
        </section>
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
              href="/#mobile"
              className="text-on-surface-variant hover:text-primary transition-colors"
            >
              Mobile
            </Link>
            <Link
              href="/release"
              className="text-on-surface-variant hover:text-primary transition-colors"
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
          Back home
        </Link>
      </div>
    </nav>
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
          <Link
            href="/release"
            className="text-on-surface-variant hover:text-primary transition-colors"
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
        </nav>
      </div>
    </footer>
  );
}
