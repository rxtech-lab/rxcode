import type { Metadata } from "next";
import UserAgreementContent from "@/content/user-agreement.mdx";
import { LegalPage } from "../legal-page";

export const metadata: Metadata = {
  title: "RxCode — User Agreement",
  description:
    "User agreement for RxCode, including responsible use, AI-generated output, third-party providers, and service availability.",
  alternates: { canonical: "/user-agreement" },
};

export default function UserAgreementPage() {
  return (
    <LegalPage
      eyebrow="Agreement"
      title="User Agreement"
      description="The terms for using RxCode, connected providers, AI-generated output, mobile sync, and related services."
    >
      <UserAgreementContent />
    </LegalPage>
  );
}
