export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
export type Args = { [key: string]: Json };
export type DayOf = (instant: string, timeZone: string) => string;

export interface DatedInput {
  readonly instant: string;
  readonly timeZone: string;
  readonly input: Args;
}

export interface ToolInput {
  readonly tool: PlanToolName;
  readonly input: Json;
  readonly executes: boolean;
}

export type PlanToolName =
  | "assess_feasibility"
  | "build_plan_skeleton"
  | "get_sample_week"
  | "plan_save"
  | "plan_load";

export const LCG_SEED = 0x5eed;

export const PLAN_TOOLS: readonly PlanToolName[] = [
  "assess_feasibility",
  "build_plan_skeleton",
  "get_sample_week",
  "plan_save",
  "plan_load",
];

const LEVELS = ["beginner", "intermediate", "advanced", "elite"];
const TIERS = ["low", "medium", "high"];
const DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
const RACE_TYPES = ["century", "gran_fondo", "criterium", "time_trial", "other"];

const INSTANTS = [
  "1998-06-13T00:30:00.000Z",
  "1998-06-13T12:00:00.000Z",
  "1998-06-13T23:30:00.000Z",
  "1998-02-28T12:00:00.000Z",
  "1998-12-31T22:00:00.000Z",
  "1996-02-28T12:00:00.000Z",
];

const ZONES = ["UTC", "Asia/Almaty", "America/Los_Angeles", "Pacific/Kiritimati", "Pacific/Pago_Pago"];
const WIDER_ZONES = [...ZONES, "Asia/Kolkata", "America/St_Johns", "Europe/Berlin", "Australia/Sydney"];

const makeRng = (seed: number): (() => number) => {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 0x1_0000_0000;
  };
};

const pick = <T,>(rng: () => number, list: readonly T[]): T => list[Math.floor(rng() * list.length)];

const chance = (rng: () => number, probability: number): boolean => rng() < probability;

const between = (rng: () => number, low: number, high: number): number =>
  low + Math.floor(rng() * (high - low + 1));

const withOptional = (args: Args, key: string, value: Json | undefined): Args =>
  value === undefined ? args : { ...args, [key]: value };

export const addDays = (day: string, offset: number): string => {
  const [year, month, date] = day.split("-").map(Number);
  return new Date(Date.UTC(year, month - 1, date + offset)).toISOString().slice(0, 10);
};

const daySubsets = (): string[][] => {
  const subsets: string[][] = [];
  for (let mask = 1; mask < 1 << DAYS.length; mask += 1) {
    subsets.push(DAYS.filter((_, index) => (mask & (1 << index)) !== 0));
  }
  return subsets;
};

export function feasibility(): Args[] {
  const currents = [50, 51, 120, 199, 200, 250, 333, 599, 600];
  const ratios = [0.5, 0.9, 1, 1.05, 1.1, 1.15, 1.2, 1.25, 1.3, 1.5, 2, 3];
  const thresholds: Record<string, readonly number[]> = {
    beginner: [0.25, 0.5],
    intermediate: [0.2, 0.5],
    advanced: [0.15, 0.4],
    elite: [0.1, 0.2],
  };
  const rows: Args[] = [];
  for (const experienceLevel of LEVELS) {
    for (const currentFtp of currents) {
      const base: Args = { currentFtp, experienceLevel };
      rows.push(base, { ...base, targetFtp: 0 }, { ...base, targetFtp: -1 });
      for (const ratio of ratios) rows.push({ ...base, targetFtp: Math.round(currentFtp * ratio) });
      const edges = new Set<number>();
      for (const threshold of thresholds[experienceLevel]) {
        const edge = currentFtp * (1 + threshold);
        for (const watts of [Math.floor(edge) - 1, Math.floor(edge), Math.ceil(edge), Math.ceil(edge) + 1]) {
          edges.add(watts);
        }
      }
      for (const targetFtp of [...edges].sort((a, b) => a - b)) rows.push({ ...base, targetFtp });
    }
  }
  const wkgTargets = [undefined, 0, -2, 1e-7, 2.5, 3, 3.25, 4, 4.25, 5.5, 1e16, 1e21];
  const weights = [undefined, 1e-7, 58.5, 70, 85];
  for (const experienceLevel of LEVELS) {
    for (const currentFtp of [50, 200, 333, 600]) {
      for (const targetWkg of wkgTargets) {
        for (const currentWeightKg of weights) {
          const args = withOptional({ currentFtp, experienceLevel }, "targetWkg", targetWkg);
          rows.push(withOptional(args, "currentWeightKg", currentWeightKg));
        }
      }
    }
    for (const targetWkg of [0, 4]) {
      for (const currentWeightKg of [undefined, 70]) {
        const args = { currentFtp: 200, experienceLevel, targetFtp: 260, targetWkg };
        rows.push(withOptional(args, "currentWeightKg", currentWeightKg));
      }
    }
  }
  const rng = makeRng(LCG_SEED);
  for (let index = 0; index < 1000; index += 1) {
    const currentFtp = between(rng, 50, 600);
    let args: Args = { currentFtp, experienceLevel: pick(rng, LEVELS) };
    if (chance(rng, 0.8)) args = { ...args, targetFtp: Math.round(currentFtp * (0.5 + rng() * 2.5)) };
    if (chance(rng, 0.6)) {
      const wkg = 1 + rng() * 5;
      args = { ...args, targetWkg: chance(rng, 0.5) ? Math.round(wkg * 100) / 100 : wkg };
    }
    if (chance(rng, 0.7)) {
      const weight = 40 + rng() * 70;
      args = { ...args, currentWeightKg: chance(rng, 0.5) ? Math.round(weight * 10) / 10 : weight };
    }
    rows.push(args);
  }
  return rows;
}

const RACE_OFFSETS = [-30, -1, 0, 1, 6, 7, 8, 49, 55, 56, 57, 63, 64, 167, 168, 169, 400];

export function totalWeeks(dayOf: DayOf): DatedInput[] {
  const base: Args = {
    experienceLevel: "intermediate",
    ftpWatts: 250,
    volumeTier: "medium",
    scheduleType: "flexible",
  };
  const rows: DatedInput[] = [];
  for (const instant of INSTANTS) {
    for (const timeZone of ZONES) {
      const today = dayOf(instant, timeZone);
      const inputs: Args[] = [];
      RACE_OFFSETS.forEach((offset, index) => {
        const raceType = [...RACE_TYPES, undefined][index % (RACE_TYPES.length + 1)];
        inputs.push(withOptional({ ...base, goalType: "race", raceDate: addDays(today, offset) }, "raceType", raceType));
      });
      for (const raceType of RACE_TYPES) inputs.push({ ...base, goalType: "race", raceType });
      inputs.push({ ...base, goalType: "race" });
      for (const experienceLevel of LEVELS) inputs.push({ ...base, experienceLevel, goalType: "general" });
      inputs.push({ ...base, goalType: "general", raceDate: addDays(today, 30) });
      for (const input of inputs) rows.push({ instant, timeZone, input });
    }
  }
  return rows;
}

const goalVariants = (today: string): Args[] => {
  const variants: Args[] = [
    { goalType: "general" },
    { goalType: "general", generalGoal: "Climb faster" },
    { goalType: "general", generalGoal: "Climb faster", generalGoalTarget: "Hold 4 W/kg for 20 minutes" },
    { goalType: "general", generalGoalTarget: "Ride 100 km" },
    { goalType: "general", generalGoal: "" },
    { goalType: "general", generalGoal: "", generalGoalTarget: "" },
    { goalType: "general", raceDate: addDays(today, 70) },
    { goalType: "general", raceType: "century", raceDate: addDays(today, 70) },
    ...RACE_TYPES.map((raceType) => ({ goalType: "race", raceType })),
    { goalType: "race" },
  ];
  [8, 9, 12, 16, 20, 23, 24].forEach((weeks, index) => {
    const raceType = [...RACE_TYPES, undefined][index % (RACE_TYPES.length + 1)];
    const raceDate = addDays(today, 7 * weeks - (index % 7));
    variants.push(withOptional({ goalType: "race", raceDate }, "raceType", raceType));
  });
  variants.push(
    { goalType: "race", raceType: "gran_fondo", raceDate: addDays(today, -3) },
    { goalType: "race", raceType: "time_trial", raceDate: today },
    { goalType: "race", raceType: "gran_fondo", targetTime: "5:30:00" },
    { goalType: "race", raceType: "criterium", targetTime: "" },
  );
  return variants;
};

const SCHEDULE_VARIANTS: readonly Args[] = [
  { scheduleType: "flexible" },
  { scheduleType: "flexible", sessionsPerWeek: 3 },
  { scheduleType: "flexible", sessionsPerWeek: 4 },
  { scheduleType: "flexible", sessionsPerWeek: 6 },
  { scheduleType: "fixed", availableDays: ["sat", "sun"] },
  { scheduleType: "fixed", availableDays: ["tue", "thu", "sat"] },
  { scheduleType: "fixed", availableDays: [...DAYS] },
  { scheduleType: "fixed", availableDays: ["tue", "thu", "sat"], keySessionDay: "sat" },
  { scheduleType: "fixed", availableDays: ["mon", "wed", "sat"], sessionsPerWeek: 5 },
  { scheduleType: "fixed", sessionsPerWeek: 4 },
];

const profileNumbers = (index: number): Args => {
  const ftpWatts = 50 + ((index * 37) % 551);
  if (index % 3 === 0) return { ftpWatts };
  return { ftpWatts, weightKg: 45 + ((index * 7) % 60) + (index % 2 === 0 ? 0 : 0.5) };
};

const draftClock = (index: number): { instant: string; timeZone: string } => ({
  instant: INSTANTS[index % INSTANTS.length],
  timeZone: ZONES[Math.floor(index / INSTANTS.length) % ZONES.length],
});

export function planDraft(dayOf: DayOf): DatedInput[] {
  const rows: DatedInput[] = [];
  for (const experienceLevel of LEVELS) {
    for (const volumeTier of TIERS) {
      for (let goal = 0; goal < 25; goal += 1) {
        for (const schedule of SCHEDULE_VARIANTS) {
          const clock = draftClock(rows.length);
          const goalArgs = goalVariants(dayOf(clock.instant, clock.timeZone))[goal];
          const input = { experienceLevel, ...profileNumbers(rows.length), volumeTier, ...schedule, ...goalArgs };
          rows.push({ ...clock, input });
        }
      }
    }
  }
  const rng = makeRng(LCG_SEED);
  const subsets = daySubsets();
  for (let index = 0; index < 1000; index += 1) {
    const instant = new Date(Date.UTC(1998, 0, 1) + between(rng, 0, 365 * 24 * 60 - 1) * 60_000).toISOString();
    const timeZone = pick(rng, WIDER_ZONES);
    const today = dayOf(instant, timeZone);
    let input: Args = {
      experienceLevel: pick(rng, LEVELS),
      ftpWatts: between(rng, 50, 600),
      volumeTier: pick(rng, TIERS),
      scheduleType: pick(rng, ["fixed", "flexible"]),
      goalType: pick(rng, ["race", "general"]),
    };
    if (chance(rng, 0.5)) input = { ...input, weightKg: Math.round((40 + rng() * 70) * 10) / 10 };
    if (chance(rng, 0.6)) input = { ...input, availableDays: chance(rng, 0.05) ? [] : pick(rng, subsets) };
    if (chance(rng, 0.3)) input = { ...input, keySessionDay: pick(rng, DAYS) };
    if (chance(rng, 0.5)) input = { ...input, sessionsPerWeek: between(rng, 3, 6) };
    if (chance(rng, 0.6)) input = { ...input, raceType: pick(rng, RACE_TYPES) };
    if (chance(rng, 0.6)) input = { ...input, raceDate: addDays(today, between(rng, -60, 300)) };
    if (chance(rng, 0.3)) input = { ...input, targetTime: pick(rng, ["", "4:45:00", "sub 3 hours"]) };
    if (chance(rng, 0.3)) input = { ...input, generalGoal: pick(rng, ["", "Build endurance", "Ride my first century"]) };
    if (chance(rng, 0.2)) input = { ...input, generalGoalTarget: pick(rng, ["", "300 W", "Finish strong"]) };
    rows.push({ instant, timeZone, input });
  }
  return rows;
}

export function sampleWeek(): Args[] {
  const rows: Args[] = [];
  for (const volumeTier of TIERS) {
    for (const availableDays of daySubsets()) {
      for (const keySessionDay of [undefined, ...DAYS]) {
        rows.push(withOptional({ volumeTier, scheduleType: "fixed", availableDays }, "keySessionDay", keySessionDay));
      }
    }
    for (const sessionsPerWeek of [undefined, 3, 4, 5, 6]) {
      rows.push(withOptional({ volumeTier, scheduleType: "flexible" }, "sessionsPerWeek", sessionsPerWeek));
    }
    rows.push(
      { volumeTier, scheduleType: "fixed", availableDays: ["sat", "sat"] },
      { volumeTier, scheduleType: "fixed", availableDays: ["mon", "mon", "tue"], keySessionDay: "mon" },
      { volumeTier, scheduleType: "fixed", availableDays: ["tue", "thu"], keySessionDay: "sun" },
      { volumeTier, scheduleType: "fixed" },
      { volumeTier, scheduleType: "fixed", availableDays: [] },
      { volumeTier, scheduleType: "fixed", availableDays: ["sun", "mon", "wed"] },
      { volumeTier, scheduleType: "fixed", availableDays: ["sat", "tue", "thu", "mon"], keySessionDay: "tue" },
      { volumeTier, scheduleType: "fixed", availableDays: ["wed", "fri"], sessionsPerWeek: 6 },
      { volumeTier, scheduleType: "flexible", availableDays: ["sat", "sun"], sessionsPerWeek: 3 },
      { volumeTier, scheduleType: "flexible", keySessionDay: "sat" },
    );
  }
  return rows;
}

const SAFE = Number.MAX_SAFE_INTEGER;

const sharedRefusals = (tool: PlanToolName): ToolInput[] =>
  [null, [], "plan", 7].map((input) => ({ tool, input, executes: false }));

const variations = (tool: PlanToolName, valid: Args, changes: readonly Args[], executes: boolean): ToolInput[] =>
  changes.map((change) => {
    const input: Args = { ...valid };
    for (const [key, value] of Object.entries(change)) {
      if (value === "<absent>") delete input[key];
      else input[key] = value;
    }
    return { tool, input, executes };
  });

const missingEach = (keys: readonly string[]): Args[] => keys.map((key) => ({ [key]: "<absent>" }));

export function toolInputs(): ToolInput[] {
  const feasibilityArgs: Args = { currentFtp: 250, targetFtp: 300, experienceLevel: "intermediate" };
  const skeletonArgs: Args = {
    experienceLevel: "intermediate",
    ftpWatts: 250,
    volumeTier: "medium",
    scheduleType: "flexible",
    goalType: "general",
  };
  const sampleArgs: Args = { volumeTier: "medium", scheduleType: "flexible" };
  const rows: ToolInput[] = [];

  rows.push(...sharedRefusals("assess_feasibility"));
  rows.push(
    ...variations(
      "assess_feasibility",
      feasibilityArgs,
      [
        {},
        { targetFtp: "<absent>" },
        ...missingEach(["currentFtp", "experienceLevel"]),
        { currentFtp: 49 },
        { currentFtp: 50 },
        { currentFtp: 600 },
        { currentFtp: 601 },
        { currentFtp: 250.5 },
        { currentFtp: "250" },
        { currentFtp: null },
        { currentFtp: SAFE },
        { targetFtp: SAFE },
        { targetFtp: -SAFE },
        { targetFtp: SAFE + 1 },
        { targetFtp: 300.5 },
        { targetFtp: "300" },
        { targetFtp: null },
        { targetFtp: "<absent>", targetWkg: 4 },
        { targetFtp: "<absent>", targetWkg: 4, currentWeightKg: 70 },
        { targetFtp: "<absent>", targetWkg: 4, currentWeightKg: 0 },
        { targetFtp: "<absent>", targetWkg: 4, currentWeightKg: -70 },
        { targetFtp: "<absent>", targetWkg: 4, currentWeightKg: 1e-7 },
        { targetFtp: "<absent>", targetWkg: "4", currentWeightKg: 70 },
        { targetFtp: "<absent>", targetWkg: 4, currentWeightKg: "70" },
        { targetWkg: null },
        { experienceLevel: "pro" },
        { experienceLevel: "Intermediate" },
        { experienceLevel: 1 },
        { unexpected: true },
      ],
      true,
    ),
  );

  rows.push(...sharedRefusals("build_plan_skeleton"));
  rows.push(
    ...variations(
      "build_plan_skeleton",
      skeletonArgs,
      [
        {},
        ...missingEach(["experienceLevel", "ftpWatts", "volumeTier", "scheduleType", "goalType"]),
        { ftpWatts: 49 },
        { ftpWatts: 50 },
        { ftpWatts: 600 },
        { ftpWatts: 601 },
        { ftpWatts: 250.5 },
        { ftpWatts: "250" },
        { ftpWatts: SAFE },
        { ftpWatts: SAFE + 1 },
        { weightKg: 0 },
        { weightKg: -60 },
        { weightKg: 1e-7 },
        { weightKg: "70" },
        { weightKg: null },
        { volumeTier: "extreme" },
        { scheduleType: "weekly" },
        { goalType: "fun" },
        { experienceLevel: "pro" },
        { availableDays: "mon" },
        { availableDays: ["funday"] },
        { availableDays: ["Mon"] },
        { availableDays: [] },
        { availableDays: ["sat", "sat"] },
        { keySessionDay: "someday" },
        { keySessionDay: ["sat"] },
        { sessionsPerWeek: 1 },
        { sessionsPerWeek: 2 },
        { sessionsPerWeek: 3 },
        { sessionsPerWeek: 6 },
        { sessionsPerWeek: 7 },
        { sessionsPerWeek: 4.5 },
        { goalType: "race", raceType: "marathon" },
        { goalType: "race", raceType: "gran_fondo" },
        { goalType: "race", raceDate: "1998-7-4" },
        { goalType: "race", raceDate: "July 4, 1998" },
        { goalType: "race", raceDate: "1998-07-04T00:00:00Z" },
        { goalType: "race", raceDate: 19980704 },
        { goalType: "race", raceDate: "" },
        { goalType: "race", targetTime: 330 },
        { generalGoal: 3 },
        { generalGoalTarget: null },
        { needsExtraRecovery: true },
      ],
      false,
    ),
  );
  rows.push(
    ...variations(
      "build_plan_skeleton",
      skeletonArgs,
      ["1998-02-31", "1998-02-29", "1900-02-29", "1998-13-01", "1998-00-10", "1998-04-31"].map(
        (raceDate) => ({ goalType: "race", raceDate }),
      ),
      true,
    ),
  );
  rows.push(
    ...variations(
      "build_plan_skeleton",
      skeletonArgs,
      ["2000-02-29", "0000-01-01"].map((raceDate) => ({ goalType: "race", raceDate })),
      false,
    ),
  );

  rows.push(...sharedRefusals("get_sample_week"));
  rows.push(
    ...variations(
      "get_sample_week",
      sampleArgs,
      [
        {},
        ...missingEach(["volumeTier", "scheduleType"]),
        { volumeTier: "extreme" },
        { volumeTier: "Low" },
        { scheduleType: "weekly" },
        { sessionsPerWeek: 1 },
        { sessionsPerWeek: 2 },
        { sessionsPerWeek: 3 },
        { sessionsPerWeek: 6 },
        { sessionsPerWeek: 7 },
        { sessionsPerWeek: 3.5 },
        { sessionsPerWeek: "4" },
        { sessionsPerWeek: null },
        { scheduleType: "fixed", availableDays: ["sat", "sun"] },
        { scheduleType: "fixed", availableDays: "sat" },
        { scheduleType: "fixed", availableDays: ["saturday"] },
        { scheduleType: "fixed", availableDays: [] },
        { scheduleType: "fixed", availableDays: ["sat", "sun"], keySessionDay: "Sun" },
        { scheduleType: "fixed", availableDays: ["sat", "sun"], keySessionDay: "sun" },
        { scheduleType: "fixed", availableDays: [1, 2] },
        { unexpected: "value" },
      ],
      true,
    ),
  );

  rows.push(...sharedRefusals("plan_save"));
  const planSaveArgs: Json[] = [
    {},
    { plan: null },
    { plan: "12-Week Plan" },
    { plan: [] },
    { plan: {} },
    { plan: { name: 12 } },
    { plan: { name: null } },
    { plan: { primaryGoal: "century" } },
    { plan: { name: "Base" } },
    { plan: { name: "" } },
    { plan: { name: "Base", primaryGoal: 3 } },
    { plan: { name: "Base", primaryGoal: null } },
    { plan: { name: "Base", totalWeeks: 0 } },
    { plan: { name: "Base", totalWeeks: -1 } },
    { plan: { name: "Base", totalWeeks: 1.5 } },
    { plan: { name: "Base", totalWeeks: "12" } },
    { plan: { name: "Base", totalWeeks: 12 } },
    { plan: { name: "Base", totalWeeks: SAFE } },
    { plan: { name: "Base", totalWeeks: SAFE + 1 } },
    { plan: { name: "Base", status: 1 } },
    { plan: { name: "Base", status: "draft" } },
    { plan: { name: "Base", phases: [{ focus: "base_building" }] } },
    { plan: { name: "Base" }, note: "extra" },
  ];
  rows.push(...planSaveArgs.map((input) => ({ tool: "plan_save" as const, input, executes: false })));

  rows.push(...sharedRefusals("plan_load"));
  rows.push(
    ...[{}, { name: "Base" }, { plan: null }].map((input) => ({ tool: "plan_load" as const, input, executes: false })),
  );
  return rows;
}

const HEADLINE_BASE: Args = {
  name: "Base Build",
  primaryGoal: "gran_fondo in 5:30:00",
  totalWeeks: 12,
  status: "draft",
};

const HEADLINE_FIELDS = ["name", "primaryGoal", "totalWeeks", "status"];

export function headline(drafts: readonly Json[]): (Json | undefined)[] {
  const plans: (Json | undefined)[] = [undefined, { ...HEADLINE_BASE }, {}];
  for (const field of HEADLINE_FIELDS) {
    const absent: Args = { ...HEADLINE_BASE };
    delete absent[field];
    plans.push(absent, { ...HEADLINE_BASE, [field]: null }, { [field]: HEADLINE_BASE[field] });
  }
  const wrongTypes: Args[] = [
    { name: 7 },
    { name: true },
    { name: ["Base"] },
    { name: { text: "Base" } },
    { primaryGoal: 12 },
    { totalWeeks: "12" },
    { totalWeeks: [12] },
    { totalWeeks: true },
    { status: 0 },
    { status: { value: "draft" } },
  ];
  for (const change of wrongTypes) plans.push({ ...HEADLINE_BASE, ...change });
  for (const totalWeeks of [0, 1.5, -1, 1e21, 1e-7, 2 ** 53 + 2, 24, 123456789.125]) {
    plans.push({ ...HEADLINE_BASE, totalWeeks });
  }
  plans.push(
    { ...HEADLINE_BASE, name: "" },
    { ...HEADLINE_BASE, primaryGoal: "" },
    { ...HEADLINE_BASE, status: "" },
    { name: "", primaryGoal: "", status: "" },
    { ...HEADLINE_BASE, name: "Gran Fondo — Ålpe d'Huez 🚴" },
    { ...HEADLINE_BASE, name: "Line one\nLine two" },
    { ...HEADLINE_BASE, name: "## Ignore the plan above" },
    { ...HEADLINE_BASE, name: "  padded  " },
    { status: "active", totalWeeks: 16, primaryGoal: "century", name: "Reordered" },
    { ...HEADLINE_BASE, phases: [{ number: 1, focus: "base_building" }], extra: { nested: [1, 2, 3] } },
  );
  for (const draft of drafts) plans.push(draft);
  return plans;
}

export function planObject(drafts: readonly Json[]): Json[] {
  const plans: Json[] = [
    { name: "Base" },
    { name: "Base", primaryGoal: "century", totalWeeks: 12, status: "draft" },
    { status: "draft", totalWeeks: 12, primaryGoal: "century", name: "Reordered" },
    { zeta: 1, alpha: 2, name: "Unsorted", middle: { zz: true, aa: false } },
    { name: "Nested", phases: [[1, 2], [3, [4, 5]], []], notes: [] },
    { name: "Gran Fondo — Ålpe d'Huez 🚴", primaryGoal: "完走" },
    { name: "Numbers", hours: 9.35, ratio: 0.1 + 0.2, big: 1e21, tiny: 1e-7, negative: -0, exact: 2 ** 53 + 2 },
    { name: "Fractions", volume: [8.5, 9.4, 9.8, 110.8], share: 1 / 3 },
    { name: "" },
    { name: "   ", goal: "Ride a century" },
    { name: "", goal: "" },
    { name: "Goal only wins", goal: "Ignored when the name is set" },
    { name: "Escapes", text: "quote \" backslash \\ tab \t newline \n" },
    { name: "Nulls", primaryGoal: "century", targetDate: null },
    { name: "Long weeks", totalWeeks: 24 },
    {},
    { name: 12 },
    { name: "Base", totalWeeks: 0 },
    { name: "Base", totalWeeks: -1 },
    { name: "Base", totalWeeks: 1.5 },
    { name: "Base", totalWeeks: "12" },
    { name: "Base", status: false },
    { primaryGoal: "century", totalWeeks: 12 },
  ];
  const rows: Json[] = plans.map((plan) => ({ plan }));
  for (const draft of drafts) rows.push({ plan: draft });
  rows.push({ plan: { name: "Top-level extra" }, note: "dropped by the schema" });
  return rows;
}

export const randomUUIDProbe: Args = {
  experienceLevel: "intermediate",
  ftpWatts: 250,
  volumeTier: "medium",
  scheduleType: "flexible",
  goalType: "general",
};

export const outsideSchemaProbe: Args = { volumeTier: "medium", scheduleType: "flexible", sessionsPerWeek: 7 };
