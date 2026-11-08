// What Pennant's host needs from the catalog, written into Swift by build.mjs: the components the model may use, each
// as json-render's own one-line prompt description, and each one's props as JSON Schema for checking a card.
import { explorerCatalog } from "./vendor/render/catalog";

/** Left out of Pennant's cards: form inputs (a posted card has nowhere to send them) and loading placeholders. */
const leftOut = new Set(["Skeleton", "RadioGroup", "SelectInput", "TextInput"]);

const catalog = explorerCatalog as any;
const components = catalog.data.components as Record<string, { props: any; slots?: string[]; description?: string }>;
const actions = catalog.data.actions as Record<string, { description?: string }>;

// json-render's own words for each component: the "AVAILABLE COMPONENTS" lines of catalog.prompt().
const prompt: string = catalog.prompt();
const lines = new Map<string, string>();
for (const line of prompt.split("\n")) {
  const m = line.match(/^- (\w+): (.*)$/);
  if (!m || !components[m[1]]) continue;
  const text = m[2]
    .replace(/,? ?className\?: string/, "")
    // Pennant's cards carry their data in the props, and a button's press replies or opens a link.
    .replace(/ Use \{ "\$state": "\/path" \} to bind read-only data( from state)?\./, "")
    .replace(/ Use with on\.press to trigger actions like setState.*$/, " Give it on.press with the reply or open action.");
  lines.set(m[1], text);
}

const out = {
  components: Object.fromEntries(
    Object.entries(components)
      .filter(([name]) => !leftOut.has(name))
      .map(([name, def]) => {
        const schema = def.props.toJSONSchema();
        delete schema.$schema;
        delete schema.properties?.className;
        schema.required = (schema.required ?? []).filter((k: string) => k !== "className");
        return [name, { line: lines.get(name) ?? "", children: !!def.slots?.length, props: schema }];
      }),
  ),
  actions: Object.keys(actions),
};
process.stdout.write(JSON.stringify(out));
