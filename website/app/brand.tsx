import Image from "next/image";

export function Brand({ className = "" }: { className?: string }) {
  return (
    <span className={`inline-flex items-center gap-2.5 ${className}`}>
      <Image src="/rxcode-icon.svg" alt="" width={36} height={36} className="shrink-0" />
      <span>Rx<span className="text-primary">Code</span></span>
    </span>
  );
}
