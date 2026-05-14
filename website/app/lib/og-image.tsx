import { ImageResponse } from "next/og";

export const OG_SIZE = { width: 1200, height: 630 };

export function renderOgImage(
  title = "The Visual Command Center for AI Coding Agents",
  description = "Native macOS · Claude Code & Codex · Free & Open Source"
): ImageResponse {
  return new ImageResponse(
    (
      <div
        style={{
          background: "#0E0E0F",
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
              "linear-gradient(rgba(217,119,87,0.06) 1px, transparent 1px), linear-gradient(90deg, rgba(217,119,87,0.06) 1px, transparent 1px)",
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
              "radial-gradient(ellipse, rgba(217,119,87,0.18) 0%, transparent 70%)",
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
          <div
            style={{
              width: "76px",
              height: "76px",
              background: "#D97757",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              borderRadius: "14px",
            }}
          >
            <span
              style={{
                color: "#FFFFFF",
                fontSize: "34px",
                fontWeight: 700,
                letterSpacing: "-0.5px",
              }}
            >
              Rx
            </span>
          </div>
          <span
            style={{
              color: "#F5F0EB",
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
            color: "#F5F0EB",
            fontSize: "38px",
            fontWeight: 600,
            textAlign: "center",
            lineHeight: 1.25,
            maxWidth: "820px",
          }}
        >
          {title}
        </div>

        {/* Sub-label */}
        <div
          style={{
            color: "#7A6E68",
            fontSize: "22px",
            marginTop: "28px",
            letterSpacing: "0.12em",
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
