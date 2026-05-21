"use client";

import { usePathname } from "next/navigation";
import { useEffect } from "react";
import { isGoogleAnalyticsEnabled } from "./analytics";

export function PageViewTracker() {
  const pathname = usePathname();

  useEffect(() => {
    if (!isGoogleAnalyticsEnabled || typeof window === "undefined") {
      return;
    }

    const pagePath = `${window.location.pathname}${window.location.search}`;

    window.gtag?.("event", "page_view", {
      page_path: pagePath,
      page_location: window.location.href,
      page_title: document.title,
    });
  }, [pathname]);

  return null;
}
