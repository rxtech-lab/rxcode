"use client";

import type { AnchorHTMLAttributes, ReactNode } from "react";
import {
  type AnalyticsEventName,
  trackAnalyticsEvent,
} from "./analytics";

type TrackedLinkProps = AnchorHTMLAttributes<HTMLAnchorElement> & {
  analyticsEventName: AnalyticsEventName;
  analyticsLabel: string;
  analyticsLocation: string;
  children: ReactNode;
};

export function TrackedLink({
  analyticsEventName,
  analyticsLabel,
  analyticsLocation,
  children,
  href,
  onClick,
  ...props
}: TrackedLinkProps) {
  return (
    <a
      href={href}
      onClick={(event) => {
        trackAnalyticsEvent(analyticsEventName, {
          label: analyticsLabel,
          location: analyticsLocation,
          link_url: href ?? null,
          transport_type: "beacon",
        });
        onClick?.(event);
      }}
      {...props}
    >
      {children}
    </a>
  );
}
