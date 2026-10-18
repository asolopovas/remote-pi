import type { AnchorHTMLAttributes } from "react";
import { repositoryUrl } from "@/lib/repository-guides.mjs";

/** Missing/invalid repository configuration must not imply another publisher. */
export function SourceLink({ children, className, ...props }: Omit<AnchorHTMLAttributes<HTMLAnchorElement>, "href">) {
  const href = repositoryUrl(process.env.NEXT_PUBLIC_REPOSITORY_URL);
  if (!href) {
    return <span className={className} role="link" aria-disabled="true" title="Source unavailable: configure NEXT_PUBLIC_REPOSITORY_URL">{children}</span>;
  }
  return <a {...props} className={className} href={href}>{children}</a>;
}
