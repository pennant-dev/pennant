// From json-render (Apache-2.0), examples/chat/lib/render/registry.tsx at the commit in ../SOURCE_COMMIT.
// Pennant's changes: the 3D components are gone; charts can draw without animating.
"use client";

import { useState, type ReactNode } from "react";
import { useBoundProp, defineRegistry } from "@json-render/react";
import { shadcnComponents } from "@json-render/shadcn";
import {
  Bar,
  BarChart as RechartsBarChart,
  CartesianGrid,
  Legend,
  Line,
  LineChart as RechartsLineChart,
  Pie,
  PieChart as RechartsPieChart,
  XAxis,
} from "recharts";
import {
  ChartContainer,
  ChartTooltip,
  ChartTooltipContent,
  type ChartConfig,
} from "@/components/ui/chart";

import {
  Table,
  TableHeader,
  TableBody,
  TableHead,
  TableRow,
  TableCell,
} from "@/components/ui/table";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import {
  TrendingUp,
  TrendingDown,
  Minus,
  Info,
  Lightbulb,
  AlertTriangle,
  Star,
  ArrowUpDown,
  ArrowUp,
  ArrowDown,
} from "lucide-react";

import { explorerCatalog } from "./catalog";

// Pennant: charts draw at once when the card is drawn off screen (a picture of it), where nothing animates.
const animated = () => !(globalThis as { pennantStill?: boolean }).pennantStill;

// =============================================================================
// Registry
// =============================================================================

export const { registry, handlers } = defineRegistry(explorerCatalog, {
  components: {
    // From @json-render/shadcn (used as-is)
    Stack: shadcnComponents.Stack,
    Card: shadcnComponents.Card,
    Grid: shadcnComponents.Grid,
    Heading: shadcnComponents.Heading,
    Separator: shadcnComponents.Separator,
    Accordion: shadcnComponents.Accordion,
    Progress: shadcnComponents.Progress,
    Skeleton: shadcnComponents.Skeleton,
    Badge: shadcnComponents.Badge,
    Alert: shadcnComponents.Alert,

    // Chat-specific components
    Text: ({ props }) => (
      <p className={props.muted ? "text-muted-foreground" : ""}>
        {props.content}
      </p>
    ),

    Metric: ({ props }) => {
      const TrendIcon =
        props.trend === "up"
          ? TrendingUp
          : props.trend === "down"
            ? TrendingDown
            : Minus;
      const trendColor =
        props.trend === "up"
          ? "text-green-500"
          : props.trend === "down"
            ? "text-red-500"
            : "text-muted-foreground";
      return (
        <div className="flex flex-col gap-1">
          <p className="text-sm text-muted-foreground">{props.label}</p>
          <div className="flex items-center gap-2">
            <span className="text-2xl font-bold">{props.value}</span>
            {props.trend && <TrendIcon className={`h-4 w-4 ${trendColor}`} />}
          </div>
          {props.detail && (
            <p className="text-xs text-muted-foreground">{props.detail}</p>
          )}
        </div>
      );
    },

    Table: ({ props }) => {
      const rawData = props.data;
      const items: Array<Record<string, unknown>> = Array.isArray(rawData)
        ? rawData
        : Array.isArray((rawData as Record<string, unknown>)?.data)
          ? ((rawData as Record<string, unknown>).data as Array<
              Record<string, unknown>
            >)
          : [];

      const [sortKey, setSortKey] = useState<string | null>(null);
      const [sortDir, setSortDir] = useState<"asc" | "desc">("asc");

      if (items.length === 0) {
        return (
          <div className="text-center py-4 text-muted-foreground">
            {props.emptyMessage ?? "No data"}
          </div>
        );
      }

      const sorted = sortKey
        ? [...items].sort((a, b) => {
            const av = a[sortKey];
            const bv = b[sortKey];
            // numeric comparison when both values are numbers
            if (typeof av === "number" && typeof bv === "number") {
              return sortDir === "asc" ? av - bv : bv - av;
            }
            const as = String(av ?? "");
            const bs = String(bv ?? "");
            return sortDir === "asc"
              ? as.localeCompare(bs)
              : bs.localeCompare(as);
          })
        : items;

      const handleSort = (key: string) => {
        if (sortKey === key) {
          setSortDir((d) => (d === "asc" ? "desc" : "asc"));
        } else {
          setSortKey(key);
          setSortDir("asc");
        }
      };

      return (
        <Table>
          <TableHeader>
            <TableRow>
              {props.columns.map((col) => {
                const SortIcon =
                  sortKey === col.key
                    ? sortDir === "asc"
                      ? ArrowUp
                      : ArrowDown
                    : ArrowUpDown;
                return (
                  <TableHead key={col.key}>
                    <button
                      type="button"
                      className="inline-flex items-center gap-1 hover:text-foreground transition-colors"
                      onClick={() => handleSort(col.key)}
                    >
                      {col.label}
                      <SortIcon className="h-3 w-3 text-muted-foreground" />
                    </button>
                  </TableHead>
                );
              })}
            </TableRow>
          </TableHeader>
          <TableBody>
            {sorted.map((item, i) => (
              <TableRow key={i}>
                {props.columns.map((col) => (
                  <TableCell key={col.key}>
                    {String(item[col.key] ?? "")}
                  </TableCell>
                ))}
              </TableRow>
            ))}
          </TableBody>
        </Table>
      );
    },

    Link: ({ props }) => (
      <a
        href={props.href}
        target="_blank"
        rel="noopener noreferrer"
        className="text-primary underline underline-offset-4 hover:text-primary/80"
      >
        {props.text}
      </a>
    ),

    BarChart: ({ props }) => {
      const rawData = props.data;
      const rawItems: Array<Record<string, unknown>> = Array.isArray(rawData)
        ? rawData
        : Array.isArray((rawData as Record<string, unknown>)?.data)
          ? ((rawData as Record<string, unknown>).data as Array<
              Record<string, unknown>
            >)
          : [];

      const { items, valueKey } = processChartData(
        rawItems,
        props.xKey,
        props.yKey,
        props.aggregate,
      );

      const chartColor = props.color ?? "var(--chart-1)";

      const chartConfig = {
        [valueKey]: {
          label: valueKey,
          color: chartColor,
        },
      } satisfies ChartConfig;

      if (items.length === 0) {
        return (
          <div className="text-center py-4 text-muted-foreground">
            No data available
          </div>
        );
      }

      return (
        <div className="w-full">
          {props.title && (
            <p className="text-sm font-medium mb-2">{props.title}</p>
          )}
          <ChartContainer
            config={chartConfig}
            className="min-h-[200px] w-full"
            style={{ height: props.height ?? 300 }}
          >
            <RechartsBarChart accessibilityLayer data={items}>
              <CartesianGrid vertical={false} />
              <XAxis
                dataKey="label"
                tickLine={false}
                tickMargin={10}
                axisLine={false}
              />
              <ChartTooltip content={<ChartTooltipContent />} />
              <Bar
                isAnimationActive={animated()}
                dataKey={valueKey}
                fill={`var(--color-${valueKey})`}
                radius={4}
              />
            </RechartsBarChart>
          </ChartContainer>
        </div>
      );
    },

    LineChart: ({ props }) => {
      const rawData = props.data;
      const rawItems: Array<Record<string, unknown>> = Array.isArray(rawData)
        ? rawData
        : Array.isArray((rawData as Record<string, unknown>)?.data)
          ? ((rawData as Record<string, unknown>).data as Array<
              Record<string, unknown>
            >)
          : [];

      const { items, valueKey } = processChartData(
        rawItems,
        props.xKey,
        props.yKey,
        props.aggregate,
      );

      const chartColor = props.color ?? "var(--chart-1)";

      const chartConfig = {
        [valueKey]: {
          label: valueKey,
          color: chartColor,
        },
      } satisfies ChartConfig;

      if (items.length === 0) {
        return (
          <div className="text-center py-4 text-muted-foreground">
            No data available
          </div>
        );
      }

      return (
        <div className="w-full">
          {props.title && (
            <p className="text-sm font-medium mb-2">{props.title}</p>
          )}
          <ChartContainer
            config={chartConfig}
            className="min-h-[200px] w-full [&_svg]:overflow-visible"
            style={{ height: props.height ?? 300 }}
          >
            <RechartsLineChart accessibilityLayer data={items}>
              <CartesianGrid vertical={false} />
              <XAxis
                dataKey="label"
                tickLine={false}
                tickMargin={10}
                axisLine={false}
                interval={
                  items.length > 12
                    ? Math.ceil(items.length / 8) - 1
                    : undefined
                }
              />
              <ChartTooltip content={<ChartTooltipContent />} />
              <Line
                isAnimationActive={animated()}
                type="monotone"
                dataKey={valueKey}
                stroke={`var(--color-${valueKey})`}
                strokeWidth={2}
                dot={false}
              />
            </RechartsLineChart>
          </ChartContainer>
        </div>
      );
    },

    Tabs: ({ props, children }) => (
      <Tabs defaultValue={props.defaultValue ?? (props.tabs ?? [])[0]?.value}>
        <TabsList>
          {(props.tabs ?? []).map((tab) => (
            <TabsTrigger key={tab.value} value={tab.value}>
              {tab.label}
            </TabsTrigger>
          ))}
        </TabsList>
        {children}
      </Tabs>
    ),

    TabContent: ({ props, children }) => (
      <TabsContent value={props.value}>{children}</TabsContent>
    ),

    Callout: ({ props }) => {
      const config = {
        info: {
          icon: Info,
          border: "border-l-blue-500",
          bg: "bg-blue-500/5",
          iconColor: "text-blue-500",
        },
        tip: {
          icon: Lightbulb,
          border: "border-l-emerald-500",
          bg: "bg-emerald-500/5",
          iconColor: "text-emerald-500",
        },
        warning: {
          icon: AlertTriangle,
          border: "border-l-amber-500",
          bg: "bg-amber-500/5",
          iconColor: "text-amber-500",
        },
        important: {
          icon: Star,
          border: "border-l-purple-500",
          bg: "bg-purple-500/5",
          iconColor: "text-purple-500",
        },
      }[props.type ?? "info"] ?? {
        icon: Info,
        border: "border-l-blue-500",
        bg: "bg-blue-500/5",
        iconColor: "text-blue-500",
      };
      const Icon = config.icon;
      return (
        <div
          className={`border-l-4 ${config.border} ${config.bg} rounded-r-lg p-4`}
        >
          <div className="flex items-start gap-3">
            <Icon className={`h-5 w-5 mt-0.5 shrink-0 ${config.iconColor}`} />
            <div className="flex-1 min-w-0">
              {props.title && (
                <p className="font-semibold text-sm mb-1">{props.title}</p>
              )}
              <p className="text-sm text-muted-foreground">{props.content}</p>
            </div>
          </div>
        </div>
      );
    },

    Timeline: ({ props }) => (
      <div className="relative pl-8">
        {/* Vertical line centered on dots: dot is 12px wide starting at 0px, center = 6px */}
        <div className="absolute left-[5.5px] top-3 bottom-3 w-px bg-border" />
        <div className="flex flex-col gap-6">
          {(props.items ?? []).map((item, i) => {
            const dotColor =
              item.status === "completed"
                ? "bg-emerald-500"
                : item.status === "current"
                  ? "bg-blue-500"
                  : "bg-muted-foreground/30";
            return (
              <div key={i} className="relative">
                <div
                  className={`absolute -left-8 top-0.5 h-3 w-3 rounded-full ${dotColor} ring-2 ring-background`}
                />
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2 flex-wrap">
                    <p className="font-medium text-sm">{item.title}</p>
                    {item.date && (
                      <span className="text-xs text-muted-foreground bg-muted px-1.5 py-0.5 rounded">
                        {item.date}
                      </span>
                    )}
                  </div>
                  {item.description && (
                    <p className="text-sm text-muted-foreground mt-1">
                      {item.description}
                    </p>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      </div>
    ),

    PieChart: ({ props }) => {
      const rawData = props.data;
      const items: Array<Record<string, unknown>> = Array.isArray(rawData)
        ? rawData
        : Array.isArray((rawData as Record<string, unknown>)?.data)
          ? ((rawData as Record<string, unknown>).data as Array<
              Record<string, unknown>
            >)
          : [];

      if (items.length === 0) {
        return (
          <div className="text-center py-4 text-muted-foreground">
            No data available
          </div>
        );
      }

      const chartConfig: ChartConfig = {};
      items.forEach((item, i) => {
        const name = String(item[props.nameKey] ?? `Segment ${i + 1}`);
        chartConfig[name] = {
          label: name,
          color: PIE_COLORS[i % PIE_COLORS.length],
        };
      });

      return (
        <div className="w-full">
          {props.title && (
            <p className="text-sm font-medium mb-2">{props.title}</p>
          )}
          <ChartContainer
            config={chartConfig}
            className="mx-auto aspect-square w-full"
            style={{ height: props.height ?? 300 }}
          >
            <RechartsPieChart>
              <ChartTooltip content={<ChartTooltipContent />} />
              <Pie
                isAnimationActive={animated()}
                data={items.map((item, i) => ({
                  name: String(item[props.nameKey] ?? `Segment ${i + 1}`),
                  value:
                    typeof item[props.valueKey] === "number"
                      ? item[props.valueKey]
                      : parseFloat(String(item[props.valueKey])) || 0,
                  fill: PIE_COLORS[i % PIE_COLORS.length],
                }))}
                dataKey="value"
                nameKey="name"
                innerRadius="40%"
                outerRadius="70%"
                paddingAngle={2}
              />
              <Legend />
            </RechartsPieChart>
          </ChartContainer>
        </div>
      );
    },

    RadioGroup: ({ props, bindings }) => {
      const [value, setValue] = useBoundProp<string>(
        props.value as string | undefined,
        bindings?.value,
      );
      const current = value ?? "";

      return (
        <div className="flex flex-col gap-2">
          {props.label && (
            <Label className="text-sm font-medium">{props.label}</Label>
          )}
          <RadioGroup
            value={current}
            onValueChange={(v: string) => setValue(v)}
          >
            {(props.options ?? []).map((opt) => (
              <div key={opt.value} className="flex items-center gap-2">
                <RadioGroupItem value={opt.value} id={`rg-${opt.value}`} />
                <Label
                  htmlFor={`rg-${opt.value}`}
                  className="font-normal cursor-pointer"
                >
                  {opt.label}
                </Label>
              </div>
            ))}
          </RadioGroup>
        </div>
      );
    },

    SelectInput: ({ props, bindings }) => {
      const [value, setValue] = useBoundProp<string>(
        props.value as string | undefined,
        bindings?.value,
      );
      const current = value ?? "";

      return (
        <div className="flex flex-col gap-2">
          {props.label && (
            <Label className="text-sm font-medium">{props.label}</Label>
          )}
          <Select value={current} onValueChange={(v: string) => setValue(v)}>
            <SelectTrigger>
              <SelectValue placeholder={props.placeholder ?? "Select..."} />
            </SelectTrigger>
            <SelectContent>
              {(props.options ?? []).map((opt) => (
                <SelectItem key={opt.value} value={opt.value}>
                  {opt.label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      );
    },

    TextInput: ({ props, bindings }) => {
      const [value, setValue] = useBoundProp<string>(
        props.value as string | undefined,
        bindings?.value,
      );
      const current = value ?? "";

      return (
        <div className="flex flex-col gap-2">
          {props.label && (
            <Label className="text-sm font-medium">{props.label}</Label>
          )}
          <Input
            type={props.type ?? "text"}
            placeholder={props.placeholder ?? ""}
            value={current}
            onChange={(e) => setValue(e.target.value)}
          />
        </div>
      );
    },

    Button: ({ props, emit }) => (
      <Button
        variant={props.variant ?? "default"}
        size={props.size ?? "default"}
        disabled={props.disabled ?? false}
        onClick={() => emit("press")}
      >
        {props.label}
      </Button>
    ),

  },
});

// =============================================================================
// Chart Helpers
// =============================================================================

const PIE_COLORS = [
  "var(--chart-1)",
  "var(--chart-2)",
  "var(--chart-3)",
  "var(--chart-4)",
  "var(--chart-5)",
];

function processChartData(
  items: Array<Record<string, unknown>>,
  xKey: string,
  yKey: string,
  aggregate: "sum" | "count" | "avg" | null | undefined,
): { items: Array<Record<string, unknown>>; valueKey: string } {
  if (items.length === 0) {
    return { items: [], valueKey: yKey };
  }

  if (!aggregate) {
    const formatted = items.map((item) => ({
      ...item,
      label: String(item[xKey] ?? ""),
    }));
    return { items: formatted, valueKey: yKey };
  }

  const groups = new Map<string, Array<Record<string, unknown>>>();

  for (const item of items) {
    const groupKey = String(item[xKey] ?? "unknown");
    const group = groups.get(groupKey) ?? [];
    group.push(item);
    groups.set(groupKey, group);
  }

  const valueKey = aggregate === "count" ? "count" : yKey;
  const aggregated: Array<Record<string, unknown>> = [];
  const sortedKeys = Array.from(groups.keys()).sort();

  for (const key of sortedKeys) {
    const group = groups.get(key)!;
    let value: number;

    if (aggregate === "count") {
      value = group.length;
    } else if (aggregate === "sum") {
      value = group.reduce((sum, item) => {
        const v = item[yKey];
        return sum + (typeof v === "number" ? v : parseFloat(String(v)) || 0);
      }, 0);
    } else {
      const sum = group.reduce((s, item) => {
        const v = item[yKey];
        return s + (typeof v === "number" ? v : parseFloat(String(v)) || 0);
      }, 0);
      value = group.length > 0 ? sum / group.length : 0;
    }

    aggregated.push({ label: key, [valueKey]: value });
  }

  return { items: aggregated, valueKey };
}

// =============================================================================
// Fallback Component
// =============================================================================

export function Fallback({ type }: { type: string }) {
  return (
    <div className="p-4 border border-dashed rounded-lg text-muted-foreground text-sm">
      Unknown component: {type}
    </div>
  );
}
