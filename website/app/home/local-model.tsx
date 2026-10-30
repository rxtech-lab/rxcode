"use client";

import {
  easeOut,
  range,
  ScrollScene,
  useLeaveProgress,
  useSceneProgress,
} from "./motion";
import { CheckIcon, Eyebrow, LaptopIcon, LockIcon, SparkIcon } from "./ui";

const SOURCES = [
  { label: "Chat threads", count: 1284 },
  { label: "Merged diffs", count: 3902 },
  { label: "Task reviews", count: 612 },
  { label: "Style rules", count: 48 },
];

const STEPS = [
  {
    title: "Collect locally",
    body: "Threads, diffs and task reviews you already have become training data, right on your Mac.",
  },
  {
    title: "Fine-tune on device",
    body: "A lightweight adapter trains on Apple silicon. Nothing is uploaded, nothing leaves the machine.",
  },
  {
    title: "Process tasks offline",
    body: "Your tuned model picks up routine tasks in your style, with zero API cost and no network.",
  },
];

const LOCAL_TASKS = [
  "Triage new issue #318",
  "Write commit message",
  "Label pull request #482",
  "Summarize CI failure log",
];

// Training loss, sampled across 0…1 of the run (1 = top of the chart).
const LOSS = [0.95, 0.78, 0.64, 0.52, 0.44, 0.37, 0.32, 0.27, 0.24, 0.21, 0.19, 0.17, 0.16];
const LOSS_PATH = LOSS.map(
  (v, i) => `${i === 0 ? "M" : "L"}${(i / (LOSS.length - 1)) * 100},${4 + (1 - v) * 52}`
).join(" ");

export function LocalModel() {
  return (
    <ScrollScene id="finetune" height="320vh" clip={false}>
      <LocalModelStage />
    </ScrollScene>
  );
}

function LocalModelStage() {
  const p = useSceneProgress();
  const leave = useLeaveProgress("finetune");
  // Data is gathered, the model trains while the loss curve draws itself,
  // then the tuned model starts clearing tasks on its own.
  const collect = range(p, 0.04, 0.3);
  const train = range(p, 0.32, 0.66);
  const serve = range(p, 0.66, 0.92);
  const step = p < 0.32 ? 0 : p < 0.66 ? 1 : 2;
  const epoch = Math.min(3, Math.floor(train * 3) + 1);
  const loss = LOSS[Math.round(train * (LOSS.length - 1))];

  return (
    <div
      className="mx-auto grid h-full max-w-[var(--container-max)] grid-cols-1 items-center gap-10 px-6 pb-10 pt-24 lg:grid-cols-2 lg:gap-16"
      style={{
        transform: `translateY(${leave * 100}vh) scale(${1 - leave * 0.14})`,
        opacity: 1 - leave * 0.8,
        filter: leave > 0 ? `blur(${leave * 8}px)` : undefined,
      }}
    >
      <div>
        <Eyebrow>Local fine-tuning</Eyebrow>
        <h2 className="mt-5 font-display text-3xl font-semibold tracking-[-0.03em] md:text-5xl lg:text-6xl">
          Your data trains
          <br />
          <span className="text-gradient-primary">your own model.</span>
        </h2>
        <p className="mt-4 max-w-xl text-base leading-relaxed text-on-surface-variant md:text-lg">
          Fine-tune a local model on the work you&apos;ve already done, then
          let it process tasks the way you would. Private by default.
        </p>
        <ol className="mt-8 flex flex-col gap-3">
          {STEPS.map((item, i) => {
            const active = i === step;
            const passed = i < step;
            return (
              <li
                key={item.title}
                className={`glass-panel flex gap-4 rounded-2xl p-4 transition-[border-color,background-color,opacity] duration-500 ${
                  active ? "border-primary/50 bg-primary/[0.06]" : ""
                }`}
                style={{ opacity: active ? 1 : passed ? 0.7 : 0.4 }}
              >
                <span
                  className={`flex h-7 w-7 shrink-0 items-center justify-center rounded-full border font-mono text-xs transition-colors duration-500 ${
                    passed
                      ? "border-emerald-400 bg-emerald-400 text-black"
                      : active
                        ? "border-primary text-primary"
                        : "border-white/20 text-on-surface-variant"
                  }`}
                >
                  {passed ? <CheckIcon className="h-3.5 w-3.5" /> : i + 1}
                </span>
                <span>
                  <span className="block font-semibold text-on-surface">{item.title}</span>
                  <span className="mt-1 block text-sm leading-relaxed text-on-surface-variant">
                    {item.body}
                  </span>
                </span>
              </li>
            );
          })}
        </ol>
      </div>

      <div className="glass-panel hidden rounded-[28px] p-5 md:p-6 lg:block">
        <div className="flex items-center justify-between font-mono text-[10px] uppercase tracking-[0.2em] text-on-surface-variant/70">
          <span className="flex items-center gap-2">
            <LaptopIcon className="h-3.5 w-3.5 text-primary" />
            This Mac
          </span>
          <span className="flex items-center gap-1.5">
            <LockIcon className="h-3 w-3" />0 bytes uploaded
          </span>
        </div>

        <div className="mt-4 grid grid-cols-2 gap-2.5">
          {SOURCES.map((source, i) => {
            const filled = easeOut(range(collect, i * 0.15, 0.55 + i * 0.15));
            return (
              <div
                key={source.label}
                className="rounded-2xl border border-white/8 bg-black/30 p-3"
                style={{ opacity: 0.35 + filled * 0.65 }}
              >
                <span className="block text-xs text-on-surface-variant">{source.label}</span>
                <span className="mt-1 block font-mono text-xl text-on-surface">
                  {Math.round(source.count * filled).toLocaleString("en-US")}
                </span>
              </div>
            );
          })}
        </div>

        <div className="mt-4 rounded-2xl border border-white/8 bg-black/30 p-4">
          <div className="flex items-center justify-between text-xs">
            <span className="text-on-surface">Fine-tuning · LoRA adapter</span>
            <span className="font-mono text-on-surface-variant">
              epoch {epoch}/3 · loss {loss.toFixed(2)}
            </span>
          </div>
          <svg viewBox="0 0 100 60" preserveAspectRatio="none" className="mt-3 h-24 w-full">
            <clipPath id="loss-reveal">
              <rect x="0" y="0" width={train * 100} height="60" />
            </clipPath>
            {[15, 30, 45].map((y) => (
              <line key={y} x1="0" x2="100" y1={y} y2={y} stroke="rgba(255,255,255,0.06)" strokeWidth="0.4" />
            ))}
            <path
              d={LOSS_PATH}
              fill="none"
              stroke="#4df5c7"
              strokeWidth="1.4"
              strokeLinecap="round"
              strokeLinejoin="round"
              vectorEffect="non-scaling-stroke"
              clipPath="url(#loss-reveal)"
            />
          </svg>
          <div className="mt-3 h-1.5 overflow-hidden rounded-full bg-white/10">
            <div
              className="h-full rounded-full bg-gradient-to-r from-primary to-[#00cfbb]"
              style={{ width: `${train * 100}%` }}
            />
          </div>
        </div>

        <div className="mt-4 flex flex-col gap-2">
          {LOCAL_TASKS.map((task, i) => {
            const shown = easeOut(range(serve, i * 0.2, 0.2 + i * 0.2));
            const done = serve > 0.25 + i * 0.2;
            return (
              <div
                key={task}
                className="flex items-center gap-3 rounded-xl border border-white/8 bg-white/[0.03] px-3 py-2 transition-[border-color] duration-500"
                style={{
                  opacity: shown,
                  transform: `translateY(${(1 - shown) * 10}px)`,
                  borderColor: done ? "rgba(52,211,153,0.35)" : undefined,
                }}
              >
                <span
                  className={`flex h-5 w-5 shrink-0 items-center justify-center rounded-full border transition-all duration-500 ${
                    done ? "border-emerald-400 bg-emerald-400 text-black" : "border-white/20 text-transparent"
                  }`}
                >
                  <CheckIcon className="h-3 w-3" />
                </span>
                <span className="flex-1 truncate text-sm text-on-surface">{task}</span>
                <span className="flex items-center gap-1 rounded-full border border-primary/30 bg-primary/10 px-2 py-0.5 font-mono text-[9px] uppercase tracking-wider text-primary">
                  <SparkIcon className="h-2.5 w-2.5" />
                  Local
                </span>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
