import type { ReactNode } from "react";

type DocsSectionProps = {
  id: string;
  title: string;
  children: ReactNode;
};

/**
 * A docs/tutorial section: a heading plus flat content, both direct children of
 * the section so the `.prose` spacing rules (globals.css) apply. The `id` lives
 * on the section for anchor links + scrollspy.
 */
export function DocsSection({ id, title, children }: DocsSectionProps) {
  return (
    <section id={id} className="reveal">
      <h2>{title}</h2>
      {children}
    </section>
  );
}

export function DocsSubsection({
  id,
  title,
  children,
}: {
  id?: string;
  title: string;
  children: ReactNode;
}) {
  return (
    <>
      <h3 id={id}>{title}</h3>
      {children}
    </>
  );
}

export function InlineCode({ children }: { children: ReactNode }) {
  return <code className="code-pill">{children}</code>;
}

export function DocsTable({
  headers,
  rows,
}: {
  headers: string[];
  rows: ReactNode[][];
}) {
  return (
    <div className="table-scroll">
      <table className="ref-table">
        <thead>
          <tr>
            {headers.map((h) => (
              <th key={h}>{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((cells, i) => (
            <tr key={i}>
              {cells.map((cell, j) => (
                <td key={j}>{cell}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
