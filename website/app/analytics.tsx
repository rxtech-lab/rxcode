import Script from "next/script";

const GOOGLE_ANALYTICS_ID = process.env.NEXT_PUBLIC_GOOGLE_ANALYTICS_ID?.trim();

export const isGoogleAnalyticsEnabled = Boolean(GOOGLE_ANALYTICS_ID);

export type AnalyticsEventName =
  | "download_button_click"
  | "app_store_button_click"
  | "testflight_button_click"
  | "google_play_button_click";

type AnalyticsEventParams = Record<string, string | number | boolean | null>;

declare global {
  interface Window {
    dataLayer?: unknown[];
    gtag?: (
      command: "js" | "config" | "event",
      target: string | Date,
      params?: Record<string, unknown>
    ) => void;
  }
}

export function GoogleAnalytics() {
  if (!GOOGLE_ANALYTICS_ID) {
    return null;
  }

  return (
    <>
      <Script
        src={`https://www.googletagmanager.com/gtag/js?id=${GOOGLE_ANALYTICS_ID}`}
        strategy="afterInteractive"
      />
      <Script id="google-analytics" strategy="afterInteractive">
        {`
          window.dataLayer = window.dataLayer || [];
          function gtag(){dataLayer.push(arguments);}
          gtag('js', new Date());
          gtag('config', '${GOOGLE_ANALYTICS_ID}', { send_page_view: false });
        `}
      </Script>
    </>
  );
}

export function trackAnalyticsEvent(
  eventName: AnalyticsEventName,
  params: AnalyticsEventParams = {}
) {
  if (!isGoogleAnalyticsEnabled || typeof window === "undefined") {
    return;
  }

  window.gtag?.("event", eventName, params);
}
