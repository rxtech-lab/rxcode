"use client";

import Image from "next/image";
import { easeOut, range, ScrollScene, useLeaveProgress, useSceneProgress } from "./motion";
import { AGENTS, Eyebrow } from "./ui";

const BUILT_IN = new Set<string>(["Claude Code", "Codex"]);

export function SupportedAgents() {
  return (
    <ScrollScene id="agents" height="280vh" clip={false}>
      <AgentsStage />
    </ScrollScene>
  );
}

function AgentsStage() {
  const p = useSceneProgress();
  // Exit: the grid holds while every tile scatters away from the centre.
  const leave = useLeaveProgress("agents");
  // Agents come online one after another, then the ACP slot opens up.
  const acp = easeOut(range(p, 0.72, 0.86));
  const online = AGENTS.filter((_, i) => p >= 0.06 + i * 0.07).length;

  return (
    <div
      className="mx-auto flex h-full max-w-[var(--container-max)] flex-col justify-center px-6 pb-10 pt-24"
      style={{ transform: `translateY(${leave * 100}vh)` }}
    >
      <div
        className="mx-auto max-w-3xl text-center"
        style={{ opacity: 1 - range(leave, 0, 0.5), transform: `scale(${1 - leave * 0.1})` }}
      >
        <Eyebrow>Every agent, one workspace</Eyebrow>
        <h2 className="mt-5 font-display text-3xl font-semibold tracking-[-0.03em] md:text-5xl lg:text-6xl">
          Bring the agents you love.
        </h2>
        <p className="mx-auto mt-4 max-w-2xl text-base leading-relaxed text-on-surface-variant md:text-lg">
          Claude Code and Codex are built in. Antigravity, Cursor, OpenCode,
          Gemini CLI and any Agent Client Protocol runtime install from the
          ACP registry in one click — same chat, approvals and board.
        </p>
        <p className="mt-4 font-mono text-[11px] uppercase tracking-[0.2em] text-on-surface-variant/70">
          <span className="text-primary">{online}</span> / {AGENTS.length} agents online
        </p>
      </div>

      <div className="mt-8 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
        {AGENTS.map((agent, i) => {
          const lit = easeOut(range(p, 0.06 + i * 0.07, 0.12 + i * 0.07));
          return (
            <div
              key={agent.name}
              className="glass-panel relative flex flex-col items-center gap-3 overflow-hidden rounded-3xl px-4 py-6 text-center transition-[border-color] duration-500"
              style={{
                borderColor: lit > 0.5 ? "rgba(77,245,199,0.35)" : undefined,
                ...scatter(i, leave),
              }}
            >
              <span
                className="pointer-events-none absolute inset-0 bg-[radial-gradient(circle_at_50%_0%,rgba(0,207,187,0.22),transparent_65%)]"
                style={{ opacity: lit }}
              />
              <span
                className="relative flex h-14 w-14 items-center justify-center rounded-2xl border border-white/10 bg-black/40"
                style={{ transform: `translateY(${-lit * 4}px) scale(${1 + lit * 0.08})` }}
              >
                <Image
                  src={agent.logo}
                  alt={`${agent.name} logo`}
                  width={28}
                  height={28}
                  unoptimized
                  className="h-7 w-7"
                  style={{ filter: `grayscale(${1 - lit})`, opacity: 0.45 + lit * 0.55 }}
                />
              </span>
              <span className="relative" style={{ opacity: 0.35 + lit * 0.65 }}>
                <span className="block font-semibold text-on-surface">{agent.name}</span>
                <span className="mt-0.5 block text-xs text-on-surface-variant/70">{agent.vendor}</span>
              </span>
              <span
                className="relative rounded-full border border-primary/30 bg-primary/10 px-2 py-0.5 font-mono text-[9px] uppercase tracking-wider text-primary"
                style={{ opacity: lit, transform: `scale(${0.8 + lit * 0.2})` }}
              >
                {BUILT_IN.has(agent.name) ? "Built in" : "ACP registry"}
              </span>
            </div>
          );
        })}
        <div
          className="glass-panel flex flex-col items-center justify-center gap-2 rounded-3xl border-dashed px-4 py-6 text-center"
          style={{
            transform: `${scatter(AGENTS.length, leave).transform} scale(${0.9 + acp * 0.1})`,
            opacity: (0.2 + acp * 0.8) * (1 - range(leave, 0, 0.7)),
          }}
        >
          <span className="font-display text-3xl font-semibold text-primary">+ ACP</span>
          <span className="text-xs text-on-surface-variant/70">Any Agent Client Protocol runtime</span>
        </div>
      </div>
    </div>
  );
}

/** Pushes tile `i` of the 5×2 grid away from the grid's centre. */
function scatter(i: number, leave: number) {
  const dx = (i % 5) - 2;
  const dy = Math.floor(i / 5) - 0.5;
  const push = leave * leave;
  return {
    transform: `translate(${dx * push * 28}vw, ${dy * push * 50}vh) rotate(${dx * push * 14}deg) scale(${1 - push * 0.3})`,
    opacity: 1 - range(leave, 0, 0.7),
  };
}
