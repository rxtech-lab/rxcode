import { renderOgImage } from "./lib/og-image";

export const runtime = "edge";

export const alt = "RxCode — The Visual Command Center for AI Coding Agents";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default function Image() {
  return renderOgImage();
}
