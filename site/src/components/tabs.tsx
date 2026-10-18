"use client";

import { useId, useState, type ReactNode } from "react";

export type TabItem = {
  /** Stable id used for ARIA wiring and as the selection key. */
  id: string;
  /** Button label shown in the tablist. */
  label: string;
  /** When true the tab can't be selected (e.g. a not-yet-shipped feature). */
  disabled?: boolean;
  /** Optional pill shown next to the label, e.g. "Coming soon". */
  badge?: string;
  /** Panel contents revealed when the tab is active. */
  content: ReactNode;
};

type TabsProps = {
  items: TabItem[];
  /** Accessible name for the tablist. */
  ariaLabel?: string;
};

/**
 * Minimal, theme-matched tabs primitive. Shared across the home install block
 * (Wave A) and the tutorials section (Wave C). Defaults the active tab to the
 * first non-disabled item so a "Coming soon" tab never traps the panel.
 */
export function Tabs({ items, ariaLabel }: TabsProps) {
  const baseId = useId();
  const firstEnabled = items.find((t) => !t.disabled)?.id ?? items[0]?.id;
  const [active, setActive] = useState(firstEnabled);

  return (
    <div className="flex flex-col gap-4">
      <div
        role="tablist"
        aria-label={ariaLabel}
        className="flex w-fit gap-1 rounded-full border border-border-soft bg-surface p-1"
      >
        {items.map((tab) => {
          const isActive = tab.id === active && !tab.disabled;
          return (
            <button
              key={tab.id}
              type="button"
              role="tab"
              id={`${baseId}-tab-${tab.id}`}
              aria-selected={isActive}
              aria-controls={`${baseId}-panel-${tab.id}`}
              aria-disabled={tab.disabled || undefined}
              disabled={tab.disabled}
              onClick={() => !tab.disabled && setActive(tab.id)}
              className={[
                "flex items-center gap-2 rounded-full px-4 py-1.5 text-sm font-medium transition-colors",
                tab.disabled
                  ? "cursor-not-allowed text-muted/50"
                  : isActive
                    ? "bg-accent text-black"
                    : "text-muted hover:text-fg",
              ].join(" ")}
            >
              {tab.label}
              {tab.badge ? (
                <span className="rounded-full bg-bg/60 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-muted">
                  {tab.badge}
                </span>
              ) : null}
            </button>
          );
        })}
      </div>
      {items.map((tab) =>
        tab.id === active && !tab.disabled ? (
          <div
            key={tab.id}
            role="tabpanel"
            id={`${baseId}-panel-${tab.id}`}
            aria-labelledby={`${baseId}-tab-${tab.id}`}
          >
            {tab.content}
          </div>
        ) : null,
      )}
    </div>
  );
}
