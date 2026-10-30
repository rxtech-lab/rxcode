"use client";

import {
  clamp,
  range,
  Reveal,
  ScrollScene,
  usePrefersReducedMotion,
  useSceneProgress,
} from "./motion";
import { Eyebrow, ProductScreenshot } from "./ui";

/* ------------------------------------------------------------------ */
/*  Native desktop screenshots with fictional demo data            */
/* ------------------------------------------------------------------ */

const SHOTS = [
  { label: "Sprint board", file: "board", caption: "Plan sprints and hand tasks to agents.", grid: "md:col-span-2", aspect: "aspect-[16/10]" },
  { label: "Task details", file: "task-details", caption: "Every task keeps its plan, thread and review.", grid: "", aspect: "aspect-[14/17] md:aspect-auto md:h-full" },
  { label: "Agent chat", file: "workspace", caption: "Chat, approve and steer agents side by side.", grid: "", aspect: "aspect-[16/10]" },
  { label: "Branch briefing", file: "briefing", caption: "A written briefing for every branch you ship.", grid: "", aspect: "aspect-[16/10]" },
  { label: "Schedules", file: "schedules", caption: "Recurring prompts that run while you're away.", grid: "", aspect: "aspect-[16/10]" },
];

const altText = (label: string) =>
  `${label} in RxCode for macOS, using fictional demo data`;

export function Screenshots() {
  const reduced = usePrefersReducedMotion();
  if (reduced) return <ScreenshotGrid />;
  return (
    <ScrollScene id="screenshots" height={`${SHOTS.length * 100 + 60}vh`}>
      <ShowcaseStage />
    </ScrollScene>
  );
}

/**
 * Pinned deck: each capture slides up from below and settles on top of the
 * previous one, which tilts back and dims into the stack.
 */
function ShowcaseStage() {
  const p = useSceneProgress();
  const pos = range(p, 0.08, 0.92) * (SHOTS.length - 1);
  const active = Math.round(pos);
  const intro = range(p, 0, 0.08);

  return (
    <div className="mx-auto flex h-full max-w-[var(--container-max)] flex-col px-6 pb-8 pt-24">
      <div className="relative z-20 flex flex-col justify-between gap-4 md:flex-row md:items-end">
        <div>
          <Eyebrow>Gallery</Eyebrow>
          <h2 className="mt-5 font-display text-4xl font-semibold tracking-[-0.03em] md:text-6xl">
            See it in action.
          </h2>
        </div>
        <div className="max-w-md md:text-right">
          <p key={active} className="fade-in font-semibold text-on-surface">
            {SHOTS[active].label}
            <span className="font-normal text-on-surface-variant"> — {SHOTS[active].caption}</span>
          </p>
          <p className="mt-1 text-xs text-on-surface-variant/70">
            Captured in the native macOS app with fictional demo data.
          </p>
        </div>
      </div>

      <div className="relative mt-8 min-h-0 flex-1 [perspective:1600px]">
        {SHOTS.map((shot, i) => {
          const d = i - pos;
          // Upcoming cards wait below the stage; the first one rises in with the intro.
          const enter = i === 0 ? 1 - intro : clamp(d);
          const depth = clamp(-d, 0, 2);
          return (
            <div
              key={shot.file}
              className="absolute inset-0 flex items-center justify-center will-change-transform"
              style={{
                zIndex: i,
                transform: `translateY(${enter * 115 - depth * 2.5}%) rotateX(${enter * 10 + depth * 4}deg) scale(${1 - depth * 0.05})`,
                transformOrigin: "50% 0%",
                opacity: d >= 0.98 ? 0 : 1 - range(-d, 1, 2),
              }}
            >
              <div
                className="w-full max-w-[min(100%,calc((100vh-300px)*1.6))] overflow-hidden rounded-[28px] border border-white/10 shadow-[0_40px_120px_-30px_rgba(0,0,0,0.8)]"
                style={{ filter: depth > 0 ? `brightness(${1 - depth * 0.25})` : undefined }}
              >
                <ProductScreenshot src={`/screenshot/demo/${shot.file}.webp`} alt={altText(shot.label)} />
              </div>
            </div>
          );
        })}
      </div>

      <div className="mt-6 flex items-center justify-center gap-2">
        {SHOTS.map((shot, i) => {
          const fill = clamp(pos - i + 1);
          return (
            <span
              key={shot.file}
              aria-hidden="true"
              className="h-1 w-10 overflow-hidden rounded-full bg-white/10"
            >
              <span
                className="block h-full rounded-full bg-primary"
                style={{ width: `${(i === 0 ? intro : fill) * 100}%` }}
              />
            </span>
          );
        })}
      </div>
    </div>
  );
}

/** Static gallery for visitors who prefer reduced motion. */
function ScreenshotGrid() {
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
              className={`overflow-hidden rounded-[28px] border border-white/8 ${shot.grid}`}
            >
              <ProductScreenshot
                src={`/screenshot/demo/${shot.file}.webp`}
                alt={altText(shot.label)}
                aspect={shot.aspect}
              />
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}
