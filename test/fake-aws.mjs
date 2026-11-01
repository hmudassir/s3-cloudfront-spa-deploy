#!/usr/bin/env node
/**
 * A stand-in for the AWS CLI commands the scripts use, so the tests run
 * without an AWS account. S3 is a folder: $FAKE_S3_ROOT/<bucket>/<key>.
 * Every call is appended to $FAKE_AWS_LOG so tests can check the order.
 * Supports: s3 sync (incl. --delete/--exclude), s3 cp (incl. "-" to stdout),
 * s3 ls, cloudfront create-invalidation.
 */
import fs from "node:fs";
import path from "node:path";

const ROOT = process.env.FAKE_S3_ROOT;
const args = process.argv.slice(2);
fs.appendFileSync(process.env.FAKE_AWS_LOG, args.join(" ") + "\n");

const local = (u) => (u.startsWith("s3://") ? path.join(ROOT, u.slice(5)) : u);
function parse(list) {
  const pos = [], exclude = [];
  let del = false;
  for (let i = 0; i < list.length; i++) {
    const a = list[i];
    if (a === "--exclude") exclude.push(list[++i]);
    else if (a === "--delete") del = true;
    else if (["--cache-control", "--content-type", "--query", "--output", "--distribution-id"].includes(a)) i++;
    else if (a === "--paths") while (list[i + 1] && !list[i + 1].startsWith("--")) i++;
    else if (!a.startsWith("--")) pos.push(a);
  }
  return { pos, exclude, del };
}
const glob = (pattern) => new RegExp("^" + pattern.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*") + "$");
function files(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { recursive: true }).filter((f) => fs.statSync(path.join(dir, f)).isFile()).map((f) => f.split(path.sep).join("/"));
}

const [svc, cmd, ...rest] = args;
if (svc === "s3" && cmd === "sync") {
  const { pos: [from, to], exclude, del } = parse(rest);
  const src = local(from).replace(/\/$/, ""), dst = local(to).replace(/\/$/, "");
  const keep = (f) => !exclude.some((p) => glob(p).test(f));
  const wanted = files(src).filter(keep);
  for (const f of wanted) {
    fs.mkdirSync(path.dirname(path.join(dst, f)), { recursive: true });
    fs.copyFileSync(path.join(src, f), path.join(dst, f));
  }
  if (del) for (const f of files(dst)) if (keep(f) && !wanted.includes(f)) fs.rmSync(path.join(dst, f));
} else if (svc === "s3" && cmd === "cp") {
  const { pos: [from, to] } = parse(rest);
  if (to === "-") {
    if (!fs.existsSync(local(from))) process.exit(1);
    process.stdout.write(fs.readFileSync(local(from)));
  } else {
    fs.mkdirSync(path.dirname(local(to)), { recursive: true });
    fs.copyFileSync(local(from), local(to));
  }
} else if (svc === "s3" && cmd === "ls") {
  if (!fs.existsSync(local(rest[0]))) process.exit(1);
  console.log("2026-01-01 00:00:00  1 " + path.basename(rest[0]));
} else if (svc === "cloudfront" && cmd === "create-invalidation") {
  console.log("IFAKE" + Date.now());
} else {
  console.error(`fake-aws: unsupported command: ${args.join(" ")}`);
  process.exit(2);
}
