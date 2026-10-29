import { renderOgImage } from "./lib/og-image";

export const runtime = "edge";

export const alt = "RxCode — Plan the big idea. Let your agents ship it.";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default function Image() {
  return renderOgImage();
}
