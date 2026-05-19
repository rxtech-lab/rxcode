import type { Metadata } from "next";
import Link from "next/link";

const SITE_URL = process.env.NEXT_PUBLIC_SITE_URL ?? "https://code.rxlab.app";
const MOBILE_APP_STORE_ID =
  process.env.RXCODE_MOBILE_APP_STORE_ID ??
  process.env.NEXT_PUBLIC_RXCODE_MOBILE_APP_STORE_ID;

type PairPageProps = {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
};

export async function generateMetadata({
  searchParams,
}: PairPageProps): Promise<Metadata> {
  const params = await searchParams;
  const pairURL = pairURLFromSearchParams(params);

  return {
    title: "Pair RxCode Mobile",
    description: "Open RxCode Mobile to pair this device with your Mac.",
    robots: {
      index: false,
      follow: false,
    },
    itunes: MOBILE_APP_STORE_ID
      ? {
          appId: MOBILE_APP_STORE_ID,
          appArgument: pairURL,
        }
      : undefined,
  };
}

export default async function PairPage({ searchParams }: PairPageProps) {
  const params = await searchParams;
  const pairURL = pairURLFromSearchParams(params);
  const relayURL = first(params.relay);

  return (
    <main className="min-h-screen flex items-center justify-center px-6 py-16">
      <section className="w-full max-w-lg">
        <Link
          href="/"
          className="font-display text-2xl font-bold text-primary tracking-tight"
        >
          RxCode
        </Link>

        <div className="mt-10 border border-surface-variant bg-surface-container-low p-6 rounded-xl">
          <p className="font-mono text-[11px] uppercase tracking-widest text-primary">
            Pairing link
          </p>
          <h1 className="mt-4 font-display text-3xl font-semibold">
            Open RxCode Mobile
          </h1>
          <p className="mt-4 text-on-surface-variant leading-relaxed">
            If RxCode Mobile is installed, this link opens the app and starts
            the existing pairing flow. If it is not installed, Safari can show
            the App Store banner for RxCode Mobile.
          </p>

          {relayURL ? (
            <div className="mt-5 border border-outline-variant bg-surface-container p-4 rounded-lg">
              <p className="font-mono text-[10px] uppercase tracking-widest text-on-surface-variant">
                Relay URL
              </p>
              <p className="mt-2 break-all font-mono text-xs text-on-surface">
                {relayURL}
              </p>
            </div>
          ) : null}

          <a
            href={pairURL}
            className="mt-6 inline-flex w-full items-center justify-center bg-primary text-on-primary px-5 py-3 font-mono text-xs tracking-widest uppercase border border-primary hover:bg-transparent hover:text-primary transition-colors"
          >
            Open RxCode Mobile
          </a>
        </div>
      </section>
    </main>
  );
}

function pairURLFromSearchParams(
  params: Record<string, string | string[] | undefined>
) {
  const url = new URL("/pair", SITE_URL);
  const token = first(params.token);
  const relay = first(params.relay);

  if (token) {
    url.searchParams.set("token", token);
  }
  if (relay) {
    url.searchParams.set("relay", relay);
  }

  return url.toString();
}

function first(value: string | string[] | undefined) {
  return Array.isArray(value) ? value[0] : value;
}
