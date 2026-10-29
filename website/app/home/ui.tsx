import type { ReactNode } from "react";

export const GITHUB_REPO_URL = "https://github.com/rxtech-lab/rxcode";
export const FLOWCY_URL = "https://www.flowcy.dev";

/** Supported agent runtimes, with logos in /public/agents. */
export const AGENTS = [
  { name: "Claude Code", vendor: "Anthropic", logo: "/agents/claude.svg" },
  { name: "Codex", vendor: "OpenAI", logo: "/agents/openai.svg" },
  { name: "Antigravity", vendor: "Google", logo: "/agents/antigravity.svg" },
  { name: "Cursor", vendor: "Anysphere", logo: "/agents/cursor.svg" },
  { name: "OpenCode", vendor: "SST", logo: "/agents/opencode.svg" },
  { name: "Gemini CLI", vendor: "Google", logo: "/agents/gemini.svg" },
  { name: "GitHub Copilot", vendor: "GitHub", logo: "/agents/githubcopilot.svg" },
  { name: "Qwen Code", vendor: "Alibaba", logo: "/agents/qwen.svg" },
  { name: "Kimi CLI", vendor: "Moonshot", logo: "/agents/kimi.svg" },
] as const;

export function Eyebrow({ children }: { children: ReactNode }) {
  return (
    <span className="inline-flex items-center gap-2 rounded-full border border-primary/30 bg-primary/10 px-3 py-1 font-mono text-[11px] uppercase tracking-[0.2em] text-primary">
      <span className="h-1.5 w-1.5 rounded-full bg-primary" />
      {children}
    </span>
  );
}

/**
 * Stand-in for a product screenshot. Swap it for an <Image> once the new
 * captures are ready.
 */
export function ScreenshotPlaceholder({
  label,
  aspect = "aspect-[16/10]",
  className = "",
}: {
  label: string;
  aspect?: string;
  className?: string;
}) {
  return (
    <div
      className={`placeholder-shimmer relative ${aspect} w-full overflow-hidden rounded-[inherit] bg-surface-container-low ${className}`}
      role="img"
      aria-label={`Screenshot placeholder: ${label}`}
    >
      <div className="absolute inset-0 bg-dots opacity-40" />
      <div className="absolute inset-0 flex flex-col items-center justify-center gap-3 p-6 text-center">
        <span className="flex h-11 w-11 items-center justify-center rounded-2xl border border-white/10 bg-white/5 text-on-surface-variant">
          <ImageIcon className="h-5 w-5" />
        </span>
        <span className="font-mono text-[11px] uppercase tracking-[0.2em] text-on-surface-variant/70">
          {label}
        </span>
      </div>
    </div>
  );
}

/* -------------------------- icons -------------------------- */

type IconProps = { className?: string };

export function AppleIcon({ className = "" }: IconProps) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="currentColor" aria-hidden="true">
      <path d="M16.365 1.43c0 1.14-.42 2.24-1.18 3.04-.78.82-2.06 1.46-3.1 1.38-.13-1.12.43-2.28 1.16-3.04.82-.86 2.22-1.5 3.12-1.38Zm3.95 16.94c-.55 1.26-1.18 2.46-2.07 3.5-1.04 1.22-2.07 2.04-3.34 2.04-1.22 0-1.57-.78-3.13-.78-1.6 0-1.98.76-3.18.8-1.28.04-2.42-1.04-3.45-2.26-2.16-2.56-3.82-7.24-1.6-10.4 1.1-1.56 3.05-2.54 5.13-2.58 1.4-.04 2.74.94 3.6.94.84 0 2.46-1.16 4.16-.98.72.04 2.66.3 3.92 2.22-.1.08-2.34 1.36-2.3 4.06.04 3.22 2.84 4.32 2.86 4.34-.02.08-.42 1.44-1.4 2.94Z" />
    </svg>
  );
}

export function GitHubIcon({ className = "" }: IconProps) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="currentColor" aria-hidden="true">
      <path d="M12 .5C5.73.5.96 5.27.96 11.55c0 4.92 3.18 9.08 7.6 10.55.55.1.75-.24.75-.53v-1.86c-3.09.67-3.74-1.49-3.74-1.49-.5-1.27-1.23-1.6-1.23-1.6-1-.69.08-.67.08-.67 1.11.08 1.7 1.14 1.7 1.14.99 1.69 2.59 1.2 3.22.92.1-.72.39-1.2.7-1.48-2.46-.28-5.05-1.23-5.05-5.48 0-1.21.43-2.2 1.13-2.97-.11-.28-.49-1.4.11-2.91 0 0 .93-.3 3.05 1.13a10.57 10.57 0 0 1 5.56 0c2.12-1.44 3.05-1.13 3.05-1.13.6 1.51.22 2.63.11 2.91.7.77 1.13 1.76 1.13 2.97 0 4.26-2.6 5.2-5.07 5.48.4.34.76 1.01.76 2.04v3.02c0 .29.2.64.76.53 4.41-1.47 7.59-5.63 7.59-10.55C23.04 5.27 18.27.5 12 .5Z" />
    </svg>
  );
}

export function TestFlightLogo({ className = "" }: IconProps) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" aria-hidden="true">
      <circle cx="12" cy="12" r="8.25" stroke="currentColor" strokeWidth="1.7" />
      <circle cx="12" cy="12" r="3.15" stroke="currentColor" strokeWidth="1.7" />
      <path
        d="M12 8.85V4.5M15.15 13.85l3.77 2.18M8.85 13.85l-3.77 2.18"
        stroke="currentColor"
        strokeWidth="1.7"
        strokeLinecap="round"
      />
      <circle cx="12" cy="4.5" r="1.1" fill="currentColor" />
      <circle cx="18.92" cy="16.03" r="1.1" fill="currentColor" />
      <circle cx="5.08" cy="16.03" r="1.1" fill="currentColor" />
    </svg>
  );
}

function strokeIcon(path: ReactNode) {
  return function StrokeIcon({ className = "" }: IconProps) {
    return (
      <svg
        viewBox="0 0 24 24"
        className={className}
        fill="none"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden="true"
      >
        {path}
      </svg>
    );
  };
}

export const ArrowRightIcon = strokeIcon(<path d="M5 12h14M13 6l6 6-6 6" />);
export const CheckIcon = strokeIcon(<path d="M20 6 9 17l-5-5" />);
export const LockIcon = strokeIcon(
  <>
    <rect x="4" y="10.5" width="16" height="10.5" rx="2" />
    <path d="M8 10.5V7a4 4 0 0 1 8 0v3.5" />
  </>
);
export const ImageIcon = strokeIcon(
  <>
    <rect x="3" y="4" width="18" height="16" rx="3" />
    <circle cx="9" cy="10" r="1.6" />
    <path d="m21 16-5-5-9 9" />
  </>
);
export const CalendarIcon = strokeIcon(
  <>
    <rect x="3.5" y="5" width="17" height="15.5" rx="3" />
    <path d="M3.5 10h17M8 3v4M16 3v4" />
  </>
);
export const NewspaperIcon = strokeIcon(
  <>
    <path d="M5 4h12a2 2 0 0 1 2 2v12a2 2 0 0 0 2 2H7a2 2 0 0 1-2-2V4Z" />
    <path d="M9 8h6M9 12h6M9 16h3" />
  </>
);
export const ChatIcon = strokeIcon(
  <path d="M20 12a8 8 0 0 1-11.6 7.1L4 20l1-4.2A8 8 0 1 1 20 12Z" />
);
export const LaptopIcon = strokeIcon(
  <>
    <rect x="4" y="4.5" width="16" height="11" rx="2" />
    <path d="M2 19.5h20" />
  </>
);
export const ServerIcon = strokeIcon(
  <>
    <rect x="3.5" y="4" width="17" height="7" rx="2" />
    <rect x="3.5" y="13" width="17" height="7" rx="2" />
    <path d="M7.5 7.5h.01M7.5 16.5h.01" />
  </>
);
export const PhoneIcon = strokeIcon(
  <>
    <rect x="7" y="2.5" width="10" height="19" rx="2.5" />
    <path d="M11 18.5h2" />
  </>
);
export const CloudIcon = strokeIcon(
  <path d="M7 18a4.5 4.5 0 0 1-.5-8.97A6 6 0 0 1 18 9.5a4 4 0 0 1-.5 8.5H7Z" />
);
export const BoltIcon = strokeIcon(<path d="M13 2 4 14h7l-1 8 9-12h-7l1-8Z" />);
export const SparkIcon = strokeIcon(
  <path d="M12 3v4M12 17v4M3 12h4M17 12h4M6 6l2.5 2.5M15.5 15.5 18 18M6 18l2.5-2.5M15.5 8.5 18 6" />
);
