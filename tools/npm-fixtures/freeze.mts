import crypto from "node:crypto";
import { syncBuiltinESMExports } from "node:module";

const RealDate = Date;
const realRandomUUID = crypto.randomUUID;
let frozen = RealDate.parse("1998-06-13T08:00:00.000Z");
let armed = false;
let draws = 0;

export class RandomUUIDReached extends Error {
  constructor() {
    super("a case reached randomUUID");
    this.name = "RandomUUIDReached";
  }
}

class FrozenDate extends RealDate {
  constructor(...args: unknown[]) {
    super(...((args.length === 0 ? [frozen] : args) as []));
  }

  static now(): number {
    return frozen;
  }
}

const refuseRandomUUID = (): ReturnType<typeof realRandomUUID> => {
  if (!armed) return realRandomUUID();
  draws += 1;
  throw new RandomUUIDReached();
};

globalThis.Date = FrozenDate as DateConstructor;
crypto.randomUUID = refuseRandomUUID;
globalThis.crypto.randomUUID = refuseRandomUUID;
syncBuiltinESMExports();

export const setNow = (iso: string): void => {
  const instant = RealDate.parse(iso);
  if (!Number.isFinite(instant)) throw new RangeError(`${iso} is not an instant`);
  frozen = instant;
};

export const armRandomUUIDTrap = (): void => {
  armed = true;
};

export const randomUUIDDraws = (): number => draws;
