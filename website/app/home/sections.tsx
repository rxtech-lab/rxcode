import Link from "next/link";
import { TrackedLink } from "../tracked-link";
import { Reveal } from "./motion";
import { AppleIcon, ArrowRightIcon } from "./ui";

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
