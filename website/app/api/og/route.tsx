import { NextRequest } from "next/server";
import { renderOgImage } from "../../lib/og-image";

export const runtime = "edge";

export async function GET(request: NextRequest) {
  const { searchParams } = new URL(request.url);

  const title = searchParams.get("title") ?? undefined;
  const description = searchParams.get("description") ?? undefined;

  return renderOgImage(title, description);
}
