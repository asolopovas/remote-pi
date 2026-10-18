import type { ReactNode } from "react";

type LegalShellProps = {
  title: string;
  lastUpdated: string;
  subtitle?: ReactNode;
  children: ReactNode;
};

export function LegalShell({
  title,
  lastUpdated,
  subtitle,
  children,
}: LegalShellProps) {
  return (
    <div className="page">
      <div className="page-body">
        <div className="wrap">
          <div className="legal">
            <header className="page-head" style={{ maxWidth: "none" }}>
              <span className="eyebrow">Legal · Upstream reference</span>
              <h1>{title}</h1>
              <p role="note">
                Upstream reference only: the operator, contacts and policies below
                describe the original Flutterando service, not this independent
                repository or its deployment. Deployment-specific legal terms
                and privacy disclosures must be supplied by its operator.
              </p>
              <div className="meta-line">
                <span>Last updated: {lastUpdated}</span>
              </div>
              {subtitle ? (
                <div
                  style={{
                    marginTop: 16,
                    color: "var(--ink-soft)",
                    fontSize: 15,
                    lineHeight: 1.65,
                  }}
                >
                  {subtitle}
                </div>
              ) : null}
            </header>
            <div className="legal-body">{children}</div>
          </div>
        </div>
      </div>
    </div>
  );
}

type SectionProps = {
  id: string;
  number: number;
  title: string;
  children: ReactNode;
};

export function LegalSection({ id, number, title, children }: SectionProps) {
  return (
    <section id={id}>
      <h2>
        {number}. {title}
      </h2>
      {children}
    </section>
  );
}
