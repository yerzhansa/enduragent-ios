import { armRandomUUIDTrap, randomUUIDDraws, RandomUUIDReached, setNow } from "./freeze.mts";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, unlinkSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";
import { parseArgs } from "node:util";
import * as cases from "./cases.mts";
import type { Args, DatedInput, Json, PlanToolName } from "./cases.mts";

type Module = Record<string, any>;
type Tool = { description?: string; inputSchema: unknown; execute: (input: unknown, options: object) => unknown };
type Tools = Record<PlanToolName, Tool>;
type Row = Record<string, Json>;

interface Npm {
  readonly cycling: Module;
  readonly core: Module;
  readonly engine: Module;
  readonly asSchema: (schema: unknown) => { jsonSchema: unknown; validate: (value: unknown) => unknown };
  readonly versions: { readonly ai: string; readonly zod: string };
}

const PINNED = "d192cb974e715e1527645e0acf0d8353ed4d0edc";
const FILE_CAP_BYTES = 4_000_000;
const CLOSURE_ROOTS = ["@enduragent/sport-cycling", "@enduragent/core"];
const WORKSPACE_GROUPS = ["packages", "apps"];
const GENERATOR_FILES = ["run.mjs", "freeze.mts", "generate.mts", "cases.mts"];
const BUILDER_OPTIONS = { id: "fixture", now: "1970-01-01T00:00:00.000Z" };
const EXECUTE_OPTIONS = { toolCallId: "fixture", messages: [] };

const refuse = (reason: string): never => {
  process.stderr.write(`npm-fixtures: ${reason}\n`);
  process.exit(1);
};

const sha256 = (bytes: string | Buffer): string => createHash("sha256").update(bytes).digest("hex");

const byPath = (left: string, right: string): number => (left < right ? -1 : left > right ? 1 : 0);

function readOptions() {
  try {
    const { values } = parseArgs({
      options: {
        npm: { type: "string" },
        out: { type: "string" },
        check: { type: "boolean", default: false },
        corepack: { type: "string" },
        probe: { type: "string" },
      },
      strict: true,
    });
    const npm = values.npm ? resolve(values.npm) : refuse("--npm is required");
    const out = values.out ? resolve(values.out) : refuse("--out is required");
    const corepack = values.corepack ? resolve(values.corepack) : join(dirname(process.execPath), "corepack");
    return { npm, out, check: values.check === true, corepack, probe: values.probe };
  } catch (error) {
    return refuse((error as Error).message);
  }
}

function git(npm: string, ...args: string[]): string {
  const result = spawnSync("git", ["-C", npm, ...args], { encoding: "utf8" });
  if (result.status !== 0) refuse(`git ${args.join(" ")} failed in ${npm}`);
  return result.stdout.trim();
}

function guardRevision(npm: string): void {
  const head = git(npm, "rev-parse", "HEAD");
  if (head !== PINNED) refuse(`the npm checkout is at ${head}, not ${PINNED}`);
}

function guardNoLocalChanges(npm: string): void {
  if (git(npm, "status", "--porcelain") !== "") refuse("the npm checkout has local changes");
}

function buildClosure(npm: string, corepack: string): void {
  const filters = CLOSURE_ROOTS.flatMap((name) => ["--filter", `${name}...`]);
  const result = spawnSync(corepack, ["pnpm", "--dir", npm, ...filters, "run", "build"], {
    encoding: "utf8",
    maxBuffer: 1 << 28,
    env: {
      ...process.env,
      COREPACK_ENABLE_NETWORK: "0",
      PATH: `${dirname(process.execPath)}:${process.env.PATH ?? ""}`,
    },
  });
  if (result.error !== undefined || result.status !== 0) {
    process.stderr.write(`${result.stdout ?? ""}${result.stderr ?? ""}`);
    refuse("the npm build failed");
  }
}

function guardBuildKeptTrackedFiles(npm: string): void {
  if (git(npm, "status", "--porcelain", "--untracked-files=no") !== "") refuse("the npm build changed tracked files");
}

function readJSON(path: string): Module {
  return JSON.parse(readFileSync(path, "utf8"));
}

function workspacePackages(npm: string): Map<string, string> {
  const found = new Map<string, string>();
  for (const group of WORKSPACE_GROUPS) {
    const folder = join(npm, group);
    if (!existsSync(folder)) continue;
    for (const entry of readdirSync(folder).sort(byPath)) {
      const manifest = join(folder, entry, "package.json");
      if (existsSync(manifest)) found.set(readJSON(manifest).name, join(folder, entry));
    }
  }
  return found;
}

function closure(npm: string): Map<string, string> {
  const packages = workspacePackages(npm);
  const reached = new Map<string, string>();
  const pending = [...CLOSURE_ROOTS];
  while (pending.length > 0) {
    const name = pending.shift() as string;
    if (reached.has(name)) continue;
    const folder = packages.get(name) ?? refuse(`the npm workspace has no ${name}`);
    reached.set(name, folder);
    const dependencies: Record<string, string> = readJSON(join(folder, "package.json")).dependencies ?? {};
    for (const [dependency, version] of Object.entries(dependencies)) {
      if (version.startsWith("workspace:")) pending.push(dependency);
    }
  }
  return new Map([...reached].sort(([left], [right]) => byPath(left, right)));
}

function filesUnder(root: string, folder: string = root): string[] {
  return readdirSync(folder, { withFileTypes: true }).flatMap((entry) => {
    const path = join(folder, entry.name);
    return entry.isDirectory() ? filesUnder(root, path) : [relative(root, path).split(sep).join("/")];
  });
}

function distHashes(packages: Map<string, string>): Record<string, Record<string, string>> {
  const hashes: Record<string, Record<string, string>> = {};
  for (const [name, folder] of packages) {
    const dist = join(folder, "dist");
    if (!existsSync(dist)) refuse(`${name} has no dist folder after the build`);
    const files = filesUnder(dist).sort(byPath);
    hashes[name] = Object.fromEntries(files.map((file) => [`dist/${file}`, sha256(readFileSync(join(dist, file)))]));
  }
  return hashes;
}

async function load(location: string, label: string, names: readonly string[]): Promise<Module> {
  let module: Module;
  try {
    module = await import(pathToFileURL(location).href);
  } catch (error) {
    return refuse(`${label} cannot be loaded: ${(error as Error).message}`);
  }
  for (const name of names) if (module[name] === undefined) refuse(`${label} does not export ${name}`);
  return module;
}

async function importNpm(npm: string): Promise<Npm> {
  const cyclingFolder = join(npm, "packages/sport-cycling");
  const requireFromCycling = createRequire(join(cyclingFolder, "package.json"));
  const ai = await load(requireFromCycling.resolve("ai"), "ai", ["asSchema"]);
  const cycling = await load(join(cyclingFolder, "dist/index.js"), "packages/sport-cycling/dist/index.js", [
    "assessGoalFeasibility",
    "computeTotalWeeks",
    "buildPlanSkeleton",
    "getSampleWeek",
    "cyclingSport",
  ]);
  const core = await load(join(npm, "packages/core/dist/index.js"), "packages/core/dist/index.js", [
    "Memory",
    "createProposalSummarizers",
    "createToolConfirmationPort",
  ]);
  const engine = await load(join(npm, "packages/engine/dist/sport.js"), "packages/engine/dist/sport.js", [
    "PlanSaveInputSchema",
    "createMemoryTools",
    "getEffectiveSections",
  ]);
  return {
    cycling,
    core,
    engine,
    asSchema: ai.asSchema,
    versions: {
      ai: requireFromCycling("ai/package.json").version,
      zod: requireFromCycling("zod/package.json").version,
    },
  };
}

function planTools(npm: Npm, memory: unknown): Tools {
  const offered = new Map<string, Tool>(
    npm.cycling.cyclingSport
      .tools({ memory, intervals: null, tz: "UTC" })
      .map((registration: { name: string; tool: Tool }) => [registration.name, registration.tool]),
  );
  const memoryTools = npm.engine.createMemoryTools(memory, npm.engine.getEffectiveSections(npm.cycling.cyclingSport));
  const tools = {
    assess_feasibility: offered.get("assess_feasibility"),
    build_plan_skeleton: offered.get("build_plan_skeleton"),
    get_sample_week: offered.get("get_sample_week"),
    plan_save: memoryTools.plan_save,
    plan_load: memoryTools.plan_load,
  };
  for (const [name, tool] of Object.entries(tools)) if (tool === undefined) refuse(`npm offers no ${name} tool`);
  return tools as Tools;
}

async function verdict(npm: Npm, tool: Tool, input: Json): Promise<{ success: boolean; value?: unknown }> {
  return (await npm.asSchema(tool.inputSchema).validate(input)) as { success: boolean; value?: unknown };
}

async function requireInSchema(npm: Npm, tool: Tool, id: string, input: Json): Promise<void> {
  if (!(await verdict(npm, tool, input)).success) refuse(`case ${id} is outside the tool schema`);
}

function plain(value: unknown): Json {
  return value === undefined ? null : JSON.parse(JSON.stringify(value));
}

async function outcome(run: () => unknown): Promise<{ output: Json } | { thrown: Json }> {
  try {
    return { output: plain(await run()) };
  } catch (error) {
    if (error instanceof RandomUUIDReached) return refuse(error.message);
    const { name, message } = error as Error;
    return { thrown: { name, message } };
  }
}

function caseId(file: string, index: number): string {
  return `${file}/${String(index + 1).padStart(4, "0")}`;
}

function dayOf(instant: string, timeZone: string): string {
  setNow(instant);
  const format = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" });
  return format.format(new Date());
}

function weekdayOf(instant: string, timeZone: string): string {
  setNow(instant);
  return new Intl.DateTimeFormat("en-US", { timeZone, weekday: "short" }).format(new Date()).toLowerCase();
}

async function feasibilityRows(npm: Npm, tools: Tools): Promise<Row[]> {
  const rows: Row[] = [];
  for (const [index, input] of cases.feasibility().entries()) {
    const id = caseId("feasibility", index);
    await requireInSchema(npm, tools.assess_feasibility, id, input);
    rows.push({ id, input, ...(await outcome(() => npm.cycling.assessGoalFeasibility(input))) });
  }
  return rows;
}

async function datedRows(
  npm: Npm,
  file: string,
  tool: Tool,
  entries: readonly DatedInput[],
  run: (input: Args, timeZone: string) => unknown,
): Promise<Row[]> {
  const rows: Row[] = [];
  for (const [index, { instant, timeZone, input }] of entries.entries()) {
    const id = caseId(file, index);
    await requireInSchema(npm, tool, id, input);
    const today = dayOf(instant, timeZone);
    const weekday = weekdayOf(instant, timeZone);
    setNow(instant);
    rows.push({ id, input, instant, timeZone, today, weekday, ...(await outcome(() => run(input, timeZone))) });
  }
  return rows;
}

function totalWeeksRows(npm: Npm, tools: Tools): Promise<Row[]> {
  return datedRows(npm, "total-weeks", tools.build_plan_skeleton, cases.totalWeeks(dayOf), (input, timeZone) =>
    npm.cycling.computeTotalWeeks({ ...input, needsExtraRecovery: false }, timeZone),
  );
}

function planDraftRows(npm: Npm, tools: Tools): Promise<Row[]> {
  return datedRows(npm, "plan-draft", tools.build_plan_skeleton, cases.planDraft(dayOf), (input, timeZone) =>
    npm.cycling.buildPlanSkeleton({ ...input, needsExtraRecovery: false }, timeZone, BUILDER_OPTIONS),
  );
}

function sampleWeekCall(npm: Npm, input: Args): unknown {
  return npm.cycling.getSampleWeek(
    input.volumeTier,
    input.scheduleType,
    input.availableDays,
    input.keySessionDay,
    input.sessionsPerWeek,
  );
}

async function sampleWeekRows(npm: Npm, tools: Tools): Promise<Row[]> {
  const rows: Row[] = [];
  for (const [index, input] of cases.sampleWeek().entries()) {
    const id = caseId("sample-week", index);
    await requireInSchema(npm, tools.get_sample_week, id, input);
    rows.push({ id, input, ...(await outcome(() => sampleWeekCall(npm, input))) });
  }
  return rows;
}

async function toolInputRows(npm: Npm, tools: Tools): Promise<Row[]> {
  const rows: Row[] = [];
  for (const [index, { tool, input, executes }] of cases.toolInputs().entries()) {
    const id = caseId("tool-inputs", index);
    const parsed = await verdict(npm, tools[tool], input);
    if (!parsed.success) {
      rows.push({ id, tool, input, output: { accepted: false } });
    } else if (!executes) {
      rows.push({ id, tool, input, output: { accepted: true } });
    } else {
      const ran = await outcome(() => tools[tool].execute(parsed.value, EXECUTE_OPTIONS));
      rows.push("thrown" in ran ? { id, tool, input, ...ran } : { id, tool, input, output: { accepted: true, result: ran.output } });
    }
  }
  return rows;
}

async function toolSchemaRows(npm: Npm, tools: Tools): Promise<Row[]> {
  const rows: Row[] = [];
  for (const [index, name] of cases.PLAN_TOOLS.entries()) {
    const tool = tools[name];
    const parameters = plain(await npm.asSchema(tool.inputSchema).jsonSchema);
    rows.push({
      id: caseId("tool-schemas", index),
      input: { tool: name },
      output: { name, description: tool.description ?? null, parameters },
    });
  }
  return rows;
}

function freshMemory(npm: Npm, scratch: string): { memory: Module; folder: string } {
  const folder = mkdtempSync(join(scratch, "memory-"));
  return { memory: new npm.core.Memory(folder, "UTC"), folder };
}

async function headlineRows(npm: Npm, scratch: string, drafts: readonly Json[]): Promise<Row[]> {
  const rows: Row[] = [];
  for (const [index, plan] of cases.headline(drafts).entries()) {
    const { memory } = freshMemory(npm, scratch);
    if (plan !== undefined) await memory.savePlan(plan);
    const planLoad = await planTools(npm, memory).plan_load.execute({}, EXECUTE_OPTIONS);
    rows.push({
      id: caseId("headline", index),
      input: plan === undefined ? {} : { plan },
      output: { context: memory.getContext(), planLoad: plain(planLoad) },
    });
  }
  return rows;
}

async function heldPlanSave(npm: Npm, scratch: string, args: unknown): Promise<Row> {
  const { memory, folder } = freshMemory(npm, scratch);
  const planSave = planTools(npm, memory).plan_save;
  let held: (() => Promise<unknown>) | undefined;
  const gate = {
    propose: (_chatId: string, _summary: string, run: () => Promise<unknown>) => {
      held = run;
    },
  };
  const port = npm.core.createToolConfirmationPort({
    gate,
    summarizers: npm.core.createProposalSummarizers({ intervals: null, tz: "UTC" }),
  });
  const pending = await port.propose({
    chatId: "fixture",
    toolName: "plan_save",
    toolInput: args,
    run: async () => planSave.execute(args, EXECUTE_OPTIONS),
  });
  if (held === undefined) return refuse("plan_save was not held for confirmation");
  const result = await held();
  const saved = readFileSync(join(folder, "plans", "current-plan.json"), "utf8");
  return { accepted: true, pending: plain(pending), result: plain(result), saved };
}

async function planObjectRows(npm: Npm, scratch: string, drafts: readonly Json[]): Promise<Row[]> {
  const rows: Row[] = [];
  const schemaTools = planTools(npm, freshMemory(npm, scratch).memory);
  for (const [index, input] of cases.planObject(drafts).entries()) {
    const parsed = await verdict(npm, schemaTools.plan_save, input);
    const output = parsed.success ? await heldPlanSave(npm, scratch, parsed.value) : { accepted: false };
    rows.push({ id: caseId("plan-object", index), input, output });
  }
  return rows;
}

async function runProbe(npm: Npm, tools: Tools, probe: string): Promise<never> {
  if (probe === "random-uuid") {
    await outcome(() => npm.cycling.buildPlanSkeleton({ ...cases.randomUUIDProbe, needsExtraRecovery: false }));
  } else if (probe === "outside-schema") {
    await requireInSchema(npm, tools.get_sample_week, "sample-week/probe", cases.outsideSchemaProbe);
  } else {
    refuse(`there is no probe named ${probe}`);
  }
  return refuse(`the probe ${probe} was not refused`);
}

function render(fn: string, rows: readonly Row[]): string {
  const lines = rows.map((row) => JSON.stringify(row)).join(",\n");
  return `{"npmRevision":"${PINNED}","function":"${fn}","cases":[\n${lines}\n]}\n`;
}

function splitUnderCap(fn: string, rows: readonly Row[]): Row[][] {
  const overhead = Buffer.byteLength(render(fn, []));
  const parts: Row[][] = [[]];
  let size = overhead;
  for (const row of rows) {
    const bytes = Buffer.byteLength(JSON.stringify(row)) + 2;
    if (parts[parts.length - 1].length > 0 && size + bytes >= FILE_CAP_BYTES) {
      parts.push([]);
      size = overhead;
    }
    parts[parts.length - 1].push(row);
    size += bytes;
  }
  return parts;
}

function generatorSHA256(): string {
  return sha256(Buffer.concat(GENERATOR_FILES.map((file) => readFileSync(new URL(file, import.meta.url)))));
}

function countBy(rows: readonly Row[], key: string): Record<string, number> {
  const counts: Record<string, number> = {};
  for (const row of rows) counts[String(row[key])] = (counts[String(row[key])] ?? 0) + 1;
  return counts;
}

function scratchFolder(): string {
  const scratch = mkdtempSync(join(tmpdir(), "npm-fixtures-"));
  process.on("exit", () => rmSync(scratch, { recursive: true, force: true }));
  return scratch;
}

async function fixtures(
  npm: Npm,
  scratch: string,
  dist: Record<string, Record<string, string>>,
): Promise<Map<string, string>> {
  const tools = planTools(npm, freshMemory(npm, scratch).memory);
  const drafts = await planDraftRows(npm, tools);
  const draftPlans = drafts.flatMap((row) => ("output" in row ? [row.output] : []));
  const toolInputs = await toolInputRows(npm, tools);
  const files: [string, string, Row[]][] = [
    ["feasibility", "assessGoalFeasibility", await feasibilityRows(npm, tools)],
    ["total-weeks", "computeTotalWeeks", await totalWeeksRows(npm, tools)],
    ...splitUnderCap("buildPlanSkeleton", drafts).map(
      (part, index): [string, string, Row[]] => [`plan-draft-${index + 1}`, "buildPlanSkeleton", part],
    ),
    ["sample-week", "getSampleWeek", await sampleWeekRows(npm, tools)],
    ["tool-inputs", "toolInputs", toolInputs],
    ["tool-schemas", "toolSchemas", await toolSchemaRows(npm, tools)],
    ["headline", "headline", await headlineRows(npm, scratch, draftPlans.filter((_, index) => index % 1000 === 0))],
    ["plan-object", "planObject", await planObjectRows(npm, scratch, draftPlans.filter((_, index) => index % 100 === 0))],
  ];
  if (randomUUIDDraws() > 0) refuse("a case reached randomUUID");
  const outputs = new Map<string, string>();
  const listed: Record<string, Row> = {};
  for (const [name, fn, rows] of files) {
    const text = render(fn, rows);
    if (Buffer.byteLength(text) >= FILE_CAP_BYTES) refuse(`${name}.json reaches 4 MB`);
    outputs.set(`${name}.json`, text);
    listed[`${name}.json`] = { sha256: sha256(text), cases: rows.length };
  }
  listed["tool-inputs.json"] = { ...listed["tool-inputs.json"], casesByTool: countBy(toolInputs, "tool") };
  const manifest = {
    npmRevision: PINNED,
    node: process.version,
    icu: process.versions.icu ?? null,
    ai: npm.versions.ai,
    zod: npm.versions.zod,
    lcgSeed: `0x${cases.LCG_SEED.toString(16)}`,
    generatorSHA256: generatorSHA256(),
    dist,
    files: listed,
  };
  outputs.set("manifest.json", `${JSON.stringify(manifest, null, 2)}\n`);
  return outputs;
}

function jsonFilesIn(out: string): string[] {
  return existsSync(out) ? readdirSync(out).filter((name) => name.endsWith(".json")).sort(byPath) : [];
}

function write(out: string, outputs: Map<string, string>): void {
  mkdirSync(out, { recursive: true });
  for (const name of jsonFilesIn(out)) if (!outputs.has(name)) unlinkSync(join(out, name));
  for (const [name, text] of outputs) writeFileSync(join(out, name), text);
  process.stdout.write(`npm-fixtures: wrote ${outputs.size} files from npm at ${PINNED}\n`);
}

function check(out: string, outputs: Map<string, string>): void {
  const differences: string[] = [];
  for (const [name, text] of outputs) {
    const path = join(out, name);
    if (!existsSync(path)) differences.push(`${name} is missing`);
    else if (!readFileSync(path).equals(Buffer.from(text))) differences.push(`${name} differs from npm at ${PINNED}`);
  }
  for (const name of jsonFilesIn(out)) if (!outputs.has(name)) differences.push(`${name} is not made by the generator`);
  if (differences.length > 0) {
    for (const difference of differences) process.stderr.write(`npm-fixtures: ${difference}\n`);
    process.exit(1);
  }
  process.stdout.write(`npm-fixtures: ${outputs.size} files match npm at ${PINNED}\n`);
}

const options = readOptions();
guardRevision(options.npm);
guardNoLocalChanges(options.npm);
buildClosure(options.npm, options.corepack);
guardBuildKeptTrackedFiles(options.npm);
const dist = distHashes(closure(options.npm));
const npm = await importNpm(options.npm);
armRandomUUIDTrap();
const scratch = scratchFolder();
if (options.probe !== undefined) {
  await runProbe(npm, planTools(npm, freshMemory(npm, scratch).memory), options.probe);
}
const outputs = await fixtures(npm, scratch, dist);
if (options.check) check(options.out, outputs);
else write(options.out, outputs);
