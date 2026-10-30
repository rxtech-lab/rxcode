import Link from "next/link";
import { TrackedLink } from "../tracked-link";
import { Reveal } from "./motion";
import {
  AppleIcon,
  ArrowRightIcon,
  Eyebrow,
  ProductScreenshot,
} from "./ui";

/* ------------------------------------------------------------------ */
/*  Native desktop screenshots with fictional demo data            */
/* ------------------------------------------------------------------ */

const SHOTS = [
  { label: "Sprint board", file: "board", className: "md:col-span-2", aspect: "aspect-[16/10]" },
  { label: "Task details", file: "task-details", className: "", aspect: "aspect-[14/17] md:aspect-auto md:h-full" },
  { label: "Agent chat", file: "workspace", className: "", aspect: "aspect-[16/10]" },
  { label: "Branch briefing", file: "briefing", className: "", aspect: "aspect-[16/10]" },
  { label: "Schedules", file: "schedules", className: "", aspect: "aspect-[16/10]" },
];

export function Screenshots() {
  return (
    <section id="screenshots" className="relative py-32">
      <div className="mx-auto max-w-[var(--container-max)] px-6">
        <Reveal className="mb-14 flex flex-col justify-between gap-6 md:flex-row md:items-end">
          <div>
            <Eyebrow>Gallery</Eyebrow>
            <h2 className="mt-5 font-display text-4xl font-semibold tracking-[-0.03em] md:text-6xl">
              See it in action.
            </h2>
          </div>
          <p className="max-w-md text-on-surface-variant">
            Captured in the native macOS app. Every project, task, and
            conversation shown here uses fictional demo data.
          </p>
        </Reveal>
        <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
          {SHOTS.map((shot, i) => (
            <Reveal
              key={shot.label}
              delay={(i % 3) * 90}
              className={`overflow-hidden rounded-[28px] border border-white/8 ${shot.className}`}
            >
              <ProductScreenshot
                src={`/screenshot/demo/${shot.file}.webp`}
                alt={`${shot.label} in RxCode for macOS, using fictional demo data`}
                aspect={shot.aspect}
              />
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}

/* ------------------------------------------------------------------ */
/*  Closing CTA                                                        */
/* ------------------------------------------------------------------ */

export function ClosingCTA({ tag, dmgUrl }: { tag: string; dmgUrl: string }) {
  return (
    <section className="relative overflow-hidden py-40">
      <div className="aurora pointer-events-none absolute inset-x-0 top-1/2 h-[700px] -translate-y-1/2 opacity-70" />
      <Reveal className="relative mx-auto max-w-3xl px-6 text-center">
        <h2 className="font-display text-5xl font-semibold tracking-[-0.04em] md:text-7xl">
          From idea to shipped.
          <br />
          <span className="text-gradient-primary">RxCode has it all.</span>
        </h2>
        <p className="mx-auto mt-6 max-w-xl text-lg text-on-surface-variant">
          Free and open source. Download {tag} and put your agent team to work.
        </p>
        <div className="mt-10 flex flex-col justify-center gap-3 sm:flex-row">
          <TrackedLink
            href={dmgUrl}
            analyticsEventName="download_button_click"
            analyticsLabel={`Download RxCode ${tag}`}
            analyticsLocation="cta"
            className="btn-primary"
          >
            <AppleIcon className="h-4 w-4" />
            Download RxCode {tag}
          </TrackedLink>
          <Link href="/release" className="btn-secondary">
            Release notes
            <ArrowRightIcon className="h-4 w-4" />
          </Link>
        </div>
      </Reveal>
    </section>
  );
}
