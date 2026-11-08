// The page the Mac and iPhone apps load for a card: json-render draws a spec with the chat example's components
// (shadcn/ui), in Pennant's colours. The app talks to it through `window.PennantCards` and hears back on the
// `pennant` message handler: the card's height, a tap's action, a link to open.
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { Component, type ReactNode } from "react";
import { ActionProvider, Renderer, StateProvider, VisibilityProvider, type ComponentRenderer, type Spec } from "@json-render/react";
import { registry, Fallback } from "./vendor/render/registry";

type Message = { type: "height"; value: number } | { type: "action"; name: string; params: Record<string, unknown> } | { type: "error"; message: string };

function post(message: Message) {
  const handler = (window as any).webkit?.messageHandlers?.pennant;
  if (handler) handler.postMessage(message);
  else console.log("pennant", JSON.stringify(message));
}

const fallback: ComponentRenderer = ({ element }) => <Fallback type={element.type} />;

/** A part the renderer can't draw shows the rest of the card instead of a blank one. */
class Guard extends Component<{ children: ReactNode }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  componentDidCatch(error: unknown) { post({ type: "error", message: String(error) }); }
  render() { return this.state.failed ? <p className="text-sm text-muted-foreground">This card couldn't be drawn.</p> : this.props.children; }
}

function Card({ spec, loading }: { spec: Spec; loading: boolean }) {
  const handlers = {
    reply: async (params: Record<string, unknown>) => post({ type: "action", name: "reply", params }),
    open: async (params: Record<string, unknown>) => post({ type: "action", name: "open", params }),
  };
  return (
    <StateProvider initialState={(spec as any).state ?? {}}>
      <VisibilityProvider>
        <ActionProvider handlers={handlers}>
          <Guard>
            <Renderer spec={spec} registry={registry} fallback={fallback} loading={loading} />
          </Guard>
        </ActionProvider>
      </VisibilityProvider>
    </StateProvider>
  );
}

let root: Root | null = null;
const container = document.getElementById("card")!;

// Links open in the owner's browser, never inside the card.
document.addEventListener("click", (event) => {
  const link = (event.target as HTMLElement | null)?.closest("a[href]") as HTMLAnchorElement | null;
  if (!link) return;
  event.preventDefault();
  post({ type: "action", name: "open", params: { url: link.href } });
}, true);

new ResizeObserver(() => post({ type: "height", value: Math.ceil(container.getBoundingClientRect().height) })).observe(container);

(window as any).PennantCards = {
  /** Draws a spec; `loading` while it's still streaming in. */
  render(spec: Spec, loading = false) {
    root ??= createRoot(container);
    root.render(<Card spec={spec} loading={loading} />);
  },
  /** Draws a spec for a picture of it: no animation, and the card's height once it stops changing (charts size
   *  themselves a moment after they mount). */
  async draw(spec: Spec, options: { dark: boolean; fontSize: number }): Promise<number> {
    (window as any).PennantCards.setAppearance({ ...options, still: true });
    root ??= createRoot(container);
    flushSync(() => root!.render(<Card spec={spec} loading={false} />));
    const height = () => Math.ceil(container.getBoundingClientRect().height);
    let last = -1;
    for (let i = 0; i < 30; i++) {
      await new Promise((r) => setTimeout(r, 50));
      const now = height();
      if (now === last && now > 0) break;
      last = now;
    }
    return height();
  },
  /** Light or dark, the text size and the accent, from the app's theme; `still`: nothing animates (a picture, or
   *  the live card that takes a picture's place). */
  setAppearance(options: { dark?: boolean; fontSize?: number; accent?: string; still?: boolean }) {
    const html = document.documentElement;
    if (options.still !== undefined) {
      (globalThis as { pennantStill?: boolean }).pennantStill = options.still;
      html.classList.toggle("still", options.still);
    }
    if (options.dark !== undefined) html.classList.toggle("dark", options.dark);
    if (options.fontSize) html.style.fontSize = `${options.fontSize}px`;
    if (options.accent) html.style.setProperty("--pennant-accent", options.accent);
  },
};
post({ type: "height", value: 0 });
