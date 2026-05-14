import { GET } from "./api/og/route";

export const runtime = "edge";

export const alt = "RxCode — The Visual Command Center for AI Coding Agents";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default async function Image() {
  const url = new URL(
    "/api/og",
    process.env.NEXT_PUBLIC_SITE_URL ?? "https://rxcode.app"
  );
  return GET(new Request(url.toString()));
}
