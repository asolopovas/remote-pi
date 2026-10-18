import { GUIDES, guideUrl, repositoryUrl } from "@/lib/repository-guides.mjs";

export type GuideKey = keyof typeof GUIDES;

export function RepositoryGuides({ guides }: { guides: GuideKey[] }) {
  const repository = repositoryUrl(process.env.NEXT_PUBLIC_REPOSITORY_URL);
  return (
    <div className="prose">
      <p>
        Build from this repository&apos;s source. Upstream packages, installers
        and existing update URLs are not releases of this independent repository.
        The linked Markdown guides own setup and configuration.
      </p>
      {!repository && (
        <p role="status">
          Repository guides unavailable: set NEXT_PUBLIC_REPOSITORY_URL to the
          owned HTTPS GitHub repository URL (https://github.com/owner/repo) at build time.
        </p>
      )}
      <ul>
        {guides.map((key) => {
          const guide = GUIDES[key];
          const href = guideUrl(repository, guide.path);
          return (
            <li key={key} id={key}>
              {href ? (
                <a href={href} target="_blank" rel="noopener noreferrer">{guide.label}</a>
              ) : (
                <span role="link" aria-disabled="true">{guide.label} — unavailable</span>
              )}
            </li>
          );
        })}
      </ul>
    </div>
  );
}

export function GuidePage({ title, description, guides }: {
  title: string;
  description: string;
  guides: GuideKey[];
}) {
  return (
    <div className="page">
      <div className="page-body">
        <div className="wrap">
          <header className="page-head">
            <span className="eyebrow">Canonical repository guides</span>
            <h1>{title}</h1>
            <p className="lede">{description}</p>
          </header>
          <RepositoryGuides guides={guides} />
          <p className="text-sm">License: MIT.</p>
        </div>
      </div>
    </div>
  );
}
