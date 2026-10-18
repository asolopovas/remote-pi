import { SourceLink } from "@/components/source-link";
import Link from "next/link";

export function SiteFooter() {
  return (
    <footer className="footer">
      <div className="wrap footer-inner">
        <div className="copy">
          Original project: © {new Date().getFullYear()} <b>Flutterando</b>. Remote Pi is open
          source under the MIT license.
        </div>
        <nav className="footer-links">
          <Link href="/docs">Docs</Link>
          <Link href="/download">Download</Link>
          <Link href="/remote-pi">Remote Pi</Link>
          <Link href="/terms">Terms of Service</Link>
          <Link href="/privacy">Privacy Policy</Link>
          <a
            href="/remote-pi/docs#protocol"
            target="_blank"
            rel="noopener noreferrer"
          >
            Protocol
          </a>
          <SourceLink target="_blank" rel="noopener noreferrer">
            GitHub
          </SourceLink>
        </nav>
      </div>
    </footer>
  );
}
