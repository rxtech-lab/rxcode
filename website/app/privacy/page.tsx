import type { Metadata } from "next";
import PrivacyContent from "@/content/privacy.mdx";
import { LegalPage } from "../legal-page";

export const metadata: Metadata = {
  title: "RxCode — Privacy Policy",
  description:
    "Privacy information for RxCode, including local app data, connected services, mobile sync, website analytics, and user choices.",
  alternates: { canonical: "/privacy" },
};

export default function PrivacyPage() {
  return (
    <LegalPage
      eyebrow="Privacy"
      title="Privacy Policy"
      description="How RxCode handles local app data, connected services, mobile sync, and website analytics."
    >
      <PrivacyContent />
    </LegalPage>
  );
}
