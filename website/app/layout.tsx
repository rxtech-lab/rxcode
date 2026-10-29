import type { Metadata } from "next";
import { Geist, Inter, JetBrains_Mono } from "next/font/google";
import { GoogleAnalytics } from "./analytics";
import "./globals.css";
import { PageViewTracker } from "./page-view-tracker";

const inter = Inter({
  variable: "--font-inter",
  subsets: ["latin"],
  display: "swap",
});

const geist = Geist({
  variable: "--font-geist",
  subsets: ["latin"],
  display: "swap",
});

const jetbrainsMono = JetBrains_Mono({
  variable: "--font-jetbrains-mono",
  subsets: ["latin"],
  display: "swap",
});

export const metadata: Metadata = {
  metadataBase: new URL(
    process.env.NEXT_PUBLIC_SITE_URL ?? "https://code.rxlab.app"
  ),
  title: "RxCode — Plan the big idea. Let your agents ship it.",
  description:
    "The native workspace for teams of AI agents. Sprint boards, automatic agent routing, schedules, briefings and chat for Claude Code, Codex, Antigravity, Cursor, OpenCode and more — on Mac, server and mobile.",
  openGraph: {
    title: "RxCode — Plan the big idea. Let your agents ship it.",
    description:
      "Sprint boards, automatic agent routing, schedules, briefings and chat for your team of AI coding agents — on Mac, server and mobile.",
    type: "website",
    url: "/",
    siteName: "RxCode",
    locale: "en_US",
    images: [
      {
        url: "/api/og",
        width: 1200,
        height: 630,
        alt: "RxCode — Plan the big idea. Let your agents ship it.",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "RxCode — Plan the big idea. Let your agents ship it.",
    description:
      "Sprint boards, automatic agent routing, schedules, briefings and chat for your team of AI coding agents — on Mac, server and mobile.",
    images: ["/api/og"],
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={`${inter.variable} ${geist.variable} ${jetbrainsMono.variable}`}
    >
      <body className="min-h-screen flex flex-col">
        {children}
        <PageViewTracker />
      </body>
      <GoogleAnalytics />
    </html>
  );
}
