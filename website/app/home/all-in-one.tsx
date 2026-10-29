"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import { range, ScrollScene, useSceneProgress } from "./motion";
import { CalendarIcon, ChatIcon, Eyebrow, NewspaperIcon } from "./ui";

export function AllInOne() {
  return (
    <ScrollScene id="everyday" height="330vh">
      <AllInOneStage />
    </ScrollScene>
  );
}

function AllInOneStage() {
  const p = useSceneProgress();
  const slide = range(p, 0.08, 0.92);
  const active = slide < 0.3 ? 0 : slide < 0.7 ? 1 : 2;
  const trackRef = useRef<HTMLDivElement>(null);
  const [maxShift, setMaxShift] = useState(0);

  // How far the track must travel so its last panel ends at the viewport edge.
  useEffect(() => {
    const track = trackRef.current;
    if (!track) return;
    const measure = () =>
      setMaxShift(Math.max(0, track.scrollWidth - window.innerWidth));
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(track);
    window.addEventListener("resize", measure);
    return () => {
      observer.disconnect();
      window.removeEventListener("resize", measure);
    };
  }, []);

  return (
    <div className="flex h-full flex-col justify-center pb-10 pt-20">
      <div className="mx-auto w-full max-w-[var(--container-max)] px-6">
        <Eyebrow>Schedule · Briefing · Chat</Eyebrow>
        <div className="mt-5 flex flex-col justify-between gap-6 md:flex-row md:items-end">
          <h2 className="max-w-3xl font-display text-3xl font-semibold tracking-[-0.03em] md:text-6xl">
            From coding to living.
            <br />
            <span className="text-on-surface-variant/50">All in one place.</span>
          </h2>
          <div className="flex gap-2">
            {["Schedule", "Briefing", "Chat"].map((label, i) => (
              <span
                key={label}
                className={`rounded-full px-4 py-1.5 text-sm transition-all duration-500 ${
                  i === active
                    ? "bg-on-surface text-background"
                    : "bg-white/5 text-on-surface-variant"
                }`}
              >
                {label}
              </span>
            ))}
          </div>
        </div>
      </div>

      <div className="mt-10 overflow-hidden">
        <div
          ref={trackRef}
          className="flex w-max gap-6 px-6 will-change-transform md:px-[max(1.5rem,calc((100vw-var(--container-max))/2+1.5rem))]"
          style={{ transform: `translate3d(${-slide * maxShift}px, 0, 0)` }}
        >
          <Panel
            icon={<CalendarIcon className="h-5 w-5" />}
            title="Schedules"
            body="Turn any prompt into a recurring task. Dependency bumps on Monday, issue triage every two hours, a morning summary before coffee."
          >
            <ScheduleMock />
          </Panel>
          <Panel
            icon={<NewspaperIcon className="h-5 w-5" />}
            title="Daily briefings"
            body="Every day, RxCode writes up what your agents shipped, fixed and decided — per project, ready on your phone when you wake up."
          >
            <BriefingMock />
          </Panel>
          <Panel
            icon={<ChatIcon className="h-5 w-5" />}
            title="Chat with everything"
            body="Ask about your board, your briefings or your codebase. Agents can talk to each other across projects, too."
          >
            <ChatMock />
          </Panel>
        </div>
      </div>
    </div>
  );
}

function Panel({
  icon,
  title,
  body,
  children,
}: {
  icon: ReactNode;
  title: string;
  body: string;
  children: ReactNode;
}) {
  return (
    <article className="glass-panel grid w-[84vw] shrink-0 grid-cols-1 gap-6 rounded-[32px] p-6 md:w-[min(64vw,900px)] md:grid-cols-[0.9fr_1.1fr] md:p-8">
      <div className="flex flex-col">
        <span className="flex h-11 w-11 items-center justify-center rounded-2xl bg-primary/15 text-primary">
          {icon}
        </span>
        <h3 className="mt-5 font-display text-2xl font-semibold tracking-tight md:text-3xl">
          {title}
        </h3>
        <p className="mt-3 leading-relaxed text-on-surface-variant">{body}</p>
      </div>
      <div className="min-h-[220px] rounded-3xl border border-white/8 bg-black/30 p-4 md:min-h-[300px]">
        {children}
      </div>
    </article>
  );
}

const SCHEDULES = [
  { time: "08:00", label: "Morning briefing", cadence: "Every day" },
  { time: "09:30", label: "Dependency updates", cadence: "Mondays" },
  { time: "every 2h", label: "Triage new issues", cadence: "Weekdays" },
  { time: "18:00", label: "Release notes draft", cadence: "Fridays" },
];

function ScheduleMock() {
  return (
    <ul className="flex flex-col gap-2">
      {SCHEDULES.map((item, i) => (
        <li
          key={item.label}
          className="flex items-center gap-3 rounded-2xl bg-white/[0.04] px-3 py-2.5"
        >
          <span className="w-16 font-mono text-xs text-primary">{item.time}</span>
          <span className="flex-1 truncate text-sm text-on-surface">{item.label}</span>
          <span className="hidden text-xs text-on-surface-variant/70 sm:inline">
            {item.cadence}
          </span>
          <span
            className={`h-5 w-9 rounded-full p-0.5 ${i === 2 ? "bg-white/15" : "bg-primary"}`}
          >
            <span
              className={`block h-4 w-4 rounded-full bg-white transition-transform ${
                i === 2 ? "" : "translate-x-4"
              }`}
            />
          </span>
        </li>
      ))}
    </ul>
  );
}

function BriefingMock() {
  return (
    <div className="flex h-full flex-col gap-3">
      <div className="flex items-center justify-between">
        <span className="text-sm font-semibold text-on-surface">Today, 8:00</span>
        <span className="rounded-full bg-emerald-400/10 px-2 py-0.5 text-[10px] text-emerald-300">
          3 projects
        </span>
      </div>
      {[
        { label: "Features", items: ["Passkey sign-in shipped", "Widgets for weekly review"] },
        { label: "Fixes", items: ["Crash on resume after sleep"] },
        { label: "Decisions", items: ["Move sync to background queue"] },
      ].map((group) => (
        <div key={group.label}>
          <p className="font-mono text-[10px] uppercase tracking-[0.2em] text-primary">
            {group.label}
          </p>
          <ul className="mt-1.5 flex flex-col gap-1">
            {group.items.map((item) => (
              <li key={item} className="flex gap-2 text-sm text-on-surface-variant">
                <span className="text-primary">›</span>
                {item}
              </li>
            ))}
          </ul>
        </div>
      ))}
    </div>
  );
}

function ChatMock() {
  return (
    <div className="flex h-full flex-col justify-end gap-2.5 text-sm">
      <p className="ml-auto max-w-[80%] rounded-2xl rounded-br-md bg-primary px-3.5 py-2 text-on-primary">
        What&apos;s blocking the 2.0 release?
      </p>
      <p className="max-w-[85%] rounded-2xl rounded-bl-md bg-white/8 px-3.5 py-2 text-on-surface">
        Two cards in Review: billing webhooks and offline sync. Both have
        passing CI — want me to merge them?
      </p>
      <p className="ml-auto max-w-[80%] rounded-2xl rounded-br-md bg-primary px-3.5 py-2 text-on-primary">
        Yes, and add it to tomorrow&apos;s briefing.
      </p>
      <span className="flex items-center gap-1 px-1">
        <span className="typing-dot" />
        <span className="typing-dot" style={{ animationDelay: "150ms" }} />
        <span className="typing-dot" style={{ animationDelay: "300ms" }} />
      </span>
    </div>
  );
}
