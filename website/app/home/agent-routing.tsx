"use client";

import { easeOut, range, ScrollScene, useSceneProgress } from "./motion";
import { Eyebrow } from "./ui";

const TASKS = [
  { title: "Fix typo in README", size: "S", y: 80, lane: 0 },
  { title: "Add settings screen", size: "M", y: 210, lane: 1 },
  { title: "Migrate auth to passkeys", size: "L", y: 340, lane: 2 },
];

const LANES = [
  { name: "Light", detail: "Fast, low-cost model", y: 80, color: "#c7e8ff" },
  { name: "Standard", detail: "Balanced everyday model", y: 210, color: "#9edaff" },
  { name: "Heavy", detail: "Deep reasoning model", y: 340, color: "#4df5c7" },
];

const ROUTER = { x: 400, y: 210 };

export function AgentRouting() {
  return (
    <ScrollScene id="routing" height="260vh">
      <RoutingStage />
    </ScrollScene>
  );
}

function RoutingStage() {
  const p = useSceneProgress();

  return (
    <div className="mx-auto flex h-full max-w-[var(--container-max)] flex-col justify-center px-6 pb-8 pt-24">
      <div className="mx-auto max-w-3xl text-center">
        <Eyebrow>Automatic routing</Eyebrow>
        <h2 className="mt-5 font-display text-3xl font-semibold tracking-[-0.03em] md:text-5xl lg:text-6xl">
          The right-sized agent for{" "}
          <span className="text-gradient-primary">every task.</span>
        </h2>
        <p className="mx-auto mt-4 max-w-2xl text-base leading-relaxed text-on-surface-variant md:text-lg">
          RxCode reads each card&apos;s scope and routes it to the agent and
          model that fit — quick fixes go to fast models, deep refactors go to
          the heavy hitters. You save tokens without losing quality.
        </p>
      </div>

      <div className="relative mx-auto mt-10 w-full max-w-5xl">
        <svg viewBox="0 0 800 420" className="mx-auto h-auto max-h-[50vh] w-full" role="img" aria-label="Tasks of different sizes routed to light, standard, and heavy agents">
          <defs>
            <radialGradient id="router-glow">
              <stop offset="0%" stopColor="#4df5c7" stopOpacity="0.55" />
              <stop offset="100%" stopColor="#4df5c7" stopOpacity="0" />
            </radialGradient>
          </defs>

          {TASKS.map((task, i) => {
            const lane = LANES[task.lane];
            const start = 0.1 + i * 0.22;
            const inbound = easeOut(range(p, start, start + 0.1));
            const outbound = easeOut(range(p, start + 0.1, start + 0.2));
            const inPath = `M250 ${task.y} C 330 ${task.y}, 330 ${ROUTER.y}, ${ROUTER.x - 34} ${ROUTER.y}`;
            const outPath = `M${ROUTER.x + 34} ${ROUTER.y} C 470 ${ROUTER.y}, 470 ${lane.y}, 560 ${lane.y}`;
            return (
              <g key={task.title}>
                <path d={inPath} fill="none" stroke="rgba(255,255,255,0.08)" strokeWidth={2} />
                <path d={outPath} fill="none" stroke="rgba(255,255,255,0.08)" strokeWidth={2} />
                <path d={inPath} fill="none" stroke={lane.color} strokeWidth={2.5} pathLength={1} strokeDasharray="1 1" strokeDashoffset={1 - inbound} strokeLinecap="round" />
                <path d={outPath} fill="none" stroke={lane.color} strokeWidth={2.5} pathLength={1} strokeDasharray="1 1" strokeDashoffset={1 - outbound} strokeLinecap="round" />
              </g>
            );
          })}

          {TASKS.map((task, i) => {
            const shown = easeOut(range(p, 0.02 + i * 0.22, 0.1 + i * 0.22));
            return (
              <g key={task.title} style={{ opacity: 0.25 + shown * 0.75, transform: `translateX(${(1 - shown) * -24}px)`, transition: "opacity 200ms" }}>
                <rect x={20} y={task.y - 28} width={230} height={56} rx={14} fill="#102448" stroke="rgba(255,255,255,0.1)" />
                <rect x={34} y={task.y - 14} width={28} height={28} rx={8} fill="rgba(0,207,187,0.15)" />
                <text x={48} y={task.y + 5} textAnchor="middle" fill="#4df5c7" fontSize={13} fontWeight={700} fontFamily="var(--font-mono)">{task.size}</text>
                <text x={74} y={task.y + 5} fill="#e8f4ff" fontSize={14} fontFamily="var(--font-inter)">{task.title}</text>
              </g>
            );
          })}

          <circle cx={ROUTER.x} cy={ROUTER.y} r={90} fill="url(#router-glow)" opacity={0.4 + 0.6 * Math.abs(Math.sin(p * Math.PI * 6))} />
          <circle cx={ROUTER.x} cy={ROUTER.y} r={34} fill="#142c50" stroke="#4df5c7" strokeWidth={2} />
          <g transform={`rotate(${p * 360} ${ROUTER.x} ${ROUTER.y})`}>
            <circle cx={ROUTER.x} cy={ROUTER.y} r={44} fill="none" stroke="#4df5c7" strokeOpacity={0.4} strokeDasharray="4 8" />
          </g>
          <text x={ROUTER.x} y={ROUTER.y + 5} textAnchor="middle" fill="#4df5c7" fontSize={12} fontWeight={600} fontFamily="var(--font-mono)">ROUTE</text>

          {LANES.map((lane, i) => {
            const lit = range(p, 0.2 + i * 0.22, 0.3 + i * 0.22);
            return (
              <g key={lane.name}>
                <rect x={560} y={lane.y - 32} width={220} height={64} rx={16} fill="#102448" stroke={lane.color} strokeOpacity={0.15 + lit * 0.75} strokeWidth={1.5} />
                <circle cx={588} cy={lane.y} r={7} fill={lane.color} opacity={0.3 + lit * 0.7} />
                <text x={606} y={lane.y - 3} fill="#e8f4ff" fontSize={15} fontWeight={600} fontFamily="var(--font-inter)">{lane.name}</text>
                <text x={606} y={lane.y + 16} fill="#aec8de" fillOpacity={0.7} fontSize={11.5} fontFamily="var(--font-inter)">{lane.detail}</text>
              </g>
            );
          })}
        </svg>
      </div>
    </div>
  );
}
