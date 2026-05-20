import type { ReactNode } from "react";

/**
 * "Agents that talk to each other" feature card with an animated diagram.
 *
 * The animation is pure CSS (keyframes live in globals.css), so this stays a
 * server component and degrades gracefully under `prefers-reduced-motion`.
 */

const NODE_W = 188;
const NODE_H = 86;

const ACCENTS = {
  frontend: { stroke: "#ff8c00", soft: "rgba(255, 140, 0, 0.14)" },
  backend: { stroke: "#85cfff", soft: "rgba(133, 207, 255, 0.14)" },
  mobile: { stroke: "#bdf4ff", soft: "rgba(189, 244, 255, 0.14)" },
} as const;

// Each edge is a thread connecting two project agents. Messages stream both
// ways: an orange packet trail in one direction, a cyan trail in the other.
const EDGES = [
  { d: "M216 83 L504 83", fwdDelay: "0s", revDelay: "0.8s" },
  { d: "M122 126 L313 250", fwdDelay: "0.5s", revDelay: "1.2s" },
  { d: "M598 126 L407 250", fwdDelay: "0.9s", revDelay: "0.3s" },
];

// Where the threads dock onto each node.
const PORTS: Array<[number, number, string]> = [
  [216, 83, ACCENTS.frontend.stroke],
  [504, 83, ACCENTS.backend.stroke],
  [122, 126, ACCENTS.frontend.stroke],
  [313, 250, ACCENTS.mobile.stroke],
  [598, 126, ACCENTS.backend.stroke],
  [407, 250, ACCENTS.mobile.stroke],
];

export function AgentTalkFeature() {
  return (
    <article className="md:col-span-3 bg-surface border border-surface-variant p-7 md:p-9 hover:border-primary transition-colors">
      <div className="grid grid-cols-1 lg:grid-cols-[0.82fr_1.18fr] gap-8 lg:gap-12 items-center">
        <div>
          <div className="flex items-center gap-2 mb-4 font-mono text-[11px] tracking-widest uppercase text-primary">
            <SparkIcon className="w-3.5 h-3.5" />
            Agent Collaboration
          </div>
          <h3 className="font-display text-2xl md:text-3xl font-semibold mb-4 tracking-tight">
            Agents that talk to each other
          </h3>
          <p className="text-on-surface-variant leading-relaxed">
            When your work spans several projects — a frontend, a backend, and a
            mobile app — each project&apos;s agent can message the others
            through their threads. Agents exchange context across the whole
            codebase, so every change is made with a full understanding of the
            system instead of a single repository.
          </p>
        </div>
        <AgentTalkDiagram />
      </div>
    </article>
  );
}

function AgentTalkDiagram() {
  return (
    <div className="relative">
      <div className="pointer-events-none absolute inset-8 -z-10 bg-primary/5 blur-3xl" />
      <svg
        viewBox="0 0 720 372"
        className="w-full h-auto"
        role="img"
        aria-label="Frontend, backend, and mobile project agents exchanging messages through shared threads"
      >
        {EDGES.map((edge) => (
          <g key={edge.d}>
            <path d={edge.d} fill="none" stroke="#353534" strokeWidth={2} />
            <path
              d={edge.d}
              fill="none"
              stroke={ACCENTS.frontend.stroke}
              strokeWidth={4.5}
              className="agent-stream"
              style={{
                filter: "drop-shadow(0 0 5px rgba(255, 140, 0, 0.65))",
                animationDelay: edge.fwdDelay,
              }}
            />
            <path
              d={edge.d}
              fill="none"
              stroke={ACCENTS.backend.stroke}
              strokeWidth={4.5}
              className="agent-stream agent-stream-rev"
              style={{
                filter: "drop-shadow(0 0 5px rgba(133, 207, 255, 0.6))",
                animationDelay: edge.revDelay,
              }}
            />
          </g>
        ))}

        {PORTS.map(([cx, cy, color]) => (
          <circle key={`${cx}-${cy}`} cx={cx} cy={cy} r={4} fill={color} />
        ))}

        <ProjectNode
          x={28}
          y={40}
          name="Frontend"
          role="UI agent"
          accent={ACCENTS.frontend}
          delay="0s"
          icon={<FrontendGlyph color={ACCENTS.frontend.stroke} />}
        />
        <ProjectNode
          x={504}
          y={40}
          name="Backend"
          role="API agent"
          accent={ACCENTS.backend}
          delay="1.1s"
          icon={<BackendGlyph color={ACCENTS.backend.stroke} />}
        />
        <ProjectNode
          x={266}
          y={250}
          name="Mobile"
          role="App agent"
          accent={ACCENTS.mobile}
          delay="2.2s"
          icon={<MobileGlyph color={ACCENTS.mobile.stroke} />}
        />
      </svg>
      <p className="mt-4 text-center font-mono text-[10px] tracking-widest uppercase text-on-surface-variant/60">
        Messages relayed agent-to-agent through project threads
      </p>
    </div>
  );
}

function ProjectNode({
  x,
  y,
  name,
  role,
  accent,
  delay,
  icon,
}: {
  x: number;
  y: number;
  name: string;
  role: string;
  accent: { stroke: string; soft: string };
  delay: string;
  icon: ReactNode;
}) {
  return (
    <g>
      <rect
        x={x}
        y={y}
        width={NODE_W}
        height={NODE_H}
        rx={12}
        fill="#201f1f"
        stroke="#353534"
        strokeWidth={1.5}
      />
      <rect
        x={x}
        y={y}
        width={NODE_W}
        height={NODE_H}
        rx={12}
        fill="none"
        stroke={accent.stroke}
        strokeWidth={1.5}
        className="agent-ring"
        style={{ animationDelay: delay }}
      />
      <g transform={`translate(${x + 16}, ${y + 23})`}>
        <rect width={40} height={40} rx={10} fill={accent.soft} />
        {icon}
      </g>
      <text
        x={x + 70}
        y={y + 39}
        fontSize={17}
        fontWeight={600}
        fill="#e5e2e1"
        style={{ fontFamily: "var(--font-display)" }}
      >
        {name}
      </text>
      <text
        x={x + 70}
        y={y + 59}
        fontSize={9.5}
        fill="#ddc1ae"
        letterSpacing={2}
        style={{ fontFamily: "var(--font-mono)" }}
      >
        {role.toUpperCase()}
      </text>
      <circle
        cx={x + NODE_W - 18}
        cy={y + 18}
        r={4}
        fill={accent.stroke}
        className="agent-pulse"
        style={{ animationDelay: delay }}
      />
    </g>
  );
}

function FrontendGlyph({ color }: { color: string }) {
  return (
    <g
      transform="translate(8, 8)"
      stroke={color}
      strokeWidth={2}
      fill="none"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <rect x={1} y={3} width={22} height={18} rx={3} />
      <line x1={1} y1={9} x2={23} y2={9} />
      <circle cx={4.8} cy={6} r={0.5} fill={color} stroke="none" />
      <circle cx={7.8} cy={6} r={0.5} fill={color} stroke="none" />
    </g>
  );
}

function BackendGlyph({ color }: { color: string }) {
  return (
    <g
      transform="translate(8, 8)"
      stroke={color}
      strokeWidth={2}
      fill="none"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <rect x={2} y={3} width={20} height={8} rx={2.5} />
      <rect x={2} y={14} width={20} height={8} rx={2.5} />
      <line x1={6} y1={7} x2={6} y2={7} />
      <line x1={6} y1={18} x2={6} y2={18} />
    </g>
  );
}

function MobileGlyph({ color }: { color: string }) {
  return (
    <g
      transform="translate(8, 8)"
      stroke={color}
      strokeWidth={2}
      fill="none"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <rect x={6} y={1} width={12} height={22} rx={3.5} />
      <line x1={9.5} y1={19} x2={14.5} y2={19} />
    </g>
  );
}

function SparkIcon({ className = "" }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      className={className}
      fill="currentColor"
      aria-hidden="true"
    >
      <path d="M12 2 14 9l7 2-7 2-2 7-2-7-7-2 7-2 2-7Z" />
    </svg>
  );
}
