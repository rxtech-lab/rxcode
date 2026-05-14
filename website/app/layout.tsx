import type { Metadata } from "next";
import { Geist, Inter, JetBrains_Mono } from "next/font/google";
import "./globals.css";

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
    process.env.NEXT_PUBLIC_SITE_URL ?? "https://rxcode.app"
  ),
  title: "RxCode — The Visual Command Center for AI Coding Agents",
  description:
    "A native macOS desktop client that supercharges your AI coding workflow. Manage sessions, visualize project architecture, and review AI-generated code without leaving your desktop.",
  openGraph: {
    title: "RxCode — The Visual Command Center for AI Coding Agents",
    description:
      "A native macOS desktop client for AI coding agents. Visual sessions, project tree, and code review in one place.",
    type: "website",
    url: "/",
    siteName: "RxCode",
    locale: "en_US",
  },
  twitter: {
    card: "summary_large_image",
    title: "RxCode — The Visual Command Center for AI Coding Agents",
    description:
      "A native macOS desktop client for AI coding agents. Visual sessions, project tree, and code review in one place.",
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
      <body className="min-h-screen flex flex-col">{children}</body>
    </html>
  );
}
