import { ImageResponse } from "next/og";
import { BRAND_ICON_DATA_URL } from "./brand-icon";

export const OG_SIZE = { width: 1200, height: 630 };
const DEFAULT_TITLE = "Plan the big idea. Let your agents ship it.";

export function renderOgImage(
  title = DEFAULT_TITLE,
  description = "Mac, server & mobile · Claude Code, Codex & ACP"
): ImageResponse {
  return new ImageResponse(
    (
      <div
        style={{
          background: "#041438",
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          fontFamily: "system-ui, sans-serif",
          padding: "80px",
          position: "relative",
        }}
      >
        {/* Subtle grid overlay */}
        <div
          style={{
            position: "absolute",
            inset: 0,
            backgroundImage:
              "linear-gradient(rgba(0,207,187,0.06) 1px, transparent 1px), linear-gradient(90deg, rgba(0,207,187,0.06) 1px, transparent 1px)",
            backgroundSize: "40px 40px",
            display: "flex",
          }}
        />

        {/* Glow */}
        <div
          style={{
            position: "absolute",
            top: "50%",
            left: "50%",
            transform: "translate(-50%, -60%)",
            width: "600px",
            height: "400px",
            background:
              "radial-gradient(ellipse, rgba(0,207,187,0.18) 0%, transparent 70%)",
            display: "flex",
          }}
        />

        {/* Logo + Name */}
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: "20px",
            marginBottom: "40px",
          }}
        >
          {/* Embedded artwork also used by the website and browser icons. */}
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={BRAND_ICON_DATA_URL} width={96} height={96} alt="" style={{ borderRadius: "22px" }} />
          <span
            style={{
              color: "#e8f4ff",
              fontSize: "60px",
              fontWeight: 700,
              letterSpacing: "-1px",
            }}
          >
            RxCode
          </span>
        </div>

        {/* Headline */}
        <div
          style={{
            color: "#e8f4ff",
            fontSize: "52px",
            fontWeight: 600,
            textAlign: "center",
            lineHeight: 1.25,
            maxWidth: "940px",
            display: "flex",
            flexDirection: "column",
            alignItems: "center",
          }}
        >
          {title === DEFAULT_TITLE ? (
            <div style={{ display: "flex", flexDirection: "column", alignItems: "center" }}>
              <div style={{ display: "flex", color: "#4df5c7" }}>Plan the big idea.</div>
              <div style={{ display: "flex" }}>Let your agents ship it.</div>
            </div>
          ) : title}
        </div>

        {/* Sub-label */}
        <div
          style={{
            color: "#aec8de",
            fontSize: "22px",
            marginTop: "28px",
            letterSpacing: "0.04em",
            textTransform: "uppercase",
            display: "flex",
            gap: "16px",
            alignItems: "center",
          }}
        >
          {description}
        </div>
      </div>
    ),
    { ...OG_SIZE }
  );
}
