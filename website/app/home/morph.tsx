"use client";

import { useEffect, useRef } from "react";
import { clamp, range } from "./motion";

/* ------------------------------------------------------------------ */
/*  MorphLayer — pieces of one section drop to form the next one      */
/* ------------------------------------------------------------------ */

/**
 * A hand-off between two sections. Elements tagged `data-morph={from}` are
 * cloned into a fixed overlay and fall, with a bounce, onto the elements
 * tagged `data-morph={to}`. Progress runs from 0 when the `section` (by id)
 * peeks over the bottom of the viewport to 1 when it reaches the top.
 *
 * With `startAt`, the real elements stay live (a marquee keeps looping)
 * until progress reaches it, and only then break off and drop. With `blank`,
 * each piece sheds its content into a plain rounded rect while it falls and
 * only turns into the target card as it lands; its corners ease from the
 * source's radius to the target's (`data-morph-round` targets end as circles).
 */
export type MorphTransition = {
  from: string;
  to: string;
  section: string;
  startAt?: number;
  /** Viewport heights of scroll the hand-off runs over (default 1). */
  span?: number;
  /** Share of the hand-off each piece spends falling (default 0.6). */
  flight?: number;
  /** `drop` falls with gravity, bounce and tumble; `glide` eases straight in. */
  path?: "drop" | "glide";
  blank?: boolean;
};

type Styled = Element & ElementCSSInlineStyle;

type Snapshot = { node: HTMLElement | SVGSVGElement; width: number; height: number };

type Piece = {
  source: Element;
  target: Element;
  root: HTMLDivElement;
  from: Snapshot;
  to: Snapshot;
  blank: Blank | null;
  start: number;
  spin: number;
};

type Blank = { node: HTMLDivElement; from: number; to: number };

type ActiveMorph = {
  transition: MorphTransition;
  pieces: Piece[];
  sources: Styled[];
  targets: Styled[];
  paused: Animation[];
};

const flightOf = (transition: MorphTransition) => transition.flight ?? 0.6;

const lerp = (a: number, b: number, t: number) => a + (b - a) * t;

const easeInOut = (t: number) =>
  t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;

/** Starts quadratic like gravity, then settles with two small bounces. */
const easeOutBounce = (t: number) => {
  const n = 7.5625;
  const d = 2.75;
  if (t < 1 / d) return n * t * t;
  if (t < 2 / d) return n * (t -= 1.5 / d) * t + 0.75;
  if (t < 2.5 / d) return n * (t -= 2.25 / d) * t + 0.9375;
  return n * (t -= 2.625 / d) * t + 0.984375;
};

/** Freezes an element into a detached visual that can be scaled freely. */
function snapshot(el: Element): Snapshot {
  if (el instanceof SVGGraphicsElement && !(el instanceof SVGSVGElement)) {
    const box = el.getBBox();
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", `${box.x} ${box.y} ${box.width} ${box.height}`);
    svg.setAttribute("width", `${box.width}`);
    svg.setAttribute("height", `${box.height}`);
    svg.style.overflow = "visible";
    svg.append(clean(el.cloneNode(true) as Element));
    place(svg);
    return { node: svg, width: box.width || 1, height: box.height || 1 };
  }

  const html = el as HTMLElement;
  const width = html.offsetWidth || 1;
  const height = html.offsetHeight || 1;
  const node = clean(html.cloneNode(true) as Element) as HTMLElement;
  node.style.width = `${width}px`;
  node.style.height = `${height}px`;
  node.style.boxSizing = "border-box";
  node.style.margin = "0";
  place(node);
  return { node, width, height };
}

function place(node: HTMLElement | SVGSVGElement) {
  node.style.position = "absolute";
  node.style.left = "0";
  node.style.top = "0";
  node.style.transformOrigin = "0 0";
  node.style.transition = "none";
}

/** Corner radius in px; `Infinity` for elements that should end as circles. */
function cornerRadius(el: Element) {
  if (el.hasAttribute("data-morph-round")) return Infinity;
  if (!(el instanceof HTMLElement)) return 16;
  return parseFloat(getComputedStyle(el).borderTopLeftRadius) || 16;
}

/** A content-free rect, sized to the piece, that morphs between corner radii. */
function blankRect(source: Element, target: Element): Blank {
  const node = document.createElement("div");
  node.className = "morph-blank";
  node.style.opacity = "0";
  return { node, from: cornerRadius(source), to: cornerRadius(target) };
}

/** Drops morph tags, reveal state and running animations from a clone. */
function clean(node: Element) {
  for (const el of [node, ...node.querySelectorAll("*")]) {
    el.removeAttribute("data-morph");
    el.classList.remove("reveal");
    const style = (el as Styled).style;
    if (!style) continue;
    style.removeProperty("--morph-in");
    style.removeProperty("--morph-out");
    style.animation = "none";
  }
  const root = (node as Styled).style;
  if (root) {
    root.transform = "none";
    root.opacity = "1";
  }
  return node;
}

/**
 * Pauses running animations on the sources' ancestors (a looping marquee)
 * while they are hidden, so their positions hold still under the pieces and
 * the loop can't jump back mid-flight. Returned animations resume on teardown.
 */
function pauseAncestors(sources: Element[]) {
  const paused = new Set<Animation>();
  for (const source of sources) {
    for (let el = source.parentElement; el && el !== document.body; el = el.parentElement) {
      for (const animation of el.getAnimations()) {
        if (animation.playState !== "running") continue;
        animation.pause();
        paused.add(animation);
      }
    }
  }
  return [...paused];
}

function group(name: string) {
  return [...document.querySelectorAll<Element>(`[data-morph="${name}"]`)] as Styled[];
}

function onScreen(el: Element, vw: number, vh: number) {
  const r = el.getBoundingClientRect();
  return r.width > 0 && r.height > 0 && r.right > 0 && r.left < vw && r.bottom > 0 && r.top < vh;
}

export function MorphLayer({ transitions }: { transitions: MorphTransition[] }) {
  const layerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const layer = layerRef.current;
    if (!layer) return;
    const media = window.matchMedia("(prefers-reduced-motion: reduce)");
    const active = new Map<number, ActiveMorph>();
    let frame = 0;

    const teardown = (index: number) => {
      const morph = active.get(index);
      if (!morph) return;
      morph.pieces.forEach((piece) => piece.root.remove());
      morph.sources.forEach((el) => el.style.removeProperty("--morph-out"));
      morph.targets.forEach((el) => el.style.removeProperty("--morph-in"));
      morph.paused.forEach((animation) => animation.play());
      active.delete(index);
    };

    const build = (transition: MorphTransition): ActiveMorph | null => {
      const vw = window.innerWidth;
      const vh = window.innerHeight;
      const allSources = group(transition.from);
      const allTargets = group(transition.to);
      const sources = allSources.filter((el) => onScreen(el, vw, vh));
      const targets = allTargets.filter((el) => {
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
      });
      if (!sources.length || !targets.length) return null;

      const count = Math.max(sources.length, targets.length);
      const pieces = Array.from({ length: count }, (_, k): Piece => {
        const source = sources[k % sources.length];
        const target = targets[k % targets.length];
        const from = snapshot(source);
        const to = snapshot(target);
        const root = document.createElement("div");
        root.className = "morph-piece";
        root.append(from.node, to.node);
        const blank = transition.blank ? blankRect(source, target) : null;
        if (blank) root.append(blank.node);
        layer.append(root);
        return {
          source,
          target,
          root,
          from,
          to,
          blank,
          start: count > 1 ? (k / (count - 1)) * (0.9 - flightOf(transition)) : 0.05,
          spin: (k % 2 ? 1 : -1) * (10 + ((k * 7) % 14)),
        };
      });

      allSources.forEach((el) => el.style.setProperty("--morph-out", "0"));
      allTargets.forEach((el) => el.style.setProperty("--morph-in", "0"));
      return {
        transition,
        pieces,
        sources: allSources,
        targets: allTargets,
        paused: pauseAncestors(sources),
      };
    };

    const render = (morph: ActiveMorph, t: number) => {
      const drop = range(t, morph.transition.startAt ?? 0, 1);
      for (const piece of morph.pieces) {
        const u = range(drop, piece.start, piece.start + flightOf(morph.transition));
        const a = piece.source.getBoundingClientRect();
        const b = piece.target.getBoundingClientRect();
        const glide = easeInOut(u);
        const x = lerp(a.left, b.left, glide);
        const gliding = morph.transition.path === "glide";
        const y = lerp(a.top, b.top, gliding ? glide : easeOutBounce(u));
        const w = lerp(a.width, b.width, glide);
        const h = lerp(a.height, b.height, glide);
        // Plain morph: cross-fade mid-flight. Blank morph: content → rect → card.
        const shed = piece.blank ? range(u, 0, 0.25) : range(u, 0.3, 0.7);
        const land = piece.blank ? range(u, 0.8, 1) : shed;

        piece.root.style.width = `${w}px`;
        piece.root.style.height = `${h}px`;
        piece.root.style.transform = `translate3d(${x}px, ${y}px, 0) rotate(${gliding ? 0 : piece.spin * Math.sin(Math.PI * u)}deg)`;
        piece.from.node.style.transform = `scale(${w / piece.from.width}, ${h / piece.from.height})`;
        piece.from.node.style.opacity = `${1 - shed}`;
        piece.to.node.style.transform = `scale(${w / piece.to.width}, ${h / piece.to.height})`;
        piece.to.node.style.opacity = `${land}`;
        if (piece.blank) {
          const half = Math.min(w, h) / 2;
          const from = Math.min(piece.blank.from, half);
          const to = Math.min(piece.blank.to, half);
          piece.blank.node.style.opacity = `${shed * (1 - land)}`;
          piece.blank.node.style.borderRadius = `${lerp(from, to, glide)}px`;
        }
      }
    };

    const measure = () => {
      frame = 0;
      if (media.matches) {
        [...active.keys()].forEach(teardown);
        return;
      }
      const vh = window.innerHeight;
      transitions.forEach((transition, index) => {
        const section = document.getElementById(transition.section);
        if (!section) return;
        const span = transition.span ?? 1;
        const t = clamp((vh - section.getBoundingClientRect().top) / (vh * span));
        if (t <= (transition.startAt ?? 0) || t >= 1) {
          teardown(index);
          return;
        }
        let morph = active.get(index);
        if (!morph) {
          const built = build(transition);
          if (!built) return;
          morph = built;
          active.set(index, morph);
        }
        render(morph, t);
      });
    };

    const schedule = () => {
      if (!frame) frame = requestAnimationFrame(measure);
    };

    measure();
    window.addEventListener("scroll", schedule, { passive: true });
    window.addEventListener("resize", schedule);
    media.addEventListener("change", schedule);
    return () => {
      window.removeEventListener("scroll", schedule);
      window.removeEventListener("resize", schedule);
      media.removeEventListener("change", schedule);
      if (frame) cancelAnimationFrame(frame);
      [...active.keys()].forEach(teardown);
    };
  }, [transitions]);

  return <div ref={layerRef} aria-hidden="true" className="morph-layer" />;
}
