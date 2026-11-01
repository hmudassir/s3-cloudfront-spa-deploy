// A minimal build: content-hashed JS (like Vite/webpack output) + a data folder.
import { createHash } from "node:crypto";
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";

rmSync("dist", { recursive: true, force: true });
mkdirSync("dist/assets", { recursive: true });
const js = readFileSync("src/app.js");
const name = `app-${createHash("sha256").update(js).digest("hex").slice(0, 8)}.js`;
writeFileSync(`dist/assets/${name}`, js);
writeFileSync("dist/index.html", readFileSync("src/index.html", "utf8").replace("%APP%", `/assets/${name}`));
cpSync("src/data", "dist/data", { recursive: true });
console.log(`built dist/ with assets/${name}`);
