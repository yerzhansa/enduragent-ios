const pinnedNode = "v24.11.1";

if (process.version !== pinnedNode) {
  process.stderr.write(`npm-fixtures: node ${process.version} is not ${pinnedNode}\n`);
  process.exit(1);
}

process.env.TZ = "UTC";
await import("./generate.mts");
