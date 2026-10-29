"use client";

import {
  createContext,
  useContext,
  useEffect,
  useRef,
  useState,
  type CSSProperties,
  type ElementType,
  type ReactNode,
} from "react";

/* ------------------------------------------------------------------ */
/*  Shared helpers                                                     */
/* ------------------------------------------------------------------ */

export const clamp = (v: number, min = 0, max = 1) =>
  Math.min(max, Math.max(min, v));

/** Maps `p` from the [start, end] window onto 0…1. */
export const range = (p: number, start: number, end: number) =>
  clamp((p - start) / (end - start));

export const easeOut = (t: number) => 1 - Math.pow(1 - t, 3);

export function usePrefersReducedMotion() {
  const [reduced, setReduced] = useState(false);
  useEffect(() => {
    const media = window.matchMedia("(prefers-reduced-motion: reduce)");
    const update = () => setReduced(media.matches);
    update();
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  }, []);
  return reduced;
}

/* ------------------------------------------------------------------ */
/*  Reveal — fades content up once it scrolls into view               */
/* ------------------------------------------------------------------ */

export function Reveal({
  children,
  as: Tag = "div",
  delay = 0,
  className = "",
  y = 32,
}: {
  children: ReactNode;
  as?: ElementType;
  delay?: number;
  className?: string;
  y?: number;
}) {
  const ref = useRef<HTMLElement>(null);
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    const node = ref.current;
    if (!node) return;
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setVisible(true);
          observer.disconnect();
        }
      },
      { rootMargin: "0px 0px -12% 0px" }
    );
    observer.observe(node);
    return () => observer.disconnect();
  }, []);

  return (
    <Tag
      ref={ref}
      className={`reveal ${visible ? "reveal-in" : ""} ${className}`}
      style={
        {
          "--reveal-delay": `${delay}ms`,
          "--reveal-y": `${y}px`,
        } as CSSProperties
      }
    >
      {children}
    </Tag>
  );
}

/** Splits a headline into words that rise in one after another. */
export function RevealWords({
  text,
  className = "",
  delay = 0,
  stagger = 70,
}: {
  text: string;
  className?: string;
  delay?: number;
  stagger?: number;
}) {
  const words = text.split(" ");
  return (
    <span aria-label={text}>
      {words.map((word, i) => (
        <span
          key={`${word}-${i}`}
          aria-hidden="true"
          className={`word-rise ${className}`}
          style={{ animationDelay: `${delay + i * stagger}ms` }}
        >
          {word}
          {i < words.length - 1 ? " " : ""}
        </span>
      ))}
    </span>
  );
}

/* ------------------------------------------------------------------ */
/*  ScrollScene — a tall, pinned section that reports its progress     */
/* ------------------------------------------------------------------ */

const SceneContext = createContext(0);

/** Scroll progress (0…1) of the nearest enclosing `ScrollScene`. */
export function useSceneProgress() {
  return useContext(SceneContext);
}

/**
 * Apple-style pinned scene. The outer element is `height` tall; the inner
 * stage sticks to the viewport while the user scrolls through it, and
 * children read the 0…1 progress through `useSceneProgress`.
 */
export function ScrollScene({
  children,
  height = "300vh",
  id,
  className = "",
  stageClassName = "",
}: {
  children: ReactNode;
  height?: string;
  id?: string;
  className?: string;
  stageClassName?: string;
}) {
  const ref = useRef<HTMLElement>(null);
  const [progress, setProgress] = useState(0);
  const reduced = usePrefersReducedMotion();

  useEffect(() => {
    const node = ref.current;
    if (!node) return;
    let frame = 0;
    const measure = () => {
      frame = 0;
      const rect = node.getBoundingClientRect();
      const scrollable = rect.height - window.innerHeight;
      const next = scrollable <= 0 ? 1 : clamp(-rect.top / scrollable);
      setProgress((prev) => (Math.abs(prev - next) < 0.001 ? prev : next));
    };
    const onScroll = () => {
      if (!frame) frame = requestAnimationFrame(measure);
    };
    measure();
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onScroll);
    return () => {
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", onScroll);
      if (frame) cancelAnimationFrame(frame);
    };
  }, []);

  return (
    <section
      ref={ref}
      id={id}
      className={`relative ${className}`}
      style={{ height: reduced ? "auto" : height }}
    >
      <div
        className={`${
          reduced ? "relative py-24" : "sticky top-0 h-screen"
        } overflow-hidden ${stageClassName}`}
      >
        <SceneContext.Provider value={reduced ? 1 : progress}>
          {children}
        </SceneContext.Provider>
      </div>
    </section>
  );
}

/* ------------------------------------------------------------------ */
/*  useElementProgress — progress of an element crossing the viewport  */
/* ------------------------------------------------------------------ */

/**
 * 0 when the element's top reaches the bottom of the viewport, 1 when its
 * top reaches `endOffset` (fraction of viewport height) from the top.
 */
export function useElementProgress<T extends HTMLElement>(endOffset = 0.2) {
  const ref = useRef<T>(null);
  const [progress, setProgress] = useState(0);
  const reduced = usePrefersReducedMotion();

  useEffect(() => {
    const node = ref.current;
    if (!node) return;
    let frame = 0;
    const measure = () => {
      frame = 0;
      const vh = window.innerHeight;
      const top = node.getBoundingClientRect().top;
      const next = clamp((vh - top) / (vh - vh * endOffset));
      setProgress((prev) => (Math.abs(prev - next) < 0.001 ? prev : next));
    };
    const onScroll = () => {
      if (!frame) frame = requestAnimationFrame(measure);
    };
    measure();
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onScroll);
    return () => {
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", onScroll);
      if (frame) cancelAnimationFrame(frame);
    };
  }, [endOffset]);

  return [ref, reduced ? 1 : progress] as const;
}
