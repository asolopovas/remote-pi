import { RepositoryGuides } from "@/components/repository-guides";

export function Install() {
  return (
    <section className="section" id="install">
      <div className="wrap">
        <div className="section-head reveal">
          <span className="eyebrow">Install from source</span>
          <h2>Build, then pair your phone.</h2>
          <p>Add the source-built extension to Pi and pair your own mobile client.</p>
        </div>
        <div className="install-card">
          <RepositoryGuides guides={["extension", "mobile", "relay", "security"]} />
        </div>
      </div>
    </section>
  );
}
