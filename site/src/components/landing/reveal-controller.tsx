"use client";

import { useEffect } from "react";

/**
 * Adds `.in` to every `.reveal` element as it scrolls into view, driving the
 * fade-up animation defined in globals.css. Mounted once on the landing page;
 * queries the global DOM so server-rendered sections stay server components.
 */
export function RevealController() {
  useEffect(() => {
    const els = document.querySelectorAll(".reveal");
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      els.forEach((el) => el.classList.add("in"));
      return;
    }
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((e) => {
          if (e.isIntersecting) {
            e.target.classList.add("in");
            io.unobserve(e.target);
          }
        });
      },
      { threshold: 0.12 },
    );
    els.forEach((el) => io.observe(el));
    return () => io.disconnect();
  }, []);

  return null;
}
