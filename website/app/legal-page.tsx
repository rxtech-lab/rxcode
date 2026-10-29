import type { ReactNode } from "react";
import { Eyebrow } from "./home/ui";
import { SiteFooter } from "./site-footer";
import { SiteNav } from "./site-nav";

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
      <SiteNav />
      <main className="flex-1 pb-28">
        <section className="relative overflow-hidden pt-36 pb-14 md:pt-44">
          <div className="aurora pointer-events-none absolute inset-x-0 -top-48 h-[600px] opacity-50" />
          <div className="pointer-events-none absolute inset-0 bg-dots opacity-25 [mask-image:radial-gradient(ellipse_at_top,black_20%,transparent_65%)]" />
          <div className="relative mx-auto max-w-[var(--container-max)] px-6">
            <Eyebrow>{eyebrow}</Eyebrow>
            <h1 className="mt-6 font-display text-5xl font-semibold leading-[1.02] tracking-[-0.04em] md:text-7xl">
              {title}
            </h1>
            <p className="mt-6 max-w-2xl text-lg leading-relaxed text-on-surface-variant">
              {description}
            </p>
          </div>
        </section>
        <section className="mx-auto max-w-[var(--container-max)] px-6">
          <article className="legal-content glass-panel rounded-[28px] p-7 md:p-10">
            {children}
          </article>
        </section>
      </main>
      <SiteFooter />
    </>
  );
}
