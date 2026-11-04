// Runs a Kotlin/JS or Kotlin/Wasm test bundle under Node. kotlin-test picks a Jasmine-like adapter
// when describe/it exist; without one it falls back to an adapter that does not await async tests.
"use strict";

const fs = require("fs");
const path = require("path");
const { pathToFileURL } = require("url");

const TIMEOUT_MS = Number(process.env.KOTLIN_JS_TEST_TIMEOUT_MS || 60000);
const tests = [];
const names = [];
let skipping = 0;

globalThis.describe = (name, fn) => { names.push(name); fn(); names.pop(); };
globalThis.xdescribe = (name, fn) => { skipping++; globalThis.describe(name, fn); skipping--; };
globalThis.it = (name, fn) => tests.push({ suite: names.join("."), name, fn, skip: skipping > 0 });
globalThis.xit = (name) => tests.push({ suite: names.join("."), name, skip: true });

function withTimeout(promise) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`timed out after ${TIMEOUT_MS} ms`)), TIMEOUT_MS); }),
  ]).finally(() => clearTimeout(timer));
}

function xmlEscape(s) {
  return String(s).replace(/[<>&"]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;" }[c]));
}

async function main() {
  const entry = path.resolve(process.argv[2]);
  if (entry.endsWith(".mjs")) {
    // Kotlin/Wasm's kotlin-test reads its hooks from this namespace (Gradle's test runner defines it).
    globalThis.kotlinTest = globalThis.kotlinTest || {};
    const module = await import(pathToFileURL(entry).href);
    // Kotlin/Wasm registers its tests only when asked to.
    if (typeof module.startUnitTests === "function") module.startUnitTests();
  } else {
    require(entry);
  }
  const only = process.env.TESTBRIDGE_TEST_ONLY ? new RegExp(process.env.TESTBRIDGE_TEST_ONLY) : null;
  const results = [];
  for (const t of tests) {
    const id = `${t.suite}.${t.name}`;
    if (only && !only.test(id)) continue;
    if (t.skip) { results.push({ ...t, status: "skipped", time: 0 }); continue; }
    const start = Date.now();
    try {
      await withTimeout(Promise.resolve().then(() => t.fn()));
      results.push({ ...t, status: "passed", time: Date.now() - start });
    } catch (e) {
      results.push({ ...t, status: "failed", time: Date.now() - start, error: e });
      console.error(`FAILED: ${id}\n${(e && e.stack) || e}`);
    }
  }
  const failed = results.filter((r) => r.status === "failed").length;
  const skipped = results.filter((r) => r.status === "skipped").length;
  console.log(`\n${results.length} tests, ${failed} failed, ${skipped} skipped`);
  if (process.env.XML_OUTPUT_FILE) {
    const bySuite = new Map();
    for (const r of results) {
      if (!bySuite.has(r.suite)) bySuite.set(r.suite, []);
      bySuite.get(r.suite).push(r);
    }
    let xml = '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n';
    for (const [suite, rs] of bySuite) {
      xml += `  <testsuite name="${xmlEscape(suite)}" tests="${rs.length}">\n`;
      for (const r of rs) {
        const body = r.status === "failed"
          ? `<failure message="${xmlEscape(r.error && r.error.message)}">${xmlEscape((r.error && r.error.stack) || r.error)}</failure>`
          : r.status === "skipped" ? "<skipped/>" : "";
        xml += `    <testcase classname="${xmlEscape(suite)}" name="${xmlEscape(r.name)}" time="${(r.time / 1000).toFixed(3)}">${body}</testcase>\n`;
      }
      xml += "  </testsuite>\n";
    }
    fs.writeFileSync(process.env.XML_OUTPUT_FILE, xml + "</testsuites>\n");
  }
  if (results.length === 0) {
    console.error("No tests were found in " + entry);
  }
  process.exit(failed > 0 ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
